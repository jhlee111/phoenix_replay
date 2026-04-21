defmodule PhoenixReplay.Config do
  @moduledoc """
  Runtime configuration access for PhoenixReplay.

  Configuration lives under the `:phoenix_replay` OTP app. All keys have
  sensible defaults for staging-only use; production deployments should
  override at least `identify`, `storage`, and `session_token_secret`.

  ## Keys

    * `:identify` — `{mod, fun, args}` | `(Plug.Conn.t -> identity | nil)`.
      Called on `POST /session` to resolve the acting identity. Returning
      `nil` rejects the session with `401`. Identity shape is
      `%{kind: atom, id: String.t() | nil, attrs: map()}`.

    * `:metadata` — `{mod, fun, args}` | `(Plug.Conn.t -> map)`. Called
      at `POST /submit` to enrich the feedback record. MUST return a map
      with string keys (so JSONB serialization round-trips cleanly).
      Defaults to `%{}`.

    * `:storage` — `{module, keyword}`. `module` implements
      `PhoenixReplay.Storage`; keyword is adapter-specific config.
      Default: `{PhoenixReplay.Storage.Ecto, []}`.

    * `:scrub` — keyword of PII scrubbing rules:
        * `:console` — list of regexes to replace in console output.
        * `:query_deny_list` — list of query-string keys whose values are
          dropped from captured URLs.
      Defaults ship a sensible baseline (bearer tokens, common secret
      names).

    * `:limits` — keyword of DoS-prevention caps:
        * `:max_batch_bytes` (default: 1 MB)
        * `:max_events_per_session` (default: 50,000)
        * `:batch_rate_per_minute` (default: 30 per session)
        * `:actor_rate_per_minute` (default: 300 per actor)
        * `:session_ttl_seconds` (default: 1800)

    * `:session_token_secret` — required. Used by
      `PhoenixReplay.SessionToken` to sign session tokens. Keep in an
      environment variable; rotating invalidates in-flight sessions
      (acceptable for staging).

  ## Example

      config :phoenix_replay,
        identify: {MyApp.Auth, :fetch_identity, []},
        metadata: {MyApp, :feedback_metadata, 1},
        storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo},
        scrub: [
          console: [~r/Bearer [A-Za-z0-9._-]+/],
          query_deny_list: ~w(token access_token password secret code)
        ],
        session_token_secret: System.fetch_env!("PHOENIX_REPLAY_TOKEN_SALT")
  """

  @doc false
  def identify_hook, do: fetch(:identify)

  @doc false
  def metadata_hook, do: fetch(:metadata, {__MODULE__, :empty_map, []})

  @doc false
  def storage, do: fetch(:storage, {PhoenixReplay.Storage.Ecto, []})

  @doc false
  def scrub, do: fetch(:scrub, [])

  @doc false
  def limits, do: fetch(:limits, [])

  @doc false
  def session_token_secret, do: fetch(:session_token_secret)

  @doc false
  def empty_map(_conn), do: %{}

  defp fetch(key, default \\ nil),
    do: Application.get_env(:phoenix_replay, key, default)
end
