defmodule PhoenixReplay.ReportControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias PhoenixReplay.Test.RecordingStorage

  @identity %{kind: :user, id: "u-test", attrs: %{}}

  setup do
    start_supervised!(RecordingStorage)

    prior_storage = Application.get_env(:phoenix_replay, :storage)
    Application.put_env(:phoenix_replay, :storage, {RecordingStorage, []})

    on_exit(fn ->
      case prior_storage do
        nil -> Application.delete_env(:phoenix_replay, :storage)
        v -> Application.put_env(:phoenix_replay, :storage, v)
      end
    end)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> assign(:phoenix_replay_identity, @identity)
      |> Phoenix.Controller.accepts(["json"])

    %{conn: conn}
  end

  describe "POST /report" do
    test "happy path: events + description in one POST → submit recorded", %{conn: conn} do
      events = [
        %{"type" => 2, "timestamp" => 1, "data" => %{"x" => 1}},
        %{"type" => 3, "timestamp" => 2, "data" => %{"x" => 2}}
      ]

      params = %{
        "description" => "buffer-attached report",
        "severity" => "medium",
        "events" => events,
        "metadata" => %{"page" => "/demo"},
        "jam_link" => nil
      }

      conn = PhoenixReplay.ReportController.create(conn, params)

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["ok"] == true
      assert is_binary(body["id"])

      assert {session_id, submit_params, identity} = RecordingStorage.last_submit()
      assert is_binary(session_id)
      assert submit_params["description"] == "buffer-attached report"
      assert submit_params["severity"] == "medium"
      assert submit_params["metadata"]["page"] == "/demo"
      assert identity == @identity
    end

    test "missing description → 422", %{conn: conn} do
      params = %{"events" => []}

      conn = PhoenixReplay.ReportController.create(conn, params)

      assert conn.status == 422
      assert %{"error" => "missing_description"} = json_response(conn, 422)
    end

    test "events defaults to [] when omitted (text-only)", %{conn: conn} do
      conn =
        PhoenixReplay.ReportController.create(conn, %{"description" => "no events"})

      assert conn.status == 201
      assert {_session_id, _params, _identity} = RecordingStorage.last_submit()
    end

    test "severity defaults to medium when omitted", %{conn: conn} do
      conn =
        PhoenixReplay.ReportController.create(conn, %{"description" => "no sev"})

      assert conn.status == 201
      assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()
      assert submit_params["severity"] == "medium"
    end

    test "extras and jam_link forwarded to submit_params", %{conn: conn} do
      params = %{
        "description" => "with extras",
        "extras" => %{"audio_url" => "s3://bucket/clip"},
        "jam_link" => "https://jam.dev/c/abc"
      }

      conn = PhoenixReplay.ReportController.create(conn, params)

      assert conn.status == 201
      assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()
      assert submit_params["extras"]["audio_url"] == "s3://bucket/clip"
      assert submit_params["jam_link"] == "https://jam.dev/c/abc"
    end

    test "non-list events → 400", %{conn: conn} do
      params = %{"description" => "bad events", "events" => "not a list"}

      conn = PhoenixReplay.ReportController.create(conn, params)

      assert conn.status == 400
      assert %{"error" => "events_must_be_list"} = json_response(conn, 400)
    end
  end
end
