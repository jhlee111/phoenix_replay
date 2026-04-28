defmodule PhoenixReplay.LiveView.Snapshots do
  @moduledoc """
  `on_mount` callback + `attach_hook` registrations that capture
  LiveView assigns shapes and callback markers into the
  phoenix_replay session's capture stream.

  Hosts add this to their `live_session` to enable LiveView state
  capture for recorded sessions:

      live_session :default,
        on_mount: [{PhoenixReplay.LiveView.Snapshots, :install}] do
        live "/posts", PostsLive
      end

  With the line in place, every LiveView in the `live_session` whose
  `session` map (populated by `PhoenixReplay.Plug.SessionLink` from
  the cookie set by `SessionController` — see Task 7.5) carries a
  `phx_replay_session_id` will emit:

    * a baseline snapshot at mount,
    * an event marker at each `handle_event` / `handle_info` /
      `handle_async` / `handle_params` callback entry,
    * a snapshot after the next render completes (paired to the
      marker via a shared `event_id`).

  Captured payloads contain only shape information (key + type +
  size hint) — no leaf values. Phase 2 will add a `use
  PhoenixReplay.LiveView, snapshot: [values: [...]]` macro to opt
  in to literal values for specific assigns keys.

  All capture paths are wrapped in `try/rescue` — a capture failure
  cannot crash the host LV.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, detach_hook: 3]
  import Phoenix.Component, only: [assign: 3]

  alias PhoenixReplay.LiveView.{Registry, Shape}

  @stream_id "phx-replay/liveview@1"
  @throttle_ms 50

  @doc """
  `on_mount` callback. Reads `phx_replay_session_id` from the LV's
  `session` map. If present, registers the LV process in
  `PhoenixReplay.LiveView.Registry`, ensures the snapshot stream is
  attached on the Session GenServer, and attaches capture hooks for
  all relevant callback stages. Otherwise returns immediately.
  """
  @spec on_mount(:install, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:install, _params, session, socket) do
    case extract_session_id(session) do
      nil ->
        {:cont, socket}

      session_id ->
        _ = Registry.register(session_id)

        # Idempotently attach the LV snapshot stream to Session state.
        # handle_call({:attach_stream, ...}) uses Map.put_new so a
        # second attach is a no-op.
        case PhoenixReplay.Session.pid_for(session_id) do
          nil -> :ok
          pid -> PhoenixReplay.Session.attach_stream(pid, @stream_id, [])
        end

        socket =
          socket
          |> assign(:__phx_replay_session_id__, session_id)
          |> assign(:__phx_replay_event_throttle__, %{})
          |> safe_attach_hook(:phx_replay_hev, :handle_event, &capture_handle_event/3)
          |> safe_attach_hook(:phx_replay_hin, :handle_info, &capture_handle_info/2)
          |> safe_attach_hook(:phx_replay_has, :handle_async, &capture_handle_async/3)
          |> safe_attach_hook(:phx_replay_hpa, :handle_params, &capture_handle_params/3)
          |> capture_baseline()

        {:cont, socket}
    end
  end

  # Test-only entry point — drives capture_handle_event/3 without
  # the full attach_hook plumbing.
  @doc false
  def capture_handle_event_for_test(event, params, socket) do
    capture_handle_event(event, params, socket)
  end

  # Accept both string and atom keys so tests / direct calls can use
  # whichever's convenient.
  defp extract_session_id(session) when is_map(session) do
    session["phx_replay_session_id"] || session[:phx_replay_session_id]
  end

  defp extract_session_id(_), do: nil

  # ── attach_hook callbacks ─────────────────────────────────────

  defp capture_handle_event(event_name, params, socket) do
    try do
      if throttle_ok?(socket, event_name) do
        session_id = socket.assigns[:__phx_replay_session_id__]
        event_id = make_ref()

        push_marker(session_id, %{
          kind: :event_marker,
          callback: :handle_event,
          event_name: event_name,
          params_shape: Shape.extract(params),
          target_cid: get_in(params, [:_target, "_target"]),
          event_id: event_id,
          lv_module: socket.view
        })

        socket = stamp_throttle(socket, event_name)
        socket = attach_pairing_hook(socket, event_id)
        {:cont, socket}
      else
        {:cont, socket}
      end
    rescue
      _ -> {:cont, socket}
    end
  end

  defp capture_handle_info(message, socket) do
    try do
      session_id = socket.assigns[:__phx_replay_session_id__]
      event_id = make_ref()

      push_marker(session_id, %{
        kind: :event_marker,
        callback: :handle_info,
        message_shape: Shape.extract(message),
        event_id: event_id,
        lv_module: socket.view
      })

      socket = attach_pairing_hook(socket, event_id)
      {:cont, socket}
    rescue
      _ -> {:cont, socket}
    end
  end

  defp capture_handle_async(name, async_result, socket) do
    try do
      session_id = socket.assigns[:__phx_replay_session_id__]
      event_id = make_ref()

      push_marker(session_id, %{
        kind: :event_marker,
        callback: :handle_async,
        name: name,
        result_shape: Shape.extract(async_result),
        event_id: event_id,
        lv_module: socket.view
      })

      socket = attach_pairing_hook(socket, event_id)
      {:cont, socket}
    rescue
      _ -> {:cont, socket}
    end
  end

  defp capture_handle_params(params, _uri, socket) do
    try do
      session_id = socket.assigns[:__phx_replay_session_id__]
      event_id = make_ref()

      push_marker(session_id, %{
        kind: :event_marker,
        callback: :handle_params,
        params_shape: Shape.extract(params),
        event_id: event_id,
        lv_module: socket.view
      })

      socket = attach_pairing_hook(socket, event_id)
      {:cont, socket}
    rescue
      _ -> {:cont, socket}
    end
  end

  # Wrapper that swallows attach_hook raises (e.g. live_isolated tests
  # don't support :handle_params; handle_async on older LV versions
  # may behave differently). A hook that fails to attach silently
  # degrades the relevant capture path to a no-op rather than
  # cascading through the whole on_mount pipeline.
  defp safe_attach_hook(socket, name, stage, fun) do
    attach_hook(socket, name, stage, fun)
  rescue
    _ -> socket
  end

  # ── snapshot pairing via :after_render ────────────────────────

  defp attach_pairing_hook(socket, event_id) do
    attach_hook(socket, :phx_replay_after_render, :after_render, fn s ->
      try do
        session_id = s.assigns[:__phx_replay_session_id__]

        push_marker(session_id, %{
          kind: :snapshot,
          paired_event_id: event_id,
          lv_module: s.view,
          assigns_shape: Shape.extract_assigns(s.assigns),
          assigns_values: %{}
        })
      rescue
        _ -> :ok
      end

      detach_hook(s, :phx_replay_after_render, :after_render)
    end)
  rescue
    _ -> socket
  end

  # ── baseline ──────────────────────────────────────────────────

  defp capture_baseline(socket) do
    try do
      session_id = socket.assigns[:__phx_replay_session_id__]

      push_marker(session_id, %{
        kind: :event_marker,
        callback: :mount,
        lv_module: socket.view,
        event_id: make_ref()
      })

      push_marker(session_id, %{
        kind: :snapshot,
        paired_event_id: nil,
        lv_module: socket.view,
        assigns_shape: Shape.extract_assigns(socket.assigns),
        assigns_values: %{}
      })

      socket
    rescue
      _ -> socket
    end
  end

  # ── helpers ───────────────────────────────────────────────────

  defp push_marker(nil, _payload), do: :ok

  defp push_marker(session_id, payload) do
    PhoenixReplay.CaptureStream.push_event(session_id, @stream_id, %{
      server_time_ms: System.system_time(:millisecond),
      payload: payload
    })
  end

  defp throttle_ok?(socket, event_name) do
    case Map.get(socket.assigns[:__phx_replay_event_throttle__] || %{}, event_name) do
      nil -> true
      last -> System.monotonic_time(:millisecond) - last >= @throttle_ms
    end
  end

  defp stamp_throttle(socket, event_name) do
    now = System.monotonic_time(:millisecond)
    throttle = Map.put(socket.assigns[:__phx_replay_event_throttle__] || %{}, event_name, now)
    assign(socket, :__phx_replay_event_throttle__, throttle)
  end
end
