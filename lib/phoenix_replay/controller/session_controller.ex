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

  def create(conn, params) do
    identity = Identify.fetch(conn)
    now = DateTime.utc_now()
    token = fetch_carry_token(conn)

    case SessionResume.run(token, identity, now) do
      {:ok, session_id, seq_watermark} ->
        maybe_record_clock_offset(session_id, params)
        mint_response(conn, identity, session_id, resumed: true, seq_watermark: seq_watermark)

      :fresh ->
        with {:ok, session_id} <- Storage.Dispatch.start_session(identity, now),
             {:ok, _pid} <- Session.start_session(session_id, identity, seq_watermark: 0) do
          maybe_record_clock_offset(session_id, params)
          mint_response(conn, identity, session_id, resumed: false, seq_watermark: 0)
        else
          {:error, reason} -> reason_error(conn, reason)
        end
    end
  end

  # ADR-0007: record clock offset for server-origin capture streams.
  # Called once per session on /session POST after Session.start_session
  # has run. The Session GenServer subtracts client_started_at_ms from
  # System.system_time(:millisecond) at call time and stores the result
  # as state.clock_offset, used at flush_for_session/1 to convert
  # server-time to browser timeline.
  defp maybe_record_clock_offset(session_id, %{"client_started_at_ms" => ms})
       when is_integer(ms) do
    case Session.pid_for(session_id) do
      nil -> :ok
      pid -> Session.record_clock_offset(pid, ms)
    end
  end

  defp maybe_record_clock_offset(_session_id, _), do: :ok

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
        # ADR-0007: cookie is the cross-pipeline bridge to LV mounts.
        # Host's :browser pipeline sees this cookie automatically;
        # PhoenixReplay.Plug.SessionLink copies it into Plug.Session
        # so LV mount/3's session arg surfaces phx_replay_session_id.
        |> put_resp_cookie("phx_replay_session_id", session_id,
          http_only: true,
          same_site: "Lax",
          secure: conn.scheme == :https,
          path: "/"
        )
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
