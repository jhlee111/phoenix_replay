defmodule PhoenixReplay.TestRouter do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_secure_browser_headers
  end

  scope "/", PhoenixReplay.Live do
    pipe_through :browser

    live "/sessions/:id/live", SessionWatch, :watch
  end
end
