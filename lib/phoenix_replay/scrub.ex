defmodule PhoenixReplay.Scrub do
  @moduledoc """
  Applies PII scrubbing rules to event payloads before storage.

  Rules come from `config :phoenix_replay, :scrub` (see
  `PhoenixReplay.Config`). Defaults drop bearer tokens and common
  secret-name query params.

  Request/response bodies are **never** captured in v0 regardless of
  scrub config.
  """

  # Implementation lands in Phase 2.
end
