defmodule PhoenixReplay.SessionController do
  @moduledoc false
  # POST /session — mints a session token binding identity to a fresh
  # session_id. If the client carries a prior token in the
  # `x-phoenix-replay-session` header, try to resume the session
  # instead of minting fresh.
  #
  # Resume order (ADR-0003 Phase 2):
  #   1. Registry lookup of `PhoenixReplay.Session` — alive process →
  #      ask it for `seq_watermark/1`, no DB hit needed.
  #   2. Storage adapter `resume_session/2` — covers the
  #      crash-restart case (process died, but the events table still
  #      has rows). On success, spawn a fresh Session process seeded
  #      with the persisted watermark.
  #   3. Fresh-mint — `start_session/2` + spawn a Session.
  #
  # Response shape:
  #   %{token, session_id, resumed :: boolean, seq_watermark :: integer}
  #
  # `resumed: true` ⇒ reuse `session_id`; client keeps numbering from
  # `seq_watermark + 1`. `resumed: false` ⇒ fresh session; client
  # must discard any cached token.

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Session, SessionToken, Storage}
  alias PhoenixReplay.Plug.Identify

  @resume_header "x-phoenix-replay-session"

  def create(conn, _params) do
    identity = Identify.fetch(conn)
    now = DateTime.utc_now()

    case attempt_resume(conn, identity, now) do
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

  # Any failure in the resume chain — no header, bad token, stale
  # session, identity mismatch — collapses to `:fresh`, which routes
  # the caller to the standard mint path. Fresh-session errors are
  # surfaced separately so we don't mask real storage problems.
  defp attempt_resume(conn, identity, now) do
    with [token | _] <- get_req_header(conn, @resume_header),
         {:ok, session_id} <- SessionToken.verify(token, identity),
         {:ok, ^session_id, seq_watermark} <- resolve_resume(session_id, identity, now) do
      {:ok, session_id, seq_watermark}
    else
      _ -> :fresh
    end
  end

  # Registry-first, DB-fallback. The DB-fallback branch also spawns
  # a Session process so subsequent /events POSTs find it without
  # another lookup-or-start round-trip.
  defp resolve_resume(session_id, identity, now) do
    case Session.seq_watermark(session_id) do
      {:ok, watermark} ->
        {:ok, session_id, watermark}

      {:error, :no_session} ->
        case Storage.Dispatch.resume_session(session_id, now) do
          {:ok, ^session_id, watermark} ->
            with {:ok, _pid} <-
                   Session.start_session(session_id, identity, seq_watermark: watermark) do
              {:ok, session_id, watermark}
            end

          {:error, _} = err ->
            err
        end
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
