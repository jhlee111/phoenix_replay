defmodule PhoenixReplay.Router do
  @moduledoc """
  Router helper for mounting the PhoenixReplay ingest endpoints.

  ## Usage

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import PhoenixReplay.Router

        # ...

        scope "/api" do
          pipe_through :api
          feedback_routes "/feedback"
        end
      end

  This mounts three endpoints under the given path:

    * `POST /session` — mint a server-signed session token for a new
      recording.
    * `POST /events`  — append a batch of rrweb events to an open session.
    * `POST /submit`  — finalize the session into a `Feedback` record.

  ## Options

    * `:pipe_through` — additional pipelines to apply to the mounted
      routes (default: none beyond the enclosing scope).
    * `:admin_live` — when `true`, also mounts
      `PhoenixReplay.UI.FeedbackLive` at `\#{path}/admin` for
      zero-config admin usage (default: `false`).
  """

  defmacro feedback_routes(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      scope path, PhoenixReplay do
        pipe_through [PhoenixReplay.Plug.Identify]

        post "/session", SessionController, :create
        post "/events", EventsController, :append
        post "/submit", SubmitController, :create
      end

      _ = opts
    end
  end
end
