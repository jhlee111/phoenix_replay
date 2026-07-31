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
  `session` map and prepares the LV for snapshot capture.

  Behaviour:

    * **Connected LVs** subscribe to `PhoenixReplay.Session.sessions_topic/0`
      and receive `{:session_started, session_id, identity, started_at}`
      broadcasts when any session GenServer comes online.
    * If the cookie's `phx_replay_session_id` already maps to a live
      Session at mount time, capture hooks install immediately
      (the original happy path).
    * If the cookie is absent, stale, or points to a session that
      is not yet alive, install is **deferred** until a
      `:session_started` broadcast arrives. The lifecycle hook
      (`:phx_replay_lifecycle` on `:handle_info`) adopts the
      broadcast's session_id when actor correlation passes — see
      `for_this_lv?/2` — and runs the install path then.

  This addresses spec § "Open question 5": Path B and Path A
  first-mount scenarios both create the recording session AFTER the
  LV has already mounted; without the lifecycle hook the LV would
  never attach hooks for that session and capture would silently
  drop on the floor.
  """
  @spec on_mount(:install, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:install, _params, session, socket) do
    initial_session_id = extract_session_id(session)

    socket =
      socket
      |> assign(:__phx_replay_session_id__, initial_session_id)
      |> assign(:__phx_replay_event_throttle__, %{})
      |> assign(:__phx_replay_installed__, false)
      |> safe_attach_hook(:phx_replay_lifecycle, :handle_info, &lifecycle_hook/2)

    _ = maybe_subscribe_global(socket)

    socket =
      case initial_session_id && PhoenixReplay.Session.pid_for(initial_session_id) do
        nil -> socket
        pid when is_pid(pid) -> install_capture(socket, initial_session_id, pid)
      end

    {:cont, socket}
  end

  # Subscribe to the global sessions topic so we can pick up
  # `:session_started` broadcasts emitted by `Session.init/1`.
  # Idempotent — Phoenix.PubSub.subscribe/2 with the same topic from
  # the same pid is a no-op. Wrapped in try/rescue so test
  # environments without PubSub configured don't blow up the on_mount.
  defp maybe_subscribe_global(socket) do
    if Phoenix.LiveView.connected?(socket) do
      try do
        case PhoenixReplay.Config.pubsub() do
          nil ->
            :ok

          pubsub ->
            Phoenix.PubSub.subscribe(pubsub, PhoenixReplay.Session.sessions_topic())
        end
      rescue
        _ -> :ok
      end
    else
      :ok
    end
  end

  # Lifecycle hook — runs as the FIRST `:handle_info` hook (registered
  # at on_mount before the capture hooks) so it always sees session
  # broadcasts even if capture hooks aren't yet attached. Returns
  # `{:cont, socket}` so the host LV's own `handle_info` clauses run
  # normally.
  defp lifecycle_hook({:session_started, sid, identity, _started_at}, socket) do
    socket =
      cond do
        socket.assigns[:__phx_replay_installed__] ->
          # Already capturing — ignore. (Could be a different session
          # for another tab; we don't want to bounce off it.)
          socket

        socket.assigns[:__phx_replay_session_id__] == sid ->
          # Cookie's session id matches the one that just came online.
          # Common case: Path A continuous + cookie carried the
          # eventual session id from the prior page.
          adopt_and_install(socket, sid)

        for_this_lv?(identity, socket) ->
          # Cookie was nil/stale; the host's `:identify` callback
          # returned a payload that matches our actor → adopt.
          adopt_and_install(socket, sid)

        true ->
          socket
      end

    {:cont, socket}
  end

  defp lifecycle_hook(_message, socket), do: {:cont, socket}

  # Best-effort actor correlation between the broadcast's identity
  # payload and the LV's assigned actor. Conservative by default:
  # when neither side carries a comparable id, return `false` so we
  # don't cross-couple unrelated tabs.
  defp for_this_lv?(identity, socket) when is_map(identity) do
    bid = identity[:id] || identity["id"]
    sid = lv_actor_id(socket)

    cond do
      is_nil(bid) -> false
      is_nil(sid) -> false
      true -> to_string(bid) == to_string(sid)
    end
  end

  defp for_this_lv?(_identity, _socket), do: false

  # Walk a small list of common actor assignment keys. Hosts using
  # other names (rare) won't get retroactive adoption — they fall
  # through to the cookie-id-matches path, which still covers the
  # most common flow.
  defp lv_actor_id(socket) do
    Enum.find_value([:current_user, :current_actor, :actor, :user], fn key ->
      case socket.assigns do
        %{^key => %{id: id}} when not is_nil(id) -> id
        _ -> nil
      end
    end)
  end

  defp adopt_and_install(socket, session_id) do
    case PhoenixReplay.Session.pid_for(session_id) do
      nil ->
        # Started broadcast arrived but the GenServer is already gone
        # (extremely tight race). Skip; another broadcast or a fresh
        # mount will resolve it.
        socket

      pid when is_pid(pid) ->
        install_capture(socket, session_id, pid)
    end
  end

  defp install_capture(socket, session_id, session_pid) do
    _ = Registry.register(session_id)

    # Idempotently attach the LV snapshot stream to Session state.
    # handle_call({:attach_stream, ...}) uses Map.put_new so a
    # second attach is a no-op.
    PhoenixReplay.Session.attach_stream(session_pid, @stream_id, [])

    socket
    |> assign(:__phx_replay_session_id__, session_id)
    |> assign(:__phx_replay_installed__, true)
    |> safe_attach_hook(:phx_replay_hev, :handle_event, &capture_handle_event/3)
    |> safe_attach_hook(:phx_replay_hin, :handle_info, &capture_handle_info/2)
    |> safe_attach_hook(:phx_replay_has, :handle_async, &capture_handle_async/3)
    |> safe_attach_hook(:phx_replay_hpa, :handle_params, &capture_handle_params/3)
    |> capture_baseline()
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
