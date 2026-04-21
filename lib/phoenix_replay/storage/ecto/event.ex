defmodule PhoenixReplay.Storage.Ecto.Event do
  @moduledoc false
  # Ecto schema for the `phoenix_replay_events` append-only child table.
  #
  # Each row is one batch posted to `/events` — a list of rrweb events
  # under `batch`. Concurrent appends are protected by the unique index
  # on `(session_id, seq)`.

  use Ecto.Schema

  schema "phoenix_replay_events" do
    field :session_id, :string
    field :seq, :integer
    field :batch, {:array, :map}
    field :inserted_at, :utc_datetime_usec
  end
end
