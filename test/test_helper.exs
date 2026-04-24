ExUnit.start()

# Start a Phoenix.Endpoint used by LiveView tests. Hosts don't run
# this — it exists purely so `Phoenix.LiveViewTest.live/2` can
# dispatch against real routes against a real LV socket.
Application.put_env(:phoenix_replay, PhoenixReplay.TestEndpoint,
  server: false,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test-salt-phoenix-replay"],
  render_errors: [formats: [html: Phoenix.Controller]]
)

{:ok, _} = Supervisor.start_link([PhoenixReplay.TestEndpoint], strategy: :one_for_one)

