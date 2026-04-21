defmodule PhoenixReplay.SessionController do
  @moduledoc false
  # POST /session — mints a session token binding identity to a fresh
  # session_id. Identity is provided by the `Identify` plug (host hook).

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{SessionToken, Storage}
  alias PhoenixReplay.Plug.Identify

  def create(conn, _params) do
    identity = Identify.fetch(conn)

    with {:ok, session_id} <- Storage.Dispatch.start_session(identity, DateTime.utc_now()),
         {:ok, token} <- SessionToken.mint(session_id, identity) do
      conn
      |> put_status(:ok)
      |> json(%{token: token, session_id: session_id})
    else
      {:error, :no_secret} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "phoenix_replay not configured"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "start_session_failed", reason: inspect(reason)})
    end
  end
end
