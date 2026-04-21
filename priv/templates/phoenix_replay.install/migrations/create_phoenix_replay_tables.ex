defmodule <%= @module %> do
  use Ecto.Migration

  def change do
    create table(:phoenix_replay_feedbacks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :description, :text
      add :severity, :string
      add :events_s3_key, :string
      add :metadata, :jsonb, default: fragment("'{}'::jsonb"), null: false
      add :identity, :jsonb, default: fragment("'{}'::jsonb"), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:phoenix_replay_feedbacks, [:session_id])

    create table(:phoenix_replay_events) do
      add :session_id, :string, null: false
      add :seq, :integer, null: false
      add :batch, :jsonb, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:phoenix_replay_events, [:session_id, :seq])
    create index(:phoenix_replay_events, [:inserted_at])
  end
end
