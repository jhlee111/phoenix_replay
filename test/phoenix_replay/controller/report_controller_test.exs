defmodule PhoenixReplay.ReportControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias PhoenixReplay.Test.RecordingStorage

  @identity %{kind: :user, id: "u-test", attrs: %{}}

  setup do
    # RateLimiter is already started by the application supervisor
    # (see PhoenixReplay.Application). Just reset its ETS state so
    # buckets don't leak across tests in this :async false suite —
    # mirrors RateLimiterTest.
    PhoenixReplay.RateLimiter.reset()

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

    test "413 when content-length exceeds max_report_bytes", %{conn: conn} do
      prior_limits = Application.get_env(:phoenix_replay, :limits)
      Application.put_env(:phoenix_replay, :limits, max_report_bytes: 1024)

      on_exit(fn ->
        case prior_limits do
          nil -> Application.delete_env(:phoenix_replay, :limits)
          v -> Application.put_env(:phoenix_replay, :limits, v)
        end
      end)

      oversized_conn =
        conn
        |> put_req_header("content-length", "2048")

      oversized_conn =
        PhoenixReplay.ReportController.create(oversized_conn, %{
          "description" => "would-be too big",
          "events" => []
        })

      assert oversized_conn.status == 413
      assert %{"error" => "body_too_large"} = json_response(oversized_conn, 413)
    end

    test "happy path passes when content-length is under the cap", %{conn: conn} do
      prior_limits = Application.get_env(:phoenix_replay, :limits)
      Application.put_env(:phoenix_replay, :limits, max_report_bytes: 1_000_000)

      on_exit(fn ->
        case prior_limits do
          nil -> Application.delete_env(:phoenix_replay, :limits)
          v -> Application.put_env(:phoenix_replay, :limits, v)
        end
      end)

      small_conn =
        conn
        |> put_req_header("content-length", "256")

      small_conn = PhoenixReplay.ReportController.create(small_conn, %{"description" => "tiny"})

      assert small_conn.status == 201
    end

    test "422 detail is a serialized error map, not a stringified changeset", %{conn: conn} do
      start_supervised!({PhoenixReplay.Test.FailingStorage, []})
      Application.put_env(:phoenix_replay, :storage, {PhoenixReplay.Test.FailingStorage, []})

      on_exit(fn ->
        Application.put_env(:phoenix_replay, :storage, {PhoenixReplay.Test.RecordingStorage, []})
      end)

      conn = PhoenixReplay.ReportController.create(conn, %{"description" => "trigger 422"})

      assert conn.status == 422
      body = json_response(conn, 422)
      assert body["error"] == "submit_failed"
      # detail must be a structured map, never an inspect-string
      assert is_map(body["detail"])
      refute is_binary(body["detail"]) and String.contains?(body["detail"], "Ecto.Changeset")
    end

    test "429 after report_rate_per_minute hits in a single window", %{conn: conn} do
      prior_limits = Application.get_env(:phoenix_replay, :limits)
      Application.put_env(:phoenix_replay, :limits, report_rate_per_minute: 3)

      on_exit(fn ->
        case prior_limits do
          nil -> Application.delete_env(:phoenix_replay, :limits)
          v -> Application.put_env(:phoenix_replay, :limits, v)
        end
      end)

      # 3 requests must succeed; the 4th must 429 with a retry-after header.
      for _ <- 1..3 do
        ok_conn = PhoenixReplay.ReportController.create(conn, %{"description" => "ok"})
        assert ok_conn.status == 201
      end

      blocked = PhoenixReplay.ReportController.create(conn, %{"description" => "blocked"})

      assert blocked.status == 429
      assert %{"error" => "rate_limited"} = json_response(blocked, 429)
      assert [retry] = Plug.Conn.get_resp_header(blocked, "retry-after")
      assert {n, _} = Integer.parse(retry)
      assert n > 0 and n <= 60
    end

    test "different actors have independent buckets", %{conn: conn} do
      prior_limits = Application.get_env(:phoenix_replay, :limits)
      Application.put_env(:phoenix_replay, :limits, report_rate_per_minute: 1)

      on_exit(fn ->
        case prior_limits do
          nil -> Application.delete_env(:phoenix_replay, :limits)
          v -> Application.put_env(:phoenix_replay, :limits, v)
        end
      end)

      conn_b =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:phoenix_replay_identity, %{kind: :user, id: "u-other", attrs: %{}})
        |> Phoenix.Controller.accepts(["json"])

      ok_a = PhoenixReplay.ReportController.create(conn, %{"description" => "actor a"})
      ok_b = PhoenixReplay.ReportController.create(conn_b, %{"description" => "actor b"})

      assert ok_a.status == 201
      assert ok_b.status == 201
    end

    test "F9: host metadata wins when client and host share a key", %{conn: conn} do
      prior_metadata = Application.get_env(:phoenix_replay, :metadata)
      Application.put_env(:phoenix_replay, :metadata, fn _conn ->
        %{"page" => "host-wins", "host_only" => "x"}
      end)

      on_exit(fn ->
        case prior_metadata do
          nil -> Application.delete_env(:phoenix_replay, :metadata)
          v -> Application.put_env(:phoenix_replay, :metadata, v)
        end
      end)

      params = %{
        "description" => "merge order",
        "metadata" => %{"page" => "client-loses", "client_only" => "y"}
      }

      conn = PhoenixReplay.ReportController.create(conn, params)

      assert conn.status == 201
      assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()

      # Collision — host wins
      assert submit_params["metadata"]["page"] == "host-wins"
      # Non-collision — both pass through
      assert submit_params["metadata"]["host_only"] == "x"
      assert submit_params["metadata"]["client_only"] == "y"
    end
  end
end
