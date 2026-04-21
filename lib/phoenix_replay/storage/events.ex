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
