defmodule PhoenixReplay.Plug.SessionLinkTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias PhoenixReplay.Plug.SessionLink

  @session_options Plug.Session.init(
                     store: :cookie,
                     key: "_test_session",
                     signing_salt: "saltsaltsalt",
                     encryption_salt: "encsaltencsalt"
                   )

  defp pipeline(conn) do
    conn
    |> Map.put(:secret_key_base, String.duplicate("x", 64))
    |> Plug.Session.call(@session_options)
    |> Plug.Conn.fetch_session()
  end

  test "copies cookie value into session when present" do
    conn =
      :get
      |> conn("/")
      |> Plug.Test.put_req_cookie("phx_replay_session_id", "session-abc")
      |> pipeline()
      |> SessionLink.call(SessionLink.init([]))

    assert Plug.Conn.get_session(conn, "phx_replay_session_id") == "session-abc"
  end

  test "no-op when cookie missing" do
    conn =
      :get
      |> conn("/")
      |> pipeline()
      |> SessionLink.call(SessionLink.init([]))

    assert Plug.Conn.get_session(conn, "phx_replay_session_id") == nil
  end

  test "silent no-op when fetch_session was not run before" do
    # If host orders the plug before :fetch_session, put_session/3
    # raises. Our plug should rescue cleanly rather than crash the
    # request pipeline.
    conn =
      :get
      |> conn("/")
      |> Plug.Test.put_req_cookie("phx_replay_session_id", "session-abc")
      |> Map.put(:secret_key_base, String.duplicate("x", 64))

    # No fetch_session, no Plug.Session
    _conn = SessionLink.call(conn, SessionLink.init([]))
    # If the call above raised, the test would fail. No assertion needed.
  end
end
