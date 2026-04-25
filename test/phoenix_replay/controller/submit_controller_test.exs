defmodule PhoenixReplay.SubmitControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias PhoenixReplay.{SessionToken, Storage}
  alias PhoenixReplay.Test.RecordingStorage

  @identity %{kind: :user, id: "u-test", attrs: %{}}
  @token_header "x-phoenix-replay-session"

  setup do
    start_supervised!(RecordingStorage)

    prior_storage = Application.get_env(:phoenix_replay, :storage)
    prior_secret = Application.get_env(:phoenix_replay, :session_token_secret)

    Application.put_env(:phoenix_replay, :storage, {RecordingStorage, []})
    Application.put_env(:phoenix_replay, :session_token_secret, String.duplicate("s", 32))

    on_exit(fn ->
      restore(:storage, prior_storage)
      restore(:session_token_secret, prior_secret)
    end)

    {:ok, session_id} = Storage.Dispatch.start_session(@identity, DateTime.utc_now())
    {:ok, token} = SessionToken.mint(session_id, @identity)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(@token_header, token)
      |> assign(:phoenix_replay_identity, @identity)
      |> Phoenix.Controller.accepts(["json"])

    %{conn: conn, session_id: session_id, token: token}
  end

  describe "POST /submit — extras passthrough" do
    test "forwards extras map into submit_params reaching the Storage adapter", %{
      conn: conn,
      session_id: session_id
    } do
      extras = %{"audio_url" => "https://cdn.example.com/clip.webm", "duration_ms" => 4200}

      params = %{
        "description" => "bug",
        "severity" => "high",
        "extras" => extras
      }

      conn = PhoenixReplay.SubmitController.create(conn, params)

      assert conn.status == 201
      assert %{"ok" => true} = json_response(conn, 201)

      assert {^session_id, submit_params, _identity} = RecordingStorage.last_submit()
      assert submit_params["extras"] == extras
    end

    test "extras defaults to empty map when not provided", %{conn: conn, session_id: session_id} do
      conn = PhoenixReplay.SubmitController.create(conn, %{"description" => "no extras"})

      assert conn.status == 201

      assert {^session_id, submit_params, _identity} = RecordingStorage.last_submit()
      assert submit_params["extras"] == %{}
    end

    test "stringifies atom-keyed extras", %{conn: conn, session_id: session_id} do
      # JSON decode always produces string keys, but guard against the
      # edge case where atom-keyed maps arrive (e.g. from server-side callers).
      params = %{"description" => "test", "extras" => %{audio_url: "s3://bucket/key"}}

      conn = PhoenixReplay.SubmitController.create(conn, params)

      assert conn.status == 201

      assert {^session_id, submit_params, _identity} = RecordingStorage.last_submit()
      assert %{"audio_url" => "s3://bucket/key"} = submit_params["extras"]
    end
  end

  # Helpers

  defp restore(key, nil), do: Application.delete_env(:phoenix_replay, key)
  defp restore(key, value), do: Application.put_env(:phoenix_replay, key, value)
end
