defmodule PhoenixReplay.Live.SessionsIndex do
  @moduledoc """
  Admin LiveView listing every in-flight session — the entry point for
  the live watch surface (ADR-0004 Phase 2).

  On mount, seeds the table from `PhoenixReplay.Session.list_active/0`
  and subscribes to the global `"\#{prefix}:sessions"` topic for live
  delta. New `:session_started` broadcasts insert rows; `:session_closed`
  / `:session_abandoned` broadcasts remove them.

  Crash safety net: each row's pid is monitored, so if a Session
  process dies without emitting a clean termination broadcast, the
  resulting `:DOWN` removes the stale row.

  ## Mount shape

      <%!-- router.ex (handled by phoenix_replay_live_routes) --%>
      live "/", PhoenixReplay.Live.SessionsIndex, :index

  Each row's session_id links to
  `\#{base_path}/\#{session_id}/live` — the watch LV from Phase 1.

  ## Authorization

  `phoenix_replay` adds no auth plug. Hosts wrap the route in their
  own admin pipeline.
  """

  use Phoenix.LiveView

  alias PhoenixReplay.Config
  alias PhoenixReplay.Session
  alias PhoenixReplay.UI.Components

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:sessions, dom_id: &row_dom_id/1)
      |> stream(:sessions, [])
      |> assign(:known_ids, MapSet.new())
      |> assign(:index_path, "/")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Config.pubsub(), Session.sessions_topic())

      summaries = Session.list_active()

      socket =
        Enum.reduce(summaries, socket, fn summary, acc ->
          insert_row(acc, summary)
        end)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    # Capture the index's mount path so we can build absolute hrefs
    # to the watch LV regardless of where the host mounted us.
    index_path = URI.parse(uri).path || "/"
    {:noreply, assign(socket, :index_path, String.trim_trailing(index_path, "/"))}
  end

  @impl true
  def handle_info({:session_started, session_id, identity, started_at}, socket) do
    summary = %{
      session_id: session_id,
      identity: identity,
      started_at: started_at,
      last_event_at: started_at,
      seq_watermark: 0
    }

    {:noreply, insert_row(socket, summary)}
  end

  def handle_info({:session_closed, session_id, _reason}, socket) do
    {:noreply, drop_row(socket, session_id)}
  end

  def handle_info({:session_abandoned, session_id, _last_event_at}, socket) do
    {:noreply, drop_row(socket, session_id)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    # The clean-broadcast path removes the row first; this catches
    # crash-without-broadcast cases. Re-snapshot from the registry
    # and re-stream with reset: true (per LV streams usage rule —
    # streams aren't enumerable, can't iterate).
    {:noreply, resync(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Components.phoenix_replay_admin_assets />

    <div class="phx-replay-sessions-index">
      <header class="phx-replay-sessions-index-header">
        <h1>Live sessions</h1>
        <span class="phx-replay-sessions-index-count">
          {MapSet.size(@known_ids)} active
        </span>
      </header>

      <table class="phx-replay-sessions-index-table">
        <thead>
          <tr>
            <th>Session</th>
            <th>Identity</th>
            <th>Started</th>
            <th>Last event</th>
            <th>Seq</th>
          </tr>
        </thead>
        <tbody id="sessions" phx-update="stream">
          <tr
            :for={{dom_id, s} <- @streams.sessions}
            id={dom_id}
            class="phx-replay-sessions-index-row"
            data-testid="session-row"
            data-session-id={s.session_id}
          >
            <td>
              <.link
                navigate={"#{@index_path}/#{s.session_id}/live"}
                class="phx-replay-sessions-index-link"
              >
                <code>{s.session_id}</code>
              </.link>
            </td>
            <td>{format_identity(s.identity)}</td>
            <td>{format_when(s.started_at)}</td>
            <td>{format_when(s.last_event_at)}</td>
            <td>{s.seq_watermark}</td>
          </tr>
        </tbody>
      </table>

      <div :if={MapSet.size(@known_ids) == 0} class="phx-replay-sessions-index-empty">
        No sessions in flight.
      </div>
    </div>
    """
  end

  # Helpers

  defp row_dom_id(%{session_id: id}), do: "session-row-#{id}"

  defp insert_row(socket, summary) do
    %{session_id: session_id} = summary

    if MapSet.member?(socket.assigns.known_ids, session_id) do
      # Same id arriving via list_active() and :session_started in the
      # mount race window — stream upserts by dom_id, count stays put.
      stream_insert(socket, :sessions, summary)
    else
      monitor_session(session_id)

      socket
      |> stream_insert(:sessions, summary)
      |> assign(:known_ids, MapSet.put(socket.assigns.known_ids, session_id))
    end
  end

  defp monitor_session(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] -> Process.monitor(pid)
      [] -> :ok
    end
  end

  defp drop_row(socket, session_id) do
    if MapSet.member?(socket.assigns.known_ids, session_id) do
      socket
      |> stream_delete(:sessions, %{session_id: session_id})
      |> assign(:known_ids, MapSet.delete(socket.assigns.known_ids, session_id))
    else
      socket
    end
  end

  # Reconcile the stream against the live registry — used by the
  # crash-DOWN path. Streams aren't enumerable, so we rebuild from
  # list_active/0 with reset: true.
  defp resync(socket) do
    summaries = Session.list_active()
    ids = summaries |> Enum.map(& &1.session_id) |> MapSet.new()

    socket
    |> stream(:sessions, summaries, reset: true)
    |> assign(:known_ids, ids)
  end

  defp format_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_when(_), do: "—"

  defp format_identity(%{kind: :user, attrs: %{"email" => email}}) when is_binary(email),
    do: email

  defp format_identity(%{kind: :user, id: id}) when is_binary(id), do: id
  defp format_identity(%{kind: kind}), do: to_string(kind)
  defp format_identity(_), do: "—"
end
