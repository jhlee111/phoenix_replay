defmodule PhoenixReplay.TestEndpoint do
  @moduledoc false
  # Minimal Phoenix.Endpoint used exclusively by LV tests in this
  # library. Hosts should never reach this module — it exists only so
  # `Phoenix.LiveViewTest.live/2` has a real endpoint + router to
  # dispatch against.

  use Phoenix.Endpoint, otp_app: :phoenix_replay

  @session_options [
    store: :cookie,
    key: "_phoenix_replay_test_key",
    signing_salt: "test-salt-phoenix-replay"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug PhoenixReplay.TestRouter
end
