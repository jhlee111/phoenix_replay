defmodule PhoenixReplay.Storage.Ecto do
  @moduledoc """
  Default storage adapter. Writes:

    * one row into `phoenix_replay_feedbacks` per submission
    * one row per event batch into `phoenix_replay_events`
      (append-only, unique on `(session_id, seq)`)

  Past a configurable size threshold, a background job collapses a
  session's event rows into a single S3 blob and populates
  `events_s3_key` on the parent — see `PhoenixReplay.Storage.S3`.

  ## Configuration

      config :phoenix_replay,
        storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo}
  """

  @behaviour PhoenixReplay.Storage

  # Implementation lands in Phase 2.

  @impl true
  def start_session(_identity, _now), do: {:error, :not_implemented}

  @impl true
  def append_events(_session_id, _seq, _batch), do: {:error, :not_implemented}

  @impl true
  def submit(_session_id, _params, _identity), do: {:error, :not_implemented}

  @impl true
  def fetch_feedback(_id, _opts), do: {:error, :not_implemented}

  @impl true
  def fetch_events(_session_id), do: {:error, :not_implemented}

  @impl true
  def list(_filters, _pagination), do: {:error, :not_implemented}
end
