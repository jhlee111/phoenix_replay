defmodule PhoenixReplay.Session do
  @moduledoc false
  # Per-session GenServer (ADR-0003 Phase 2). One process per
  # `session_id`, registered under `PhoenixReplay.SessionRegistry`,
  # supervised by `PhoenixReplay.SessionSupervisor`.
  #
  # Holds the in-memory session state — current `seq_watermark`, a
  # bounded queue of recent `seq` values for in-flight dedup, and an
  # idle-timer reference. Persists every accepted batch via
  # `Storage.Dispatch.append_events/3` and broadcasts
  # `{:event_batch, ...}` on the session topic so live admin views can
  # subscribe.
  #
  # Messages broadcast:
  #
  #   * `{:event_batch, session_id, events, seq}` — after a successful
  #     persisted append.
  #   * `{:session_closed, session_id, reason}` — `close/2` invoked
  #     (typically from `SubmitController`).
  #   * `{:session_abandoned, session_id, last_event_at}` — idle
  #     timer fired without a `close/2`.
  #
  # Topic: `"#{prefix}:session:#{session_id}"` where `prefix` defaults
  # to `"phoenix_replay"` and is configurable via
  # `:pubsub_topic_prefix`.
  #
  # The process intentionally exits on `:idle_timeout` or `close/2` —
  # the supervisor uses `:transient` restart semantics so normal exits
  # don't spawn a fresh child. Crash → supervisor restarts; the next
  # `/events` POST will hit the controller's lookup-or-start path
  # (which falls back to the DB resume) and a fresh process takes
  # over with the persisted watermark.

  use GenServer, restart: :transient

  alias PhoenixReplay.Config
  alias PhoenixReplay.Storage.Dispatch

  @recent_seqs_capacity 50

  # Public API

  @doc """
  Returns `{:ok, pid}` for the running Session process for
  `session_id`. If no process is registered, attempts to start one,
  seeding the watermark from the configured storage adapter
  (`Storage.Dispatch.resume_session/2`). Returns `{:error, :no_session}`
  when the storage adapter has no record of `session_id` (i.e. the
  session was never started or has been GC'd).
  """
  @spec lookup_or_start(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def lookup_or_start(session_id, identity) when is_binary(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Dispatch.resume_session(session_id, DateTime.utc_now()) do
          {:ok, ^session_id, watermark} ->
            start_session(session_id, identity, seq_watermark: watermark)

          {:error, :not_found} ->
            # Brand-new session that hasn't yet written any event
            # rows — start it with watermark 0. Identity binding has
            # already been verified by the token at the controller.
            start_session(session_id, identity, seq_watermark: 0)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Starts (or returns the existing) Session process for `session_id`.
  Wraps `SessionSupervisor.start_session/3` and folds
  `:already_started` into the success path.
  """
  @spec start_session(String.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id, identity, opts \\ []) do
    case PhoenixReplay.SessionSupervisor.start_session(session_id, identity, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Appends a batch of events at position `seq` to the session
  identified by `session_id`. The Session process dedups against
  recently-seen `seq` values, persists via the storage adapter, then
  broadcasts `{:event_batch, session_id, events, seq}` and resets
  the idle timer.

  Returns:
    * `:ok` on a fresh accept
    * `:ok` (silent) on a dedup hit (already-seen `seq`)
    * `{:error, :conflict}` when the storage adapter rejects the seq
    * `{:error, :no_session}` when no Session process exists for
      `session_id` (caller should `lookup_or_start/2` first)
  """
  @spec append_events(String.t(), non_neg_integer(), [map()]) ::
          :ok | {:error, term()}
  def append_events(session_id, seq, events)
      when is_binary(session_id) and is_integer(seq) and is_list(events) do
    call(session_id, {:append, seq, events})
  end

  @doc """
  Returns the current `seq_watermark` for `session_id` — the maximum
  `seq` value persisted so far. Used by the resume path in
  `SessionController` to tell the client where to keep numbering
  from.
  """
  @spec seq_watermark(String.t()) :: {:ok, non_neg_integer()} | {:error, :no_session}
  def seq_watermark(session_id) when is_binary(session_id) do
    call(session_id, :seq_watermark)
  end

  @doc """
  Closes the session — cancels the idle timer, broadcasts
  `{:session_closed, session_id, reason}`, and stops the process.
  Typically called from `SubmitController` with `reason: :submitted`.
  """
  @spec close(String.t(), atom()) :: :ok | {:error, :no_session}
  def close(session_id, reason \\ :normal) when is_binary(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:close, reason})
      [] -> {:error, :no_session}
    end
  end

  @doc false
  def via(session_id), do: {:via, Registry, {PhoenixReplay.SessionRegistry, session_id}}

  # GenServer

  @doc false
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    identity = Keyword.fetch!(opts, :identity)
    seq_watermark = Keyword.get(opts, :seq_watermark, 0)
    idle_ms = Keyword.get(opts, :idle_timeout_ms, Config.session_idle_timeout_ms())

    state = %{
      session_id: session_id,
      identity: identity,
      seq_watermark: seq_watermark,
      started_at: DateTime.utc_now(),
      last_event_at: DateTime.utc_now(),
      idle_timeout_ms: idle_ms,
      idle_timer: nil,
      recent_seqs: :queue.new(),
      recent_seqs_set: MapSet.new(),
      pubsub: Config.pubsub(),
      topic: topic_for(session_id)
    }

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_call({:append, seq, events}, _from, state) do
    cond do
      MapSet.member?(state.recent_seqs_set, seq) ->
        # Silent dedup — controller doesn't need to know.
        {:reply, :ok, schedule_idle(state)}

      true ->
        case Dispatch.append_events(state.session_id, seq, events) do
          :ok ->
            broadcast(state, {:event_batch, state.session_id, events, seq})

            new_state =
              state
              |> remember_seq(seq)
              |> Map.put(:seq_watermark, max(state.seq_watermark, seq))
              |> Map.put(:last_event_at, DateTime.utc_now())
              |> schedule_idle()

            {:reply, :ok, new_state}

          {:error, :conflict} = err ->
            # Storage layer caught a duplicate that bypassed our
            # in-memory dedup (e.g. fresh process after a crash).
            # Bump our local memory so subsequent retries are
            # absorbed silently.
            {:reply, err, state |> remember_seq(seq) |> schedule_idle()}

          {:error, _} = err ->
            {:reply, err, schedule_idle(state)}
        end
    end
  end

  @impl true
  def handle_call(:seq_watermark, _from, state) do
    {:reply, {:ok, state.seq_watermark}, state}
  end

  @impl true
  def handle_call({:close, reason}, _from, state) do
    cancel_idle(state)
    broadcast(state, {:session_closed, state.session_id, reason})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    broadcast(state, {:session_abandoned, state.session_id, state.last_event_at})
    {:stop, :normal, state}
  end

  # Internals

  defp call(session_id, msg) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, msg)
      [] -> {:error, :no_session}
    end
  end

  defp schedule_idle(state) do
    cancel_idle(state)
    ref = Process.send_after(self(), :idle_timeout, state.idle_timeout_ms)
    %{state | idle_timer: ref}
  end

  defp cancel_idle(%{idle_timer: nil} = _state), do: :ok

  defp cancel_idle(%{idle_timer: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  defp remember_seq(state, seq) do
    queue = :queue.in(seq, state.recent_seqs)
    set = MapSet.put(state.recent_seqs_set, seq)

    if :queue.len(queue) > @recent_seqs_capacity do
      {{:value, dropped}, queue2} = :queue.out(queue)
      %{state | recent_seqs: queue2, recent_seqs_set: MapSet.delete(set, dropped)}
    else
      %{state | recent_seqs: queue, recent_seqs_set: set}
    end
  end

  defp broadcast(%{pubsub: nil}, _msg), do: :ok

  defp broadcast(%{pubsub: pubsub, topic: topic}, msg) do
    Phoenix.PubSub.broadcast(pubsub, topic, msg)
  end

  defp topic_for(session_id) do
    "#{Config.pubsub_topic_prefix()}:session:#{session_id}"
  end
end
