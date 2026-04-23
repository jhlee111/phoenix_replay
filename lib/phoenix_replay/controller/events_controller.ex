defmodule PhoenixReplay.EventsController do
  @moduledoc false
  # POST /events — appends a single batch of rrweb events to an open
  # session. Enforces token validity + rate limits + body-size cap +
  # scrub, then delegates to the storage adapter.

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Config, RateLimiter, Scrub, Session, SessionToken}
  alias PhoenixReplay.Plug.Identify

  @token_header "x-phoenix-replay-session"

  @default_limits [
    max_batch_bytes: 1_048_576,
    batch_rate_per_minute: 30,
    actor_rate_per_minute: 300
  ]

  def append(conn, params) do
    identity = Identify.fetch(conn)
    limits = Keyword.merge(@default_limits, Config.limits())

    with :ok <- check_actor_rate(identity, limits),
         {:ok, token} <- fetch_token(conn),
         {:ok, session_id} <- SessionToken.verify(token, identity),
         :ok <- check_session_rate(session_id, limits),
         :ok <- check_body_size(conn, limits),
         {:ok, seq, batch} <- parse_payload(params) do
      scrubbed = Scrub.scrub_batch(batch)

      with {:ok, _pid} <- Session.lookup_or_start(session_id, identity),
           :ok <- Session.append_events(session_id, seq, scrubbed) do
        json(conn, %{ok: true, seq: seq})
      else
        {:error, :conflict} -> send_error(conn, 409, "seq_conflict")
        {:error, :no_session} -> send_error(conn, 410, "session_expired")
        {:error, other} -> send_error(conn, 500, "append_failed", inspect(other))
      end
    else
      {:error, :missing_token} -> send_error(conn, 401, "missing_session_token")
      {:error, :expired} -> send_error(conn, 410, "session_expired")
      {:error, :invalid} -> send_error(conn, 401, "invalid_session_token")
      {:error, :identity_mismatch} -> send_error(conn, 401, "identity_mismatch")
      {:error, :no_secret} -> send_error(conn, 503, "not_configured")
      {:error, :body_too_large} -> send_error(conn, 413, "body_too_large")
      {:error, :invalid_payload} -> send_error(conn, 400, "invalid_payload")
      {:error, :rate_limited, retry_after} ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_error(429, "rate_limited")
    end
  end

  defp fetch_token(conn) do
    case get_req_header(conn, @token_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp check_actor_rate(identity, limits) do
    limit = Keyword.get(limits, :actor_rate_per_minute, 300)
    key = {:actor, identity[:id] || identity[:kind] || :anonymous}
    RateLimiter.hit(key, limit, 60)
  end

  defp check_session_rate(session_id, limits) do
    limit = Keyword.get(limits, :batch_rate_per_minute, 30)
    RateLimiter.hit({:session, session_id}, limit, 60)
  end

  defp check_body_size(conn, limits) do
    max = Keyword.get(limits, :max_batch_bytes, 1_048_576)

    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {n, _} when n <= max -> :ok
          {_, _} -> {:error, :body_too_large}
          :error -> :ok
        end

      _ ->
        :ok
    end
  end

  defp parse_payload(params) do
    case params do
      %{"seq" => seq, "events" => events} when is_integer(seq) and is_list(events) ->
        {:ok, seq, events}

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp send_error(conn, status, code, detail \\ nil) do
    body = if detail, do: %{error: code, detail: detail}, else: %{error: code}

    conn
    |> put_status(status)
    |> json(body)
    |> halt()
  end
end
