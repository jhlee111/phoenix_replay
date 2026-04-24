defmodule PhoenixReplay.Live.SessionWatch do
  @moduledoc """
  Admin LiveView for watching a single in-flight session replay in
  real time.

  Subscribes to `PhoenixReplay.Session`'s per-session PubSub topic
  (see ADR-0003 Phase 2) and forwards `:event_batch` messages to the
  `data-mode="live"` branch of `player_hook.js`, which feeds them to
  rrweb-player via `player.addEvent/1`. On mount, seeds the player
  with the historical buffer via `Session.catchup/1` so an admin
  joining mid-session sees the reproduction from the start.

  ## Mount shape

      <%!-- router.ex --%>
      live "/sessions/:id/live", PhoenixReplay.Live.SessionWatch

  The LV expects the session's `:id` in path params. Host router must
  have mounted `Plug.Static` for `/phoenix_replay` assets (see
  `<.phoenix_replay_admin_assets />` in `UI.Components`) so the
  player_hook JS is available on the page.

  ## Authorization

  `phoenix_replay` adds no auth plug. Hosts wrap the route in their
  own admin pipeline (`pipe_through :admin`) — see README.

  ## Dedup

  `Session.catchup/1` returns `{events, watermark}` atomically,
  serialized against in-flight appends. Any subsequent `:event_batch`
  broadcast with `seq <= watermark` is already in the returned events
  and is silently dropped. Strict `>` accepts only new batches.

  When `catchup/1` returns `:infinity` (session no longer running),
  dedup is disabled — no further broadcasts will arrive for a closed
  or abandoned session.
  """

  use Phoenix.LiveView

  alias PhoenixReplay.Config
  alias PhoenixReplay.Session
  alias PhoenixReplay.UI.Components

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:seq_watermark, 0)
      |> assign(:status, :live)
      |> assign(:status_reason, nil)
      |> assign(:catchup_error, nil)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Config.pubsub(), topic_for(session_id))

      case Session.catchup(session_id) do
        {:ok, events, watermark} ->
          {:ok,
           socket
           |> assign(:seq_watermark, watermark_floor(watermark))
           |> assign(:status, status_for(watermark))
           |> push_event("phoenix_replay:catchup", %{
             session_id: session_id,
             events: events
           })}

        {:error, reason} ->
          {:ok,
           socket
           |> assign(:catchup_error, reason)
           |> assign(:status, :error)}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:event_batch, session_id, events, seq}, socket) do
    if seq > socket.assigns.seq_watermark do
      {:noreply,
       socket
       |> assign(:seq_watermark, seq)
       |> push_event("phoenix_replay:append", %{
         session_id: session_id,
         events: events,
         seq: seq
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_closed, session_id, reason}, socket) do
    {:noreply,
     socket
     |> assign(:status, :closed)
     |> assign(:status_reason, reason)
     |> push_event("phoenix_replay:closed", %{
       session_id: session_id,
       reason: to_string(reason)
     })}
  end

  def handle_info({:session_abandoned, session_id, last_event_at}, socket) do
    {:noreply,
     socket
     |> assign(:status, :abandoned)
     |> assign(:status_reason, last_event_at)
     |> push_event("phoenix_replay:abandoned", %{
       session_id: session_id,
       last_event_at: DateTime.to_iso8601(last_event_at)
     })}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Components.phoenix_replay_admin_assets />

    <div class="phx-replay-session-watch" id={"session-watch-#{@session_id}"}>
      <header class="phx-replay-session-watch-header">
        <h2>
          <span class="phx-replay-session-watch-label">Live session</span>
          <code class="phx-replay-session-watch-id">{@session_id}</code>
        </h2>
        <span class={["phx-replay-session-watch-status", "is-#{@status}"]}>
          {status_label(@status)}
        </span>
      </header>

      <div :if={@catchup_error} class="phx-replay-session-watch-error">
        Could not load session: {inspect(@catchup_error)}
      </div>

      <div
        :if={!@catchup_error}
        id={"phx-replay-live-player-#{@session_id}"}
        data-phoenix-replay-player
        data-mode="live"
        data-session-id={@session_id}
        data-height="560"
        class="phx-replay-player"
        phx-update="ignore"
      />

      <div
        :if={@status == :closed}
        class="phx-replay-session-watch-overlay is-closed"
        data-testid="session-watch-closed-overlay"
      >
        Session closed ({@status_reason})
      </div>

      <div
        :if={@status == :abandoned}
        class="phx-replay-session-watch-overlay is-abandoned"
        data-testid="session-watch-abandoned-overlay"
      >
        Session abandoned (idle timeout)
      </div>
    </div>
    """
  end

  # Helpers

  defp topic_for(session_id) do
    "#{Config.pubsub_topic_prefix()}:session:#{session_id}"
  end

  # Treat `:infinity` (closed/abandoned session) as "accept no more"
  # — any incoming batch is impossible anyway, but if one did sneak
  # in we'd rather drop than re-push.
  defp watermark_floor(:infinity), do: :infinity
  defp watermark_floor(n) when is_integer(n), do: n

  defp status_for(:infinity), do: :closed
  defp status_for(_), do: :live

  defp status_label(:live), do: "Live"
  defp status_label(:closed), do: "Closed"
  defp status_label(:abandoned), do: "Abandoned"
  defp status_label(:error), do: "Error"
end
