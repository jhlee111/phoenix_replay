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

      # Triage fields (ADR-0118) — present from the initial install so
      # hosts don't need a second migration step.
      add :status, :string, null: false, default: "new"
      add :priority, :string
      add :assignee_id, :binary_id
      add :pr_urls, {:array, :string}, null: false, default: []
      add :triage_notes, :text
      add :reported_on_env, :string
      add :verified_by_id, :binary_id
      add :verified_at, :utc_datetime_usec
      add :resolved_by_id, :binary_id
      add :resolved_at, :utc_datetime_usec
      add :dismissed_reason, :string
      add :related_to_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:phoenix_replay_feedbacks, [:session_id])
    create index(:phoenix_replay_feedbacks, [:status])
    create index(:phoenix_replay_feedbacks, [:assignee_id])
    create index(:phoenix_replay_feedbacks, [:reported_on_env])

    create table(:phoenix_replay_events) do
      add :session_id, :string, null: false
      add :seq, :integer, null: false
      add :batch, :jsonb, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:phoenix_replay_events, [:session_id, :seq])
    create index(:phoenix_replay_events, [:inserted_at])

    # Triage comments (ADR-0118) — append-only conversation thread on
    # feedback rows.
    create table(:phoenix_replay_feedback_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :feedback_id, :binary_id, null: false
      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:phoenix_replay_feedback_comments, [:feedback_id])
  end
end
