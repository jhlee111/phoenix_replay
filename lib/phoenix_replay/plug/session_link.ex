defmodule PhoenixReplay.Plug.SessionLink do
  @moduledoc """
  Bridges phoenix_replay's session_id cookie into the host's
  `Plug.Session` so LiveView mounts can read it from `session` arg.

  ## Why

  The phoenix_replay widget POSTs to `/session` via a separate
  pipeline (`:feedback_ingest`) that does not share state with the
  host's `:browser` pipeline. The widget receives a session_id in
  the JSON response. To make that session_id available inside host
  LiveViews — so `PhoenixReplay.LiveView.Snapshots.on_mount` can
  register the LV process under the recording session — we cookie
  it at `/session` response time and copy it into the host's
  session here.

  ## Installation

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug Plug.Session, @session_options  # whatever the host has
        plug PhoenixReplay.Plug.SessionLink   # ← add this line
        plug :fetch_live_flash
        # ...
      end

  Order matters: this plug must run after `:fetch_session` (so
  `put_session/3` is callable). If misordered, this plug becomes a
  silent no-op rather than crashing the host's pipeline.

  ## Cookie name

  The cookie is `phx_replay_session_id`. Set by
  `PhoenixReplay.SessionController` after a successful `/session`
  POST.
  """

  @cookie_name "phx_replay_session_id"
  @session_key "phx_replay_session_id"

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.cookies[@cookie_name] do
      nil ->
        conn

      session_id when is_binary(session_id) ->
        try do
          Plug.Conn.put_session(conn, @session_key, session_id)
        rescue
          # If :fetch_session hasn't run, put_session/3 raises with
          # an opaque error. Silent no-op is preferable to crashing
          # the host's pipeline — the LV will simply not capture
          # state, identical to the not-installed case.
          ArgumentError -> conn
        end
    end
  end
end
