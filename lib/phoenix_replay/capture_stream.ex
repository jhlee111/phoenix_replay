defmodule PhoenixReplay.CaptureStream do
  @moduledoc """
  Server-origin capture stream registry.

  Allows libraries (including phoenix_replay's own LiveView snapshot
  capture, and external consumers like ash_feedback) to push
  server-side events into a phoenix_replay session's recording stream
  with automatic clock-offset alignment to the browser timeline.

  See `docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md`
  for the full design rationale.

  ## Wire format

  `flush_for_session/1` returns rrweb-type-6-shaped maps suitable for
  merging into the existing rrweb event batch:

      %{
        "type" => 6,
        "timestamp" => browser_timeline_ms,
        "data" => %{
          "plugin" => stream_id,
          "payload" => map_passed_to_push_event
        }
      }

  Server-time → browser-time conversion happens exactly once, inside
  `flush_for_session/1`. Push-time storage uses raw `server_time_ms`.
  """

  alias PhoenixReplay.CaptureStream.Registry

  @type session_id :: String.t()
  @type stream_id :: String.t()
  @type event :: %{
          required(:server_time_ms) => integer(),
          required(:payload) => map()
        }

  @doc """
  Records the clock offset for a session — the difference between
  server-arrival time and the browser's `Date.now()` at the moment
  the client bootstrapped. Subsequent `push_event/3` calls' raw
  `server_time_ms` values are converted to browser timeline by
  subtracting this offset (at flush time).

  Idempotent: a second call replaces the first. Silent no-op if the
  session has no registered streams.
  """
  @spec record_clock_offset(session_id, integer()) :: :ok
  def record_clock_offset(session_id, browser_started_at_ms) do
    case Registry.session_pid(session_id) do
      nil -> :ok
      pid -> session_module().record_clock_offset(pid, browser_started_at_ms)
    end
  end

  @doc """
  Registers a stream for a session. Activates the scratch buffer so
  `push_event/3` accepts events. No-op if already attached.

  Options (Phase 1 honors only `:max_events`; `:ttl_ms` and
  `:max_bytes` are accepted but reserved for future enforcement):

    * `:max_events` — hard cap on scratch buffer size (default 5000).
      On overflow, oldest event is evicted (ring queue semantics).
  """
  @spec attach(session_id, stream_id, keyword()) :: :ok | {:error, :no_session}
  def attach(session_id, stream_id, opts \\ []) do
    case session_module().pid_for(session_id) do
      nil ->
        {:error, :no_session}

      pid ->
        session_module().attach_stream(pid, stream_id, opts)
        Registry.register(session_id, stream_id, pid)
        :ok
    end
  end

  @doc """
  Pushes a server-origin event into the session's scratch buffer.

  Hot-path budget: `< 5µs` when no stream is registered (single ETS
  lookup, no GenServer roundtrip).

  Silent `:ok` when the stream is not attached or the session does
  not exist. This lets call sites stay simple — instrumentation can
  safely call `push_event/3` unconditionally.
  """
  @spec push_event(session_id, stream_id, event) :: :ok
  def push_event(session_id, stream_id, %{server_time_ms: _, payload: _} = event) do
    case Registry.lookup(session_id, stream_id) do
      nil -> :ok
      pid -> session_module().handle_capture_push(pid, stream_id, event)
    end
  end

  @doc """
  Drains all scratch buffers for the session, applies the clock
  offset, wraps each event in rrweb type-6 plugin format, and
  returns the result. The caller is responsible for timestamp-sorting
  the merged batch before persistence.

  After flush, scratch buffers are empty but streams remain attached.
  """
  @spec flush_for_session(session_id) :: [map()]
  def flush_for_session(session_id) do
    case Registry.session_pid(session_id) do
      nil -> []
      pid -> session_module().drain_capture_streams(pid)
    end
  end

  defp session_module do
    Application.get_env(:phoenix_replay, :capture_stream_session_module, PhoenixReplay.Session)
  end
end
