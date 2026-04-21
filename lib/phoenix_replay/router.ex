defmodule PhoenixReplay.Router do
  @moduledoc """
  Router helpers for mounting the PhoenixReplay ingest + admin
  endpoints.

  ## Ingest

      scope "/api" do
        pipe_through :feedback_ingest
        feedback_routes "/feedback"
      end

  Mounts three POST endpoints under `path` guarded by
  `PhoenixReplay.Plug.Identify`:

    * `POST /session` — mint a server-signed session token for a new
      recording.
    * `POST /events`  — append a batch of rrweb events to an open session.
    * `POST /submit`  — finalize the session into a `Feedback` record.

  ## Admin

      scope "/admin" do
        pipe_through [:browser, :admin_auth]
        admin_routes "/feedback"
      end

  Mounts three GET endpoints for listing, viewing, and playing back
  feedback records. Authorization is the **host's** responsibility —
  the macro adds no auth plug, only the controller routes.

    * `GET /`                       — list JSON (filters, pagination)
    * `GET /:id`                    — feedback detail JSON
    * `GET /events/:session_id`     — rrweb event stream JSON

  ## Options (feedback_routes)

    * `:pipe_through` — additional pipelines to apply beyond the
      enclosing scope (default: none).
  """

  defmacro feedback_routes(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      scope path, alias: false do
        pipe_through [PhoenixReplay.Plug.Identify]

        post "/session", PhoenixReplay.SessionController, :create
        post "/events", PhoenixReplay.EventsController, :append
        post "/submit", PhoenixReplay.SubmitController, :create
      end

      _ = opts
    end
  end

  @doc """
  Mounts the admin JSON endpoints at `path`. Intended to sit inside a
  scope whose `pipe_through` already enforces admin-level access.
  """
  defmacro admin_routes(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      # alias: false so the admin controller resolves absolutely,
      # regardless of any outer `scope "/admin", MyApp.Admin do` wrapping.
      scope path, alias: false do
        get "/events/:session_id", PhoenixReplay.AdminController, :events
        get "/:id/json", PhoenixReplay.AdminController, :show
        get "/json", PhoenixReplay.AdminController, :index
      end

      _ = opts
    end
  end
end
