defmodule PhoenixReplay.SessionTokenTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.SessionToken

  setup do
    prev_secret = Application.get_env(:phoenix_replay, :session_token_secret)
    prev_limits = Application.get_env(:phoenix_replay, :limits)

    Application.put_env(:phoenix_replay, :session_token_secret, String.duplicate("a", 32))

    on_exit(fn ->
      if prev_secret,
        do: Application.put_env(:phoenix_replay, :session_token_secret, prev_secret),
        else: Application.delete_env(:phoenix_replay, :session_token_secret)

      if prev_limits,
        do: Application.put_env(:phoenix_replay, :limits, prev_limits),
        else: Application.delete_env(:phoenix_replay, :limits)
    end)

    :ok
  end

  test "mint/verify round-trip recovers session_id for same identity" do
    identity = %{kind: :user, id: "usr_1", attrs: %{tenant_id: "t1"}}

    {:ok, token} = SessionToken.mint("sess_abc", identity)
    assert {:ok, "sess_abc"} = SessionToken.verify(token, identity)
  end

  test "verify rejects a different identity with :identity_mismatch" do
    identity_a = %{kind: :user, id: "usr_a", attrs: %{}}
    identity_b = %{kind: :user, id: "usr_b", attrs: %{}}

    {:ok, token} = SessionToken.mint("sess_1", identity_a)
    assert {:error, :identity_mismatch} = SessionToken.verify(token, identity_b)
  end

  test "atom vs string key in identity attrs produces same hash" do
    atom_identity = %{kind: :user, id: "usr_1", attrs: %{tenant_id: "t1"}}
    string_identity = %{"kind" => :user, "id" => "usr_1", "attrs" => %{"tenant_id" => "t1"}}

    assert SessionToken.identity_hash(atom_identity) ==
             SessionToken.identity_hash(string_identity)
  end

  test "mint returns :no_secret when session_token_secret is missing" do
    Application.delete_env(:phoenix_replay, :session_token_secret)
    assert {:error, :no_secret} = SessionToken.mint("s", %{kind: :anonymous})
  end

  test "new_session_id produces distinct values" do
    ids = for _ <- 1..100, do: SessionToken.new_session_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "verify rejects garbage" do
    assert {:error, :invalid} = SessionToken.verify("garbage", %{kind: :anonymous})
    assert {:error, :invalid} = SessionToken.verify(nil, %{kind: :anonymous})
  end

  test "verify rejects expired tokens past max_age" do
    # Override TTL to 0 so any freshly-minted token is immediately expired.
    Application.put_env(:phoenix_replay, :limits, session_ttl_seconds: 0)

    {:ok, token} = SessionToken.mint("sess_exp", %{kind: :user, id: "u"})
    # Phoenix.Token max_age: 0 produces :expired on the next clock tick.
    :timer.sleep(1_100)
    assert {:error, :expired} = SessionToken.verify(token, %{kind: :user, id: "u"})
  end
end
