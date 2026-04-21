defmodule PhoenixReplay do
  @moduledoc """
  `PhoenixReplay` ingests [rrweb](https://github.com/rrweb-io/rrweb)
  session-replay events + console / network timelines from a client-side
  widget and hands them off to a pluggable storage backend.

  ## Concepts

    * **Session** — the span between a widget starting a recording and the
      user submitting (or the session TTL expiring). Identified by a
      server-minted `Phoenix.Token`.
    * **Event batch** — a chunk of rrweb events posted to
      `POST /events` during a session. Appended with a monotonic `seq`
      number per session.
    * **Feedback** — the finalized record created by `POST /submit`.
      Carries description, severity, host-supplied metadata, and a
      reference (inline JSONB or S3 key) to the underlying events.

  ## Wiring

      # config/config.exs
      config :phoenix_replay,
        identify: {MyApp.Auth, :fetch_identity, []},
        metadata: {MyApp, :feedback_metadata, 1},
        storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo},
        scrub: [
          console: [~r/Bearer [A-Za-z0-9._-]+/],
          query_deny_list: ~w(token password secret)
        ],
        limits: [
          max_batch_bytes: 1_048_576,
          batch_rate_per_minute: 30,
          session_ttl_seconds: 1_800
        ]

      # router.ex
      import PhoenixReplay.Router
      feedback_routes "/api/feedback"

  See `PhoenixReplay.Router`, `PhoenixReplay.Storage`, and
  `PhoenixReplay.Config` for the API contracts.
  """
end
