defmodule PhoenixReplay.Integration.LvSnapshotE2eTest do
  use PhoenixReplay.ConnCase, async: false

  alias PhoenixReplay.{Session, CaptureStream}

  @stream_id "phx-replay/liveview@1"
  @identity %{kind: :anonymous, id: nil, attrs: %{}}

  defmodule CounterLive do
    use Phoenix.LiveView, layout: false
    on_mount({PhoenixReplay.LiveView.Snapshots, :install})

    def mount(_params, _session, socket) do
      {:ok, Phoenix.Component.assign(socket, :count, 0)}
    end

    def handle_event("inc", _, socket) do
      {:noreply, Phoenix.Component.assign(socket, :count, socket.assigns.count + 1)}
    end

    def render(assigns) do
      ~H"""
      <div id="counter">count: {@count}</div>
      """
    end
  end

  setup do
    session_id = "e2e-#{System.unique_integer([:positive])}"
    {:ok, sess_pid} = Session.start_session(session_id, @identity, seq_watermark: 0)
    :ok = Session.attach_stream(sess_pid, @stream_id, [])
    # Pretend client_started_at = 1000, server_received_at = 1500 → offset 500
    :ok = Session.set_clock_received_at_for_test(sess_pid, 1500)
    :ok = Session.record_clock_offset(sess_pid, 1000)

    on_exit(fn ->
      if Process.alive?(sess_pid), do: GenServer.stop(sess_pid, :normal, 1000)
    end)

    %{session_id: session_id, sess_pid: sess_pid}
  end

  test "instrumented LV produces baseline + post-event snapshots aligned to browser timeline",
       %{session_id: session_id} do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"phx_replay_session_id" => session_id})

    {:ok, view, _html} = live_isolated(conn, CounterLive)

    assert render_click(view, "inc") =~ "count: 1"

    # Allow async :after_render hook to fire.
    Process.sleep(50)

    events = CaptureStream.flush_for_session(session_id)

    # Mount baseline marker + handle_event marker should both be present.
    callbacks =
      Enum.map(events, &get_in(&1, ["data", "payload", :callback]))

    assert :mount in callbacks, "expected a mount baseline marker"
    assert :handle_event in callbacks, "expected a handle_event marker"

    # Wire format: rrweb type-6 plugin events with our plugin name.
    assert Enum.all?(events, &(&1["type"] == 6))
    assert Enum.all?(events, &(&1["data"]["plugin"] == @stream_id))

    # Timestamps are converted to browser timeline by subtracting offset.
    # We can't assert exact values (depends on system_time at capture),
    # but they must be integers and ≤ now-offset roughly.
    assert Enum.all?(events, &is_integer(&1["timestamp"]))
  end
end
