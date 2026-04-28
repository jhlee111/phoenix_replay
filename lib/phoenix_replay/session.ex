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

  alias PhoenixReplay.{Config, DedupeBuffer}
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

  @doc """
  Returns a snapshot of every running Session — one summary map per
  registered process. Used by the index LV at mount time to seed its
  table; live updates arrive afterwards via the global
  `"\#{prefix}:sessions"` topic.

  Concurrent: each `Registry.select/2` hit fans out to its Session
  via `Task.async_stream/3` (timeout 200ms, kill-on-timeout) so a
  single stuck process can't stall the whole snapshot. Sessions that
  die mid-iteration are silently dropped.

  ## Summary shape

      %{
        session_id: String.t(),
        identity: map(),
        started_at: DateTime.t(),
        last_event_at: DateTime.t(),
        seq_watermark: non_neg_integer()
      }
  """
  @spec list_active() :: [map()]
  def list_active do
    PhoenixReplay.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Task.async_stream(
      fn {_session_id, pid} ->
        try do
          GenServer.call(pid, :state_summary, 100)
        catch
          :exit, _ -> nil
        end
      end,
      timeout: 200,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, %{} = summary} -> [summary]
      _ -> []
    end)
  end

  @doc """
  Returns the historical event stream plus the current `seq_watermark`
  for a running session, serialized against in-flight appends. Used by
  the live watch LV at mount time to seed the player with catch-up
  frames without racing against newly-arriving `:event_batch`
  broadcasts — any broadcast with `seq <= watermark` from the returned
  pair is already in the returned events; later seqs are strictly new.

  Falls back to `Storage.Dispatch.fetch_events/1` when no Session
  process is registered (the session has already closed or been
  abandoned). In that case returns `{:ok, events, :infinity}` — no
  further broadcasts will arrive, so the dedup watermark is moot.
  """
  @spec catchup(String.t()) ::
          {:ok, [map()], non_neg_integer() | :infinity} | {:error, term()}
  def catchup(session_id) when is_binary(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, :catchup)

      [] ->
        case Dispatch.fetch_events(session_id) do
          {:ok, events} -> {:ok, events, :infinity}
          {:error, _} = err -> err
        end
    end
  end

  @doc false
  def via(session_id), do: {:via, Registry, {PhoenixReplay.SessionRegistry, session_id}}

  # Capture-stream API (ADR-0007). Invoked by PhoenixReplay.CaptureStream.

  @doc false
  @spec pid_for(String.t()) :: pid() | nil
  def pid_for(session_id) when is_binary(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec attach_stream(pid(), String.t(), keyword()) :: :ok
  def attach_stream(pid, stream_id, opts) do
    GenServer.call(pid, {:attach_stream, stream_id, opts})
  end

  @doc false
  @spec record_clock_offset(pid(), integer()) :: :ok
  def record_clock_offset(pid, browser_started_at_ms) do
    GenServer.call(pid, {:record_clock_offset, browser_started_at_ms})
  end

  @doc false
  @spec handle_capture_push(pid(), String.t(), map()) :: :ok
  def handle_capture_push(pid, stream_id, event) do
    GenServer.cast(pid, {:capture_push, stream_id, event})
  end

  @doc false
  @spec drain_capture_streams(pid()) :: [map()]
  def drain_capture_streams(pid) do
    GenServer.call(pid, :drain_capture_streams)
  end

  @doc false
  # Test helper — overrides the timestamp used by record_clock_offset
  # as `server_received_at_ms`. Production path uses
  # System.system_time(:millisecond) directly.
  @spec set_clock_received_at_for_test(pid(), integer()) :: :ok
  def set_clock_received_at_for_test(pid, ts) do
    GenServer.call(pid, {:set_clock_received_at, ts})
  end

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

    now = DateTime.utc_now()

    state = %{
      session_id: session_id,
      identity: identity,
      seq_watermark: seq_watermark,
      started_at: now,
      last_event_at: now,
      idle_timeout_ms: idle_ms,
      idle_timer: nil,
      dedup: DedupeBuffer.new(@recent_seqs_capacity),
      pubsub: Config.pubsub(),
      topic: topic_for(session_id),
      # Capture-stream state (ADR-0007).
      # capture_streams: stream_id => :queue.t() of raw push_event maps
      # capture_opts:    stream_id => keyword() (e.g. max_events: 5000)
      # clock_offset:    integer | nil — server_time - browser_time
      # clock_received_at_ms: integer | nil — test override for offset calc
      capture_streams: %{},
      capture_opts: %{},
      clock_offset: nil,
      clock_received_at_ms: nil
    }

    broadcast_global(state, {:session_started, session_id, identity, now})

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_call({:append, seq, events}, _from, state) do
    cond do
      DedupeBuffer.member?(state.dedup, seq) ->
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
    broadcast_global(state, {:session_closed, state.session_id, reason})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:catchup, _from, state) do
    case Dispatch.fetch_events(state.session_id) do
      {:ok, events} -> {:reply, {:ok, events, state.seq_watermark}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:state_summary, _from, state) do
    {:reply, state_summary(state), state}
  end

  # Capture-stream handlers (ADR-0007).

  @capture_default_max_events 5_000

  def handle_call({:attach_stream, stream_id, opts}, _from, state) do
    state = %{
      state
      | capture_streams: Map.put_new(state.capture_streams, stream_id, :queue.new()),
        capture_opts: Map.put(state.capture_opts, stream_id, opts)
    }

    PhoenixReplay.CaptureStream.Registry.register(state.session_id, stream_id, self())
    {:reply, :ok, state}
  end

  def handle_call({:record_clock_offset, browser_started_at_ms}, _from, state) do
    received_at = state.clock_received_at_ms || System.system_time(:millisecond)
    offset = received_at - browser_started_at_ms
    {:reply, :ok, %{state | clock_offset: offset}}
  end

  def handle_call(:drain_capture_streams, _from, state) do
    offset = state.clock_offset || 0

    events =
      Enum.flat_map(state.capture_streams, fn {stream_id, queue} ->
        queue
        |> :queue.to_list()
        |> Enum.map(fn ev ->
          %{
            "type" => 6,
            "timestamp" => ev.server_time_ms - offset,
            "data" => %{"plugin" => stream_id, "payload" => ev.payload}
          }
        end)
      end)

    cleared = Map.new(state.capture_streams, fn {sid, _} -> {sid, :queue.new()} end)
    {:reply, events, %{state | capture_streams: cleared}}
  end

  def handle_call({:set_clock_received_at, ts}, _from, state) do
    {:reply, :ok, %{state | clock_received_at_ms: ts}}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    broadcast(state, {:session_abandoned, state.session_id, state.last_event_at})
    broadcast_global(state, {:session_abandoned, state.session_id, state.last_event_at})
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast({:capture_push, stream_id, event}, state) do
    case Map.fetch(state.capture_streams, stream_id) do
      :error ->
        {:noreply, state}

      {:ok, queue} ->
        max =
          state.capture_opts
          |> Map.get(stream_id, [])
          |> Keyword.get(:max_events, @capture_default_max_events)

        queue = :queue.in(event, queue)

        queue =
          case :queue.len(queue) do
            n when n > max ->
              {{:value, _evicted}, q2} = :queue.out(queue)
              q2

            _ ->
              queue
          end

        {:noreply, put_in(state.capture_streams[stream_id], queue)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Purge capture-stream Registry entries for this session so subsequent
    # CaptureStream.push_event/3 calls become silent no-ops rather than
    # routing to a stopped pid. Belt-and-suspenders with the Registry's
    # own :DOWN monitor handler.
    PhoenixReplay.CaptureStream.Registry.unregister_session(state.session_id)
    :ok
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
    %{state | dedup: DedupeBuffer.put(state.dedup, seq)}
  end

  defp broadcast(%{pubsub: nil}, _msg), do: :ok

  defp broadcast(%{pubsub: pubsub, topic: topic}, msg) do
    Phoenix.PubSub.broadcast(pubsub, topic, msg)
  end

  defp broadcast_global(%{pubsub: nil}, _msg), do: :ok

  defp broadcast_global(%{pubsub: pubsub}, msg) do
    Phoenix.PubSub.broadcast(pubsub, sessions_topic(), msg)
  end

  defp state_summary(state) do
    %{
      session_id: state.session_id,
      identity: state.identity,
      started_at: state.started_at,
      last_event_at: state.last_event_at,
      seq_watermark: state.seq_watermark
    }
  end

  defp topic_for(session_id) do
    "#{Config.pubsub_topic_prefix()}:session:#{session_id}"
  end

  @doc false
  # Public so the index LV (and tests) can subscribe to the global
  # bus without re-deriving the prefix.
  def sessions_topic do
    "#{Config.pubsub_topic_prefix()}:sessions"
  end
end
