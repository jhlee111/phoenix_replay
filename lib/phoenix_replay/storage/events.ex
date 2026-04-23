defmodule PhoenixReplay.Storage.Events do
  @moduledoc """
  Event-stream helpers shared by all storage adapters.

  The `phoenix_replay_events` child table is owned by
  `phoenix_replay` — it is **not** an Ash resource and never will
  be. Whether the feedback parent row lives in a plain Ecto schema
  (`PhoenixReplay.Storage.Ecto`) or in an Ash resource
  (`AshFeedback.Storage`), the event stream goes through this
  module with an explicit `repo` argument.

  Callers are expected to have run the migration from
  `mix phoenix_replay.install`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixReplay.Storage.Ecto.Event

  @doc """
  Appends a single `batch` of rrweb events at position `seq` for
  `session_id`. Returns `:ok` on success, `{:error, :conflict}` on a
  duplicate `{session_id, seq}` pair (safe to retry with a fresh seq).
  """
  @spec append(repo :: module(), session_id :: String.t(), seq :: non_neg_integer(),
               batch :: [map()]) :: :ok | {:error, :conflict | term()}
  def append(repo, session_id, seq, batch)
      when is_atom(repo) and is_binary(session_id) and is_integer(seq) and is_list(batch) do
    attrs = %{
      session_id: session_id,
      seq: seq,
      batch: batch,
      inserted_at: DateTime.utc_now()
    }

    try do
      case repo.insert_all(Event, [attrs],
             on_conflict: :nothing,
             conflict_target: [:session_id, :seq]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :conflict}
      end
    rescue
      e in Ecto.ConstraintError -> {:error, {:constraint, e}}
    end
  end

  @doc """
  Checks whether `session_id` is resumable based on event freshness.
  Shared by adapters that don't carry a separate session-state table
  (both shipped adapters use the events row itself as the liveness
  signal — no session row exists until `/submit`).

  Returns `{:ok, session_id, seq_watermark}` when the most recent
  event is newer than `idle_timeout_ms`, `{:error, :stale}` when the
  session exists but is too old, `{:error, :not_found}` when no
  event rows exist. Identity-binding is handled by the token in the
  caller.
  """
  @spec resume(repo :: module(), session_id :: String.t(),
               idle_timeout_ms :: non_neg_integer(), now :: DateTime.t()) ::
          {:ok, String.t(), non_neg_integer()}
          | {:error, :not_found | :stale}
  def resume(repo, session_id, idle_timeout_ms, now)
      when is_atom(repo) and is_binary(session_id) and is_integer(idle_timeout_ms) do
    cutoff = DateTime.add(now, -idle_timeout_ms, :millisecond)

    row =
      from(e in Event,
        where: e.session_id == ^session_id,
        order_by: [desc: e.seq],
        limit: 1,
        select: {e.seq, e.inserted_at}
      )
      |> repo.one()

    case row do
      nil ->
        {:error, :not_found}

      {seq, last_at} ->
        if DateTime.compare(last_at, cutoff) == :gt do
          {:ok, session_id, seq}
        else
          {:error, :stale}
        end
    end
  end

  @doc """
  Returns the ordered concatenation of every batch for `session_id`.
  The result is the flat list of rrweb events — ready to feed into
  `new rrwebPlayer({ events, ... })` on the client.
  """
  @spec fetch(repo :: module(), session_id :: String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch(repo, session_id) when is_atom(repo) and is_binary(session_id) do
    rows =
      from(e in Event,
        where: e.session_id == ^session_id,
        order_by: [asc: e.seq],
        select: e.batch
      )
      |> repo.all()

    {:ok, Enum.concat(rows)}
  end
end
