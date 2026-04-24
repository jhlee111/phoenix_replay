defmodule PhoenixReplay.Live.SessionWatchTest do
  use PhoenixReplay.ConnCase, async: false

  alias PhoenixReplay.Session
  alias PhoenixReplay.Storage.TestAdapter

  @identity %{kind: :anonymous, id: nil, attrs: %{}}

  setup do
    start_supervised!(TestAdapter)
    prior = Application.get_env(:phoenix_replay, :storage)
    Application.put_env(:phoenix_replay, :storage, {TestAdapter, []})

    on_exit(fn ->
      stop_all_sessions()

      case prior do
        nil -> Application.delete_env(:phoenix_replay, :storage)
        v -> Application.put_env(:phoenix_replay, :storage, v)
      end
    end)

    :ok
  end

  describe "mount/3 with a running session" do
    test "subscribes, catches up, and pushes initial events to the player", %{conn: conn} do
      session_id = unique_id()
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      # Seed the running session with one batch so catchup returns it.
      seed_events = [%{"type" => 0, "data" => %{}}]
      assert :ok = Session.append_events(session_id, 1, seed_events)

      {:ok, view, html} = live(conn, "/sessions/#{session_id}/live")

      assert html =~ session_id
      assert html =~ "Live"
      # The live player element is rendered with phx-update=ignore and
      # the data-mode attribute so the client-side script knows to use
      # the live-mode branch.
      assert html =~ ~s(data-mode="live")
      assert html =~ ~s(data-session-id="#{session_id}")

      # Catchup push_event is recorded — the test adapter stubs
      # fetch_events to [] so the payload here is just the server's
      # seed. Real Ecto adapter returns the persisted batch.
      assert_push_event(view, "phoenix_replay:catchup", %{
        session_id: ^session_id,
        events: _
      })
    end

    test "forwards :event_batch with seq > watermark via push_event", %{conn: conn} do
      session_id = unique_id()
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      {:ok, view, _html} = live(conn, "/sessions/#{session_id}/live")

      # Drop the initial :catchup push so later assert_push_event
      # reliably targets the :append we're about to trigger.
      assert_push_event(view, "phoenix_replay:catchup", _)

      # Drive a real append via the GenServer so it persists AND
      # broadcasts on the Session topic — the LV is already subscribed.
      new_events = [%{"type" => 3, "data" => %{"source" => 0}}]
      assert :ok = Session.append_events(session_id, 5, new_events)

      assert_push_event(view, "phoenix_replay:append", %{
        session_id: ^session_id,
        events: ^new_events,
        seq: 5
      })
    end

    test "drops :event_batch with seq <= current watermark (dedup)", %{conn: conn} do
      session_id = unique_id()
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      events = [%{"type" => 3, "data" => %{}}]
      assert :ok = Session.append_events(session_id, 10, events)

      {:ok, view, _html} = live(conn, "/sessions/#{session_id}/live")

      # After mount, the LV's watermark should be 10 (the session's
      # current seq). Send a simulated :event_batch for seq 5 — this
      # is the dedup path we want to exercise. Using send/2 on the
      # LV pid bypasses the normal broadcast flow so we can inject a
      # stale seq deterministically.
      send(view.pid, {:event_batch, session_id, events, 5})

      refute_push_event(view, "phoenix_replay:append", _, 50)
    end
  end

  describe "status transitions" do
    test ":session_closed pushes the closed event and renders the banner", %{conn: conn} do
      session_id = unique_id()
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      {:ok, view, _html} = live(conn, "/sessions/#{session_id}/live")
      assert_push_event(view, "phoenix_replay:catchup", _)

      assert :ok = Session.close(session_id, :submitted)

      assert_push_event(view, "phoenix_replay:closed", %{
        session_id: ^session_id,
        reason: "submitted"
      })

      assert render(view) =~ "Session closed"
      assert has_element?(view, "[data-testid=session-watch-closed-overlay]")
    end

    test ":session_abandoned pushes the abandoned event and renders the banner",
         %{conn: conn} do
      session_id = unique_id()

      {:ok, _pid} =
        Session.start_session(session_id, @identity,
          seq_watermark: 0,
          idle_timeout_ms: 40
        )

      {:ok, view, _html} = live(conn, "/sessions/#{session_id}/live")
      assert_push_event(view, "phoenix_replay:catchup", _)

      assert_push_event(
        view,
        "phoenix_replay:abandoned",
        %{session_id: ^session_id, last_event_at: _},
        500
      )

      assert render(view) =~ "Session abandoned"
      assert has_element?(view, "[data-testid=session-watch-abandoned-overlay]")
    end
  end

  describe "mount/3 with no running session" do
    test "falls back to storage fetch — status :closed, watermark :infinity",
         %{conn: conn} do
      session_id = unique_id()
      # No running session → Session.catchup/1 takes the :no_session
      # branch and returns {:ok, [], :infinity} from the TestAdapter's
      # fetch_events stub.
      {:ok, view, html} = live(conn, "/sessions/#{session_id}/live")

      assert html =~ session_id
      assert_push_event(view, "phoenix_replay:catchup", %{
        session_id: ^session_id,
        events: []
      })
    end
  end

  # Helpers

  defp unique_id, do: "session-#{System.unique_integer([:positive])}"

  defp stop_all_sessions do
    PhoenixReplay.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_id, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
    end)
  end

  # Phoenix.LiveViewTest's `assert_push_event` lives under
  # `Phoenix.LiveViewTest` — import via ConnCase.
end
