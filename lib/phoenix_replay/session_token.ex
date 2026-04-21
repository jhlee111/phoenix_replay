defmodule PhoenixReplay.SessionToken do
  @moduledoc """
  Signs / verifies session tokens that bind a `session_id` to the
  identity that started the recording.

  Tokens are opaque `Phoenix.Token` strings. Clients receive one on
  `POST /session` and carry it as `x-phoenix-replay-session` on every
  subsequent `POST /events` and `POST /submit`.

  The token payload embeds a truncated SHA-256 of the identity map so
  a stolen token cannot be replayed by a different actor — even one
  that happens to authenticate on the same browser.
  """

  alias PhoenixReplay.Config

  @salt "phoenix_replay.session"
  @default_ttl_seconds 1_800

  @type payload :: %{
          session_id: String.t(),
          identity_hash: String.t(),
          issued_at: non_neg_integer()
        }

  @doc """
  Mints a session token binding `session_id` to the given `identity`.

  Returns the opaque token string. Sessions are rejected if
  `session_token_secret` is not configured.
  """
  @spec mint(session_id :: String.t(), identity :: map(), now :: DateTime.t()) ::
          {:ok, String.t()} | {:error, :no_secret}
  def mint(session_id, identity, now \\ DateTime.utc_now()) do
    with {:ok, secret} <- fetch_secret() do
      payload = %{
        session_id: session_id,
        identity_hash: identity_hash(identity),
        issued_at: DateTime.to_unix(now)
      }

      {:ok, Phoenix.Token.sign(secret, @salt, payload, max_age: ttl())}
    end
  end

  @doc """
  Verifies a token, returning the bound `session_id` on success.

  Rejects if the token was signed for a different identity, or if
  it is older than `session_ttl_seconds`.

    * `{:error, :expired}` — token older than TTL; client should mint a fresh one
    * `{:error, :invalid}`  — forged or malformed token
    * `{:error, :identity_mismatch}` — token was not signed for this actor
    * `{:error, :no_secret}` — `session_token_secret` not configured
  """
  @spec verify(token :: String.t(), identity :: map()) ::
          {:ok, String.t()}
          | {:error, :expired | :invalid | :identity_mismatch | :no_secret}
  def verify(token, identity) when is_binary(token) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, payload} <- verify_token(secret, token) do
      cond do
        payload.identity_hash != identity_hash(identity) -> {:error, :identity_mismatch}
        true -> {:ok, payload.session_id}
      end
    end
  end

  def verify(_, _), do: {:error, :invalid}

  defp verify_token(secret, token) do
    case Phoenix.Token.verify(secret, @salt, token, max_age: ttl()) do
      {:ok, payload} -> {:ok, payload}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp fetch_secret do
    case Config.session_token_secret() do
      nil -> {:error, :no_secret}
      secret when is_binary(secret) and byte_size(secret) >= 16 -> {:ok, secret}
      _ -> {:error, :no_secret}
    end
  end

  defp ttl do
    Keyword.get(Config.limits(), :session_ttl_seconds, @default_ttl_seconds)
  end

  @doc false
  @spec identity_hash(map()) :: String.t()
  def identity_hash(identity) do
    # Canonicalize keys and values so tokens survive atom vs string flips
    # from the identify hook. Truncated to 16 bytes — collision-resistant
    # enough for a replay-prevention side-channel.
    canonical = identity |> to_canonical() |> :erlang.term_to_binary()

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp to_canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_canonical(v)} end)
    |> Enum.sort()
  end

  defp to_canonical(list) when is_list(list), do: Enum.map(list, &to_canonical/1)
  defp to_canonical(atom) when is_atom(atom) and not is_nil(atom) and atom not in [true, false],
    do: to_string(atom)

  defp to_canonical(other), do: other

  @doc """
  Generates a fresh, URL-safe session id.

  Session ids are opaque to the client — they're returned by the
  storage adapter's `start_session/2` callback.
  """
  @spec new_session_id() :: String.t()
  def new_session_id do
    # 16 bytes → 22 url-safe base64 chars; low collision with >10^38 space.
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
