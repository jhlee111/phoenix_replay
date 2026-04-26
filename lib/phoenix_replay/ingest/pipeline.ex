defmodule PhoenixReplay.Ingest.Pipeline do
  @moduledoc false
  # Composable validation steps shared by /events, /submit, and /report.
  # Each step takes a `ctx :: map` and returns `{:ok, ctx}` or
  # `{:error, %Error{}}`. Controllers thread `with` over these steps and
  # collapse the `else` to a single `%Error{} -> respond/2` clause —
  # avoiding the "complex else clauses in `with`" Elixir anti-pattern
  # that comes from a `with` whose error sources have heterogeneous
  # shapes.

  alias PhoenixReplay.{RateLimiter, SessionToken}
  alias PhoenixReplay.Ingest.Error

  @token_header "x-phoenix-replay-session"

  @doc """
  Hits the rate limiter for the actor's bucket. Bucket tag and limit-key
  are configurable so /events and /report can keep distinct quotas.

  ## Options

    * `:bucket` — atom prefix of the rate-limiter key (e.g. `:report`,
      `:actor`).
    * `:limit_key` — keyword key under `ctx.limits` whose value is the
      per-minute limit.
    * `:default` — fallback limit when `:limit_key` is absent.
  """
  def check_actor_rate(ctx, opts) do
    bucket_tag = Keyword.fetch!(opts, :bucket)
    limit_key = Keyword.fetch!(opts, :limit_key)
    default = Keyword.fetch!(opts, :default)

    %{identity: identity, limits: limits} = ctx
    limit = Keyword.get(limits, limit_key, default)
    key = {bucket_tag, identity[:id] || identity[:kind] || :anonymous}

    case RateLimiter.hit(key, limit, 60) do
      :ok ->
        {:ok, ctx}

      {:error, :rate_limited, retry_after} ->
        {:error,
         Error.new(429, "rate_limited",
           headers: [{"retry-after", Integer.to_string(retry_after)}]
         )}
    end
  end

  @doc """
  Hits the rate limiter for a session-scoped bucket. Used by /events to
  cap per-session flush rate independently of the per-actor bucket.
  Requires `:session_id` in `ctx` (typically populated by `verify_token/1`).

  ## Options

    * `:limit_key` — keyword key under `ctx.limits` whose value is the
      per-minute limit.
    * `:default` — fallback limit when `:limit_key` is absent.
  """
  def check_session_rate(%{session_id: session_id, limits: limits} = ctx, opts) do
    limit_key = Keyword.fetch!(opts, :limit_key)
    default = Keyword.fetch!(opts, :default)

    limit = Keyword.get(limits, limit_key, default)

    case RateLimiter.hit({:session, session_id}, limit, 60) do
      :ok ->
        {:ok, ctx}

      {:error, :rate_limited, retry_after} ->
        {:error,
         Error.new(429, "rate_limited",
           headers: [{"retry-after", Integer.to_string(retry_after)}]
         )}
    end
  end

  @doc """
  Cheap content-length check — rejects bodies larger than the configured
  cap before the parser kicks in. Missing or unparseable header is a
  no-op (let the parser handle truly bad requests).

  ## Options

    * `:limit_key` — keyword key under `ctx.limits` (e.g.
      `:max_batch_bytes`, `:max_report_bytes`).
    * `:default` — fallback cap when `:limit_key` is absent.
  """
  def check_body_size(ctx, opts) do
    limit_key = Keyword.fetch!(opts, :limit_key)
    default = Keyword.fetch!(opts, :default)

    %{conn: conn, limits: limits} = ctx
    max = Keyword.get(limits, limit_key, default)

    case Plug.Conn.get_req_header(conn, "content-length") do
      # Header absent — body size unknown at this stage. Plug.Parsers
      # enforces the hard cap on the actual body downstream.
      [] ->
        {:ok, ctx}

      [value] ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 and n <= max -> {:ok, ctx}
          {n, ""} when n >= 0 -> {:error, Error.new(413, "body_too_large")}
          # Negative values, trailing garbage, and non-numeric headers
          # all collapse to 400 — a malformed content-length is malformed.
          _ -> {:error, Error.new(400, "invalid_content_length")}
        end

      # Conflicting content-length headers are a classic request-smuggling
      # signal — reject rather than silently picking one.
      [_, _ | _] ->
        {:error, Error.new(400, "invalid_content_length")}
    end
  end

  @doc """
  Pulls the session token off the `x-phoenix-replay-session` header and
  stashes it under `ctx.token`.
  """
  def fetch_token(%{conn: conn} = ctx) do
    case Plug.Conn.get_req_header(conn, @token_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 ->
        {:ok, Map.put(ctx, :token, token)}

      _ ->
        {:error, Error.new(401, "missing_session_token")}
    end
  end

  @doc """
  Verifies a previously-fetched token against the actor's identity and
  stashes the resolved `session_id` under `ctx.session_id`.
  """
  def verify_token(%{token: token, identity: identity} = ctx) do
    case SessionToken.verify(token, identity) do
      {:ok, session_id} -> {:ok, Map.put(ctx, :session_id, session_id)}
      {:error, :expired} -> {:error, Error.new(410, "session_expired")}
      {:error, :invalid} -> {:error, Error.new(401, "invalid_session_token")}
      {:error, :identity_mismatch} -> {:error, Error.new(401, "identity_mismatch")}
      {:error, :no_secret} -> {:error, Error.new(503, "not_configured")}
    end
  end

  @doc """
  Renders a `%Error{}` as a JSON response and halts the conn. Headers on
  the error (e.g. `retry-after` from rate limiting) are applied before
  the body is sent.
  """
  def respond(conn, %Error{} = err) do
    body = if err.detail, do: %{error: err.code, detail: err.detail}, else: %{error: err.code}

    conn =
      Enum.reduce(err.headers, conn, fn {k, v}, acc ->
        Plug.Conn.put_resp_header(acc, k, v)
      end)

    conn
    |> Plug.Conn.put_status(err.status)
    |> Phoenix.Controller.json(body)
    |> Plug.Conn.halt()
  end
end
