defmodule PhoenixReplay.SessionController do
  @moduledoc false
  # POST /session — mints a session token binding identity to a fresh
  # session_id. If the client carries a prior token in the
  # `x-phoenix-replay-session` header, try to resume the session via
  # `PhoenixReplay.SessionResume` instead of minting fresh.
  #
  # Response shape:
  #   %{token, session_id, resumed :: boolean, seq_watermark :: integer}
  #
  # `resumed: true` ⇒ reuse `session_id`; client keeps numbering from
  # `seq_watermark + 1`. `resumed: false` ⇒ fresh session; client
  # must discard any cached token.

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Session, SessionResume, SessionToken, Storage}
  alias PhoenixReplay.Plug.Identify

  @resume_header "x-phoenix-replay-session"

  def create(conn, _params) do
    identity = Identify.fetch(conn)
    now = DateTime.utc_now()
    token = fetch_carry_token(conn)

    case SessionResume.run(token, identity, now) do
      {:ok, session_id, seq_watermark} ->
        mint_response(conn, identity, session_id, resumed: true, seq_watermark: seq_watermark)

      :fresh ->
        with {:ok, session_id} <- Storage.Dispatch.start_session(identity, now),
             {:ok, _pid} <- Session.start_session(session_id, identity, seq_watermark: 0) do
          mint_response(conn, identity, session_id, resumed: false, seq_watermark: 0)
        else
          {:error, reason} -> reason_error(conn, reason)
        end
    end
  end

  defp fetch_carry_token(conn) do
    case get_req_header(conn, @resume_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp mint_response(conn, identity, session_id, opts) do
    case SessionToken.mint(session_id, identity) do
      {:ok, token} ->
        conn
        |> put_status(:ok)
        |> json(%{
          token: token,
          session_id: session_id,
          resumed: Keyword.fetch!(opts, :resumed),
          seq_watermark: Keyword.fetch!(opts, :seq_watermark)
        })

      {:error, reason} ->
        reason_error(conn, reason)
    end
  end

  defp reason_error(conn, :no_secret) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "phoenix_replay not configured"})
  end

  defp reason_error(conn, reason) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "start_session_failed", reason: inspect(reason)})
  end
end
