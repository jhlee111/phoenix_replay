defmodule PhoenixReplay.LiveView.SnapshotsTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.LiveView.Snapshots
  alias PhoenixReplay.Session

  @stream_id "phx-replay/liveview@1"
  @identity %{kind: :anonymous, id: nil, attrs: %{}}

  defmodule FakeLive do
    use Phoenix.LiveView
    def render(assigns), do: ~H""
  end

  defmodule BrokenStruct do
    defstruct [:placeholder]
  end

  setup do
    session_id = "lv-snap-#{System.unique_integer([:positive])}"
    {:ok, sess_pid} = Session.start_session(session_id, @identity, seq_watermark: 0)
    :ok = Session.attach_stream(sess_pid, @stream_id, [])
    # Pre-populate LV.Registry so direct hook calls (bypassing on_mount)
    # can locate session_id via Registry.lookup().
    :ok = PhoenixReplay.LiveView.Registry.register(session_id)

    on_exit(fn ->
      if Process.alive?(sess_pid), do: GenServer.stop(sess_pid, :normal, 1000)
    end)

    %{session_id: session_id, sess_pid: sess_pid}
  end

  test "capture_handle_event_for_test/3 emits an event marker into the stream",
       %{session_id: session_id, sess_pid: sess_pid} do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, __phx_replay_session_id__: session_id, count: 0},
      view: FakeLive,
      transport_pid: self()
    }

    assert {:cont, _socket} =
             Snapshots.capture_handle_event_for_test("inc", %{"key" => "value"}, socket)

    [event | _] = Session.drain_capture_streams(sess_pid)
    assert event["data"]["plugin"] == @stream_id
    assert event["data"]["payload"][:kind] == :event_marker
    assert event["data"]["payload"][:callback] == :handle_event
    assert event["data"]["payload"][:event_name] == "inc"
  end

  test "capture path swallows raises so host LV is not affected",
       %{session_id: session_id} do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        __phx_replay_session_id__: session_id,
        broken: %BrokenStruct{}
      },
      view: FakeLive,
      transport_pid: self()
    }

    # Even if shape extraction or attach_hook fails (handbuilt sockets
    # lack the :lifecycle private the real LV process supplies), the
    # wrapper must return {:cont, _} to keep the LV alive. We don't
    # pin to the input socket because successful captures legitimately
    # mutate assigns (throttle stamp).
    assert {:cont, _} = Snapshots.capture_handle_event_for_test("evt", %{}, socket)
  end

  test "session map without phx_replay_session_id → on_mount defers install but stays subscribed" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      view: FakeLive
    }

    assert {:cont, returned} = Snapshots.on_mount(:install, %{}, %{}, socket)

    # New contract (Phase 1.5): the socket is always primed with the
    # phx_replay assigns, the lifecycle hook is attached, and we
    # listen for `:session_started` broadcasts. Capture stays
    # uninstalled (`:__phx_replay_installed__` false) until a session
    # comes online for this LV.
    assert returned.assigns[:__phx_replay_session_id__] == nil
    assert returned.assigns[:__phx_replay_event_throttle__] == %{}
    assert returned.assigns[:__phx_replay_installed__] == false
  end
end
