defmodule PhoenixReplay.Storage.S3 do
  @moduledoc """
  Opt-in S3 collapser. For sessions that exceed
  `config :phoenix_replay, limits: [events_inline_threshold: _]`
  (default 1 MB), a background job reads the event rows for the session,
  gzips + encodes them, uploads to S3, and sets `events_s3_key` on the
  parent feedback row. The corresponding event rows can then be pruned.

  Not a full storage adapter — it works alongside
  `PhoenixReplay.Storage.Ecto`.
  """

  # Implementation lands in Phase 2 / post-MVP.
end
