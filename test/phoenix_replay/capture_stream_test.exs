defmodule PhoenixReplay.CaptureStreamTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.CaptureStream

  @stream_id "phx-replay/test@1"

  setup_all do
    prev = Application.get_env(:phoenix_replay, :capture_stream_session_module)
    Application.put_env(:phoenix_replay, :capture_stream_session_module, StubSessionModule)

    on_exit(fn ->
      if prev do
        Application.put_env(:phoenix_replay, :capture_stream_session_module, prev)
      else
        Application.delete_env(:phoenix_replay, :capture_stream_session_module)
      end
    end)

    :ok
  end

  setup do
    session_id = "session-cap-#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({StubSession, session_id})
    :ok = CaptureStream.Registry.register(session_id, @stream_id, pid)
    on_exit(fn -> CaptureStream.Registry.unregister(session_id, @stream_id) end)
    %{session_id: session_id, pid: pid}
  end

  test "push_event/3 returns :ok and routes to the registered pid",
       %{session_id: session_id, pid: pid} do
    :ok =
      CaptureStream.push_event(session_id, @stream_id, %{
        server_time_ms: 1000,
        payload: %{kind: :marker}
      })

    assert StubSession.events(pid) == [
             {@stream_id, %{server_time_ms: 1000, payload: %{kind: :marker}}}
           ]
  end

  test "push_event/3 is a silent no-op when stream is not registered" do
    assert :ok =
             CaptureStream.push_event("unknown-session", "unknown/stream@1", %{
               server_time_ms: 0,
               payload: %{}
             })
  end

  test "record_clock_offset/2 stores offset in the registered session",
       %{session_id: session_id, pid: pid} do
    StubSession.set_received_at(pid, 1500)
    :ok = CaptureStream.record_clock_offset(session_id, 1000)
    assert StubSession.clock_offset(pid) == 500
  end

  test "flush_for_session/1 drains and applies offset, wraps in rrweb type-6",
       %{session_id: session_id, pid: pid} do
    StubSession.set_received_at(pid, 1500)
    :ok = CaptureStream.record_clock_offset(session_id, 1000)

    :ok =
      CaptureStream.push_event(session_id, @stream_id, %{
        server_time_ms: 2000,
        payload: %{kind: :marker, name: "click"}
      })

    [event] = CaptureStream.flush_for_session(session_id)

    assert event["type"] == 6
    # 2000 server - 500 offset = 1500 browser timeline
    assert event["timestamp"] == 1500
    assert event["data"]["plugin"] == @stream_id
    assert event["data"]["payload"] == %{kind: :marker, name: "click"}
  end

  test "flush_for_session/1 with no offset falls back to raw server time",
       %{session_id: session_id} do
    :ok =
      CaptureStream.push_event(session_id, @stream_id, %{
        server_time_ms: 7777,
        payload: %{}
      })

    [event] = CaptureStream.flush_for_session(session_id)
    assert event["timestamp"] == 7777
  end

  test "flush_for_session/1 returns [] for unknown session" do
    assert CaptureStream.flush_for_session("unknown-session") == []
  end
end

defmodule StubSession do
  use Agent

  def start_link(session_id) do
    Agent.start_link(
      fn -> %{events: [], offset: nil, received_at: nil} end,
      name: name(session_id)
    )
  end

  def child_spec(session_id) do
    %{id: {__MODULE__, session_id}, start: {__MODULE__, :start_link, [session_id]}}
  end

  def events(pid), do: Agent.get(pid, & &1.events)
  def clock_offset(pid), do: Agent.get(pid, & &1.offset)

  def set_received_at(pid, ts) do
    Agent.update(pid, &%{&1 | received_at: ts})
    :ok
  end

  defp name(session_id), do: :"stub_session_#{session_id}"
end

defmodule StubSessionModule do
  @moduledoc false
  # Thin facade over Agent-based StubSession; matches the protocol
  # PhoenixReplay.CaptureStream's session_module/0 expects.

  def pid_for(session_id) do
    Process.whereis(:"stub_session_#{session_id}")
  end

  def attach_stream(pid, stream_id, _opts) do
    send(pid, {:attach_stream, stream_id})
    :ok
  end

  def handle_capture_push(pid, stream_id, event) do
    Agent.update(pid, fn s -> %{s | events: s.events ++ [{stream_id, event}]} end)
    :ok
  end

  def record_clock_offset(pid, browser_started_at_ms) do
    Agent.update(pid, fn s ->
      offset = (s.received_at || browser_started_at_ms) - browser_started_at_ms
      %{s | offset: offset}
    end)

    :ok
  end

  def drain_capture_streams(pid) do
    Agent.get_and_update(pid, fn s ->
      offset = s.offset || 0

      out =
        Enum.map(s.events, fn {sid, ev} ->
          %{
            "type" => 6,
            "timestamp" => ev.server_time_ms - offset,
            "data" => %{"plugin" => sid, "payload" => ev.payload}
          }
        end)

      {out, %{s | events: []}}
    end)
  end
end
