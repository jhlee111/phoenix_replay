defmodule PhoenixReplay.Plug.Identify do
  @moduledoc """
  Plug that invokes the configured `identify` hook (see
  `PhoenixReplay.Config`) and stashes the resulting identity under
  `conn.assigns[:phoenix_replay_identity]`.

  Rejects requests with `401` when the hook returns `nil`.
  """

  # Implementation lands in Phase 2.
end
