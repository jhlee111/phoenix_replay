defmodule PhoenixReplay.SessionToken do
  @moduledoc """
  Signs / verifies session tokens that bind a `session_id` to the
  identity that started the recording.

  Tokens are opaque `Phoenix.Token` strings. Clients receive one on
  `POST /session` and carry it as `x-phoenix-replay-session` on every
  subsequent `POST /events` and `POST /submit`.

  This module is the boundary that prevents cross-session injection —
  the events endpoint never trusts a client-chosen session_id URL
  segment.
  """

  # Implementation lands in Phase 2.
end
