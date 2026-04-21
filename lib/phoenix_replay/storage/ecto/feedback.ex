defmodule PhoenixReplay.Storage.Ecto.Feedback do
  @moduledoc false
  # Ecto schema for the `phoenix_replay_feedbacks` parent row.
  #
  # One row per finalized submission. Events (rrweb stream) live in the
  # child table `phoenix_replay_events`, joined on `session_id`.

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "phoenix_replay_feedbacks" do
    field :session_id, :string
    field :description, :string
    field :severity, :string
    field :events_s3_key, :string
    field :metadata, :map, default: %{}
    field :identity, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:session_id, :description, :severity, :events_s3_key, :metadata, :identity])
    |> validate_required([:session_id])
    |> unique_constraint(:session_id)
  end
end
