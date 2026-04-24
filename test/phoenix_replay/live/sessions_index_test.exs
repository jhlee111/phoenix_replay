defmodule PhoenixReplay.Live.SessionsIndexTest do
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

  describe "mount/3" do
    test "renders rows for every running session", %{conn: conn} do
      sid_a = unique_id()
      sid_b = unique_id()
      {:ok, _} = Session.start_session(sid_a, @identity, seq_watermark: 0)
      {:ok, _} = Session.start_session(sid_b, @identity, seq_watermark: 0)

      {:ok, view, _html} = live(conn, "/sessions")

      assert has_element?(view, "tr[data-session-id='#{sid_a}']")
      assert has_element?(view, "tr[data-session-id='#{sid_b}']")
      assert render(view) =~ "2 active"
    end

    test "renders empty state when no sessions are running", %{conn: conn} do
      stop_all_sessions()

      {:ok, view, html} = live(conn, "/sessions")

      assert html =~ "No sessions in flight"
      assert render(view) =~ "0 active"
    end
  end

  describe "live updates" do
    test "inserts a row when :session_started broadcasts arrive", %{conn: conn} do
      stop_all_sessions()
      {:ok, view, _html} = live(conn, "/sessions")
      assert render(view) =~ "0 active"

      sid = unique_id()
      {:ok, _} = Session.start_session(sid, @identity, seq_watermark: 0)

      # The mount-time PubSub subscription drives the broadcast into
      # the LV process; render after a brief tick to let the message
      # land.
      assert eventually(fn -> has_element?(view, "tr[data-session-id='#{sid}']") end)
      assert render(view) =~ "1 active"
    end

    test "removes the row when :session_closed broadcasts arrive", %{conn: conn} do
      sid = unique_id()
      {:ok, _} = Session.start_session(sid, @identity, seq_watermark: 0)

      {:ok, view, _html} = live(conn, "/sessions")
      assert has_element?(view, "tr[data-session-id='#{sid}']")

      assert :ok = Session.close(sid, :submitted)

      assert eventually(fn -> not has_element?(view, "tr[data-session-id='#{sid}']") end)
      assert render(view) =~ "0 active"
    end

    test "removes the row when :session_abandoned broadcasts arrive", %{conn: conn} do
      sid = unique_id()

      {:ok, _} =
        Session.start_session(sid, @identity, seq_watermark: 0, idle_timeout_ms: 30)

      {:ok, view, _html} = live(conn, "/sessions")
      assert has_element?(view, "tr[data-session-id='#{sid}']")

      # idle_timeout_ms = 30 → :session_abandoned fires automatically.
      assert eventually(fn -> not has_element?(view, "tr[data-session-id='#{sid}']") end, 500)
      assert render(view) =~ "0 active"
    end

    test "DOWN cleanup removes a crashed session even without a broadcast",
         %{conn: conn} do
      sid = unique_id()
      {:ok, pid} = Session.start_session(sid, @identity, seq_watermark: 0)

      {:ok, view, _html} = live(conn, "/sessions")
      assert has_element?(view, "tr[data-session-id='#{sid}']")

      # :kill bypasses GenServer.handle_call/handle_info — no
      # :session_closed broadcast fires. The LV's Process.monitor
      # picks up the DOWN and resyncs from list_active/0.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert eventually(
               fn -> not has_element?(view, "tr[data-session-id='#{sid}']") end,
               500
             )
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

  # Polls a 0-arg predicate until it returns truthy or the budget
  # runs out. Used to bridge async LV broadcasts to sync assertions.
  defp eventually(fun, budget_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end
end
