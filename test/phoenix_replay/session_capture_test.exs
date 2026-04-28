defmodule PhoenixReplay.SessionCaptureTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.{Session, CaptureStream}

  @stream_id "phx-replay/test@1"
  @identity %{kind: :anonymous, id: nil, attrs: %{}}

  setup do
    session_id = "session-cap-#{System.unique_integer([:positive])}"
    {:ok, pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
    end)

    %{session_id: session_id, pid: pid}
  end

  test "attach_stream/3 registers in CaptureStream.Registry",
       %{session_id: session_id, pid: pid} do
    :ok = Session.attach_stream(pid, @stream_id, [])
    assert CaptureStream.Registry.lookup(session_id, @stream_id) == pid
  end

  test "handle_capture_push + drain_capture_streams round-trip applies offset",
       %{pid: pid} do
    :ok = Session.attach_stream(pid, @stream_id, [])
    :ok = Session.set_clock_received_at_for_test(pid, 1500)
    :ok = Session.record_clock_offset(pid, 1000)

    :ok =
      Session.handle_capture_push(pid, @stream_id, %{
        server_time_ms: 2000,
        payload: %{kind: :marker}
      })

    [event] = Session.drain_capture_streams(pid)

    assert event["type"] == 6
    assert event["timestamp"] == 1500
    assert event["data"]["plugin"] == @stream_id
    assert event["data"]["payload"] == %{kind: :marker}
  end

  test "drain twice empties the buffer the second time", %{pid: pid} do
    :ok = Session.attach_stream(pid, @stream_id, [])

    :ok =
      Session.handle_capture_push(pid, @stream_id, %{server_time_ms: 0, payload: %{}})

    assert [_] = Session.drain_capture_streams(pid)
    assert [] = Session.drain_capture_streams(pid)
  end

  test "ring overflow drops oldest", %{pid: pid} do
    :ok = Session.attach_stream(pid, @stream_id, max_events: 2)

    Enum.each(1..5, fn i ->
      Session.handle_capture_push(pid, @stream_id, %{server_time_ms: i, payload: %{i: i}})
    end)

    events = Session.drain_capture_streams(pid)
    assert length(events) == 2
    payloads = Enum.map(events, & &1["data"]["payload"])
    assert payloads == [%{i: 4}, %{i: 5}]
  end

  test "session terminate purges Registry entries",
       %{session_id: session_id, pid: pid} do
    :ok = Session.attach_stream(pid, @stream_id, [])
    assert CaptureStream.Registry.lookup(session_id, @stream_id) == pid

    ref = Process.monitor(pid)
    Session.close(session_id, :test_done)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

    # Registry's DOWN handler clears entries asynchronously; sync via :sys.get_state.
    :sys.get_state(PhoenixReplay.CaptureStream.Registry)
    assert CaptureStream.Registry.lookup(session_id, @stream_id) == nil
  end

  test "push to unattached stream is no-op (handle_cast falls through)",
       %{pid: pid} do
    :ok =
      Session.handle_capture_push(pid, "never-attached@1", %{
        server_time_ms: 0,
        payload: %{}
      })

    # Drain should be empty (no streams attached at all).
    assert Session.drain_capture_streams(pid) == []
  end
end
