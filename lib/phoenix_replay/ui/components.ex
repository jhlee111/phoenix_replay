defmodule PhoenixReplay.UI.Components do
  @moduledoc """
  Phoenix function components for the PhoenixReplay widget.

  ## Usage

  Drop the mount + scripts into your root layout once:

      # lib/my_app_web/components/layouts/root.html.heex
      <.phoenix_replay_widget
        base_path={~p"/api/feedback"}
        csrf_token={get_csrf_token()}
      />

  The widget JS auto-mounts on any element with `data-phoenix-replay`
  attribute, so no additional glue is required.

  ## Script sources

  PhoenixReplay itself ships `phoenix_replay.js` and
  `phoenix_replay.css` under `/phoenix_replay/` when served via
  `Plug.Static`. `rrweb` + its plugins are NOT vendored — pass
  `rrweb_src`, `rrweb_console_src`, and `rrweb_network_src` to point at
  your preferred origin (CDN or self-hosted).

  When rrweb is missing the widget still works — descriptions + severity
  are submitted without DOM/console/network replay.

  The component renders only in environments you explicitly enable
  (staging / opt-in prod) — control via the host's own config check
  before rendering.
  """

  use Phoenix.Component

  @rrweb_version "2.0.0-alpha.18"
  # Use unpkg: it serves `.umd.cjs` with `text/javascript`. jsdelivr labels
  # the same file as `application/node`, which Chrome's strict MIME check
  # refuses to execute as a script. Hosts can override either URL.
  @default_rrweb_src "https://unpkg.com/rrweb@#{@rrweb_version}/dist/rrweb.umd.cjs"
  @default_console_src "https://unpkg.com/@rrweb/rrweb-plugin-console-record@#{@rrweb_version}/dist/rrweb-plugin-console-record.umd.cjs"
  # Network plugin is not published as a separate npm package at this rrweb
  # version — hosts that want network capture can build it themselves and
  # pass the URL via `rrweb_network_src`.
  @default_network_src nil

  attr :base_path, :string,
    required: true,
    doc:
      "Path prefix where `feedback_routes/2` is mounted. The widget " <>
        "will POST to `\#{base_path}/session`, `/events`, and `/submit`."

  attr :csrf_token, :string,
    required: true,
    doc: "Phoenix CSRF token. Pass `get_csrf_token()` in your layout."

  attr :widget_text, :string,
    default: "Report issue",
    doc: "Label shown on the floating toggle button."

  attr :position, :atom,
    default: :bottom_right,
    values: [:bottom_right, :bottom_left, :top_right, :top_left],
    doc:
      "Corner preset for the floating toggle button. Fine-tune via CSS " <>
        "custom properties `--phx-replay-toggle-{bottom,right,top,left,z}` " <>
        "on any ancestor or on `.phx-replay-toggle` directly."

  attr :mode, :atom,
    default: :float,
    values: [:float, :headless],
    doc:
      "`:float` renders the floating toggle button (default). `:headless` " <>
        "renders only the panel; host wires its own trigger via " <>
        "`[data-phoenix-replay-trigger]` on any element or by calling " <>
        "`window.PhoenixReplay.open()` / `.close()`."

  attr :show_severity, :boolean,
    default: false,
    doc:
      "When `true`, the submit forms (Path A and Path B) render Low/Medium/" <>
        "High severity buttons. When `false` (default), severity is omitted " <>
        "and the submitted Feedback row carries `severity: nil`. End-user " <>
        "widgets should leave this off — severity is a triage decision the " <>
        "receiver makes. Set `true` for QA-internal portals where the " <>
        "reporter is also the triager."

  attr :allow_paths, :list,
    default: [:report_now, :record_and_report],
    doc:
      "Which Report Issue paths the panel offers. Defaults to both. Pass " <>
        "`[:report_now]` to hide the Record-and-report card; pass " <>
        "`[:record_and_report]` to hide Report-now. When only one is " <>
        "allowed, clicking the trigger goes straight to that path's UI " <>
        "(no two-option panel)."

  attr :buffer_window_seconds, :integer,
    default: 60,
    doc:
      "Sliding-window size of the client-side ring buffer (seconds) used " <>
        "by Path A. Older events are evicted as they fall out of the " <>
        "window. Tune lower for memory-sensitive hosts; tune higher when " <>
        "users typically take longer to recognize and report a bug."

  attr :rrweb_src, :string,
    default: @default_rrweb_src,
    doc: "Script URL for rrweb core. Pass `nil` to disable rrweb entirely."

  attr :rrweb_console_src, :string,
    default: @default_console_src,
    doc: "Script URL for rrweb console plugin. Pass `nil` to disable."

  attr :rrweb_network_src, :string,
    default: @default_network_src,
    doc: "Script URL for rrweb network plugin. Pass `nil` to disable."

  attr :rrweb_player_src, :string,
    default: "https://unpkg.com/rrweb-player@2.0.0-alpha.18/dist/rrweb-player.umd.cjs",
    doc:
      "Script URL for rrweb-player UMD. Used by Path B's review step " <>
        "to render the mini playback before the user submits. Emitted " <>
        "only when `allow_paths` includes `:record_and_report`. Pass " <>
        "`nil` to disable — the review step degrades to a 'Continue " <>
        "without preview' UI in that case."

  attr :rrweb_player_style_src, :string,
    default: "https://unpkg.com/rrweb-player@2.0.0-alpha.18/dist/style.css",
    doc:
      "Stylesheet URL for rrweb-player. Pass `nil` to disable. Loaded " <>
        "alongside the player script for Path B-capable widgets."

  attr :asset_path, :string,
    default: "/phoenix_replay",
    doc:
      "Public path prefix where `phoenix_replay.js` / `phoenix_replay.css` " <>
        "are served. Mount `Plug.Static, at: asset_path, from: {:phoenix_replay, \"priv/static/assets\"}`. " <>
        "Pass `nil` to skip both the stylesheet and script tags — useful when " <>
        "the host self-hosts library assets through its own bundler or wants " <>
        "to ship fully custom styling in `:headless` mode."

  attr :rest, :global

  @doc """
  Renders the PhoenixReplay mount point, stylesheet, and scripts.

  Emits a hidden `<div data-phoenix-replay>` with all configuration on
  data-attributes. The included `phoenix_replay.js` auto-mounts on
  DOMContentLoaded.

  ## Customizing the trigger

  The default `:float` mode renders a floating toggle button in the
  bottom-right corner. Move it with the `position` preset attr:

      <.phoenix_replay_widget
        base_path="/api/feedback"
        csrf_token={get_csrf_token()}
        position={:bottom_left}
      />

  Fine-tune via CSS custom properties in a host stylesheet loaded after
  the library CSS:

      .phx-replay-toggle {
        --phx-replay-toggle-bottom: 5rem; /* push above a footer bar */
      }

  To hide the floating button entirely and wire your own trigger — a
  header link, a dropdown menu item, a keyboard shortcut, etc. — use
  `:headless` mode:

      <.phoenix_replay_widget
        base_path="/api/feedback"
        csrf_token={get_csrf_token()}
        mode={:headless}
      />

      <button data-phoenix-replay-trigger>Report a bug</button>

  Any element with `[data-phoenix-replay-trigger]` opens the panel when
  clicked (including elements added to the DOM after page load — the
  click listener is delegated at the document level). For programmatic
  control, call `window.PhoenixReplay.open()` and
  `window.PhoenixReplay.close()` from your JS. See the
  [Headless integration guide](guides/headless-integration.html) for
  worked examples.
  """
  def phoenix_replay_widget(assigns) do
    assigns = assign(assigns, :path_b_enabled, :record_and_report in (assigns[:allow_paths] || []))

    ~H"""
    <link :if={@asset_path} rel="stylesheet" href={"#{@asset_path}/phoenix_replay.css"} />
    <script :if={@rrweb_src} src={@rrweb_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_console_src} src={@rrweb_console_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_network_src} src={@rrweb_network_src} crossorigin="anonymous"></script>
    <link :if={@path_b_enabled and @rrweb_player_style_src} rel="stylesheet" href={@rrweb_player_style_src} crossorigin="anonymous" />
    <script :if={@path_b_enabled and @rrweb_player_src} src={@rrweb_player_src} crossorigin="anonymous"></script>
    <script :if={@asset_path} src={"#{@asset_path}/phoenix_replay.js"} defer></script>
    <div
      data-phoenix-replay
      data-base-path={@base_path}
      data-csrf-token={@csrf_token}
      data-widget-text={@widget_text}
      data-position={@position}
      data-mode={@mode}
      data-show-severity={to_string(@show_severity)}
      data-allow-paths={Enum.map_join(@allow_paths, ",", &Atom.to_string/1)}
      data-buffer-window-seconds={@buffer_window_seconds}
      {@rest}
    />
    """
  end

  # --- Admin components ------------------------------------------------

  @rrweb_player_version "2.0.0-alpha.18"
  @default_player_style_src "https://unpkg.com/rrweb-player@#{@rrweb_player_version}/dist/style.css"
  # UMD bundle exposes `window.rrwebPlayer`. unpkg's ESM variant
  # (`/dist/rrweb-player.js`) uses bare specifiers (@rrweb/replay,
  # @rrweb/packer) that are not rewritten by unpkg, so a plain
  # <script type=module> fails without an import map. UMD is the
  # no-build default.
  @default_player_src "https://unpkg.com/rrweb-player@#{@rrweb_player_version}/dist/rrweb-player.umd.cjs"

  attr :asset_path, :string,
    default: "/phoenix_replay",
    doc:
      "Public path prefix where `phoenix_replay_admin.css` / `player_hook.js` " <>
        "are served. Mount `Plug.Static, at: asset_path, from: {:phoenix_replay, \"priv/static/assets\"}`."

  attr :player_style_src, :string,
    default: @default_player_style_src,
    doc: "rrweb-player stylesheet URL. Pass `nil` to disable."

  attr :player_src, :string,
    default: @default_player_src,
    doc: "rrweb-player script URL. Pass `nil` to disable."

  @doc """
  Emits the stylesheet + JS required by `<.replay_player />`.

  Drop this in the admin layout (once per page). After this runs, any
  `<.replay_player />` element — including those added by LiveView
  patches — auto-initializes an rrweb-player bound to its
  `events_url`.
  """
  def phoenix_replay_admin_assets(assigns) do
    ~H"""
    <link rel="stylesheet" href={"#{@asset_path}/phoenix_replay_admin.css"} />
    <link :if={@player_style_src} rel="stylesheet" href={@player_style_src} crossorigin="anonymous" />
    <script :if={@player_src} src={@player_src} crossorigin="anonymous"></script>
    <script src={"#{@asset_path}/player_hook.js"} defer></script>
    """
  end

  attr :entries, :list, required: true, doc: "List of feedback rows (structs or maps)."
  attr :selected_id, :any, default: nil, doc: "Currently-selected id (highlighted in the list)."
  attr :row_click_target, :any, default: nil,
    doc:
      "Phoenix `:phx-target` component if the parent LV routes clicks through a component. " <>
        "Defaults to the containing LiveView."

  attr :row_click_event, :string,
    default: "select_feedback",
    doc: "phx-click event name dispatched when a row is selected."

  attr :empty_text, :string, default: "No feedback yet."

  @doc """
  Renders a table of feedback entries. Rows emit a `phx-click` event
  when selected; wire the parent LV to handle it (the default event
  name is `"select_feedback"` with a `"id"` param).
  """
  def feedback_list(assigns) do
    ~H"""
    <div class="phx-replay-list">
      <div :if={@entries == []} class="phx-replay-empty">{@empty_text}</div>
      <table :if={@entries != []} class="phx-replay-list-table">
        <thead>
          <tr>
            <th>When</th>
            <th>Severity</th>
            <th>Who</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={entry <- @entries}
            class={["phx-replay-list-row", entry_id(entry) == @selected_id && "is-selected"]}
            phx-click={@row_click_event}
            phx-target={@row_click_target}
            phx-value-id={entry_id(entry)}
          >
            <td class="phx-replay-col-when">{format_when(entry)}</td>
            <td><span class={"phx-replay-severity severity-#{entry_severity(entry) || "none"}"}>{entry_severity(entry) || "—"}</span></td>
            <td class="phx-replay-col-who">{format_identity(entry_identity(entry))}</td>
            <td class="phx-replay-col-desc">{truncate(entry_description(entry), 80)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :entry, :any, required: true, doc: "Selected feedback row (struct or map)."

  attr :events_url, :string,
    required: true,
    doc:
      "URL that returns `{events: [...]}` JSON for this session. " <>
        "Typically `~p\"/admin/feedback/events/\#{entry.session_id}\"`."

  attr :hide_player, :boolean, default: false, doc: "Render without the rrweb-player panel."

  @doc """
  Renders the detail view for one feedback entry: description,
  severity, identity, metadata, and — unless `hide_player` is set —
  a `<.replay_player />` bound to `events_url`.
  """
  def feedback_detail(assigns) do
    ~H"""
    <div class="phx-replay-detail">
      <header class="phx-replay-detail-header">
        <span class={"phx-replay-severity severity-#{entry_severity(@entry) || "none"}"}>
          {entry_severity(@entry) || "—"}
        </span>
        <h2>{truncate(entry_description(@entry), 140) || "(no description)"}</h2>
        <dl class="phx-replay-detail-meta">
          <dt>When</dt><dd>{format_when(@entry)}</dd>
          <dt>Who</dt><dd>{format_identity(entry_identity(@entry))}</dd>
          <dt>Session</dt><dd><code>{entry_session_id(@entry)}</code></dd>
        </dl>
      </header>

      <section class="phx-replay-detail-body">
        <h3>Description</h3>
        <pre class="phx-replay-description">{entry_description(@entry) || "(none)"}</pre>
      </section>

      <section :if={map_size(entry_metadata(@entry)) > 0} class="phx-replay-detail-meta-section">
        <h3>Metadata</h3>
        <dl class="phx-replay-metadata">
          <%= for {k, v} <- Enum.sort(entry_metadata(@entry)) do %>
            <dt>{k}</dt>
            <dd><code>{format_value(v)}</code></dd>
          <% end %>
        </dl>
      </section>

      <section :if={not @hide_player} class="phx-replay-detail-player-section">
        <h3>Replay</h3>
        <.replay_player events_url={@events_url} session_id={entry_session_id(@entry)} />
      </section>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :events_url, :string, required: true
  attr :session_id, :string, default: nil
  attr :height, :integer, default: 560

  @doc """
  Renders the rrweb-player mount point. The auto-init script shipped
  by `<.phoenix_replay_admin_assets />` detects this element (including
  on LiveView DOM patches) and initializes rrweb-player in place.

  Pass `session_id` so the player participates in the
  `phoenix_replay:timeline` event bus (ADR-0005). When omitted the
  bus uses the element id as a fallback scope.
  """
  def replay_player(assigns) do
    assigns = Map.put_new(assigns, :id, "phx-replay-player-#{:erlang.unique_integer([:positive])}")

    ~H"""
    <div
      id={@id}
      data-phoenix-replay-player
      data-events-url={@events_url}
      data-session-id={@session_id}
      data-height={@height}
      class="phx-replay-player"
      phx-update="ignore"
    />
    """
  end

  # --- helpers ----------------------------------------------------------

  defp entry_id(%{id: id}), do: format_id(id)
  defp entry_id(%{"id" => id}), do: format_id(id)
  defp entry_id(_), do: nil

  defp format_id(id) when is_binary(id) do
    if byte_size(id) == 16 do
      Base.encode16(id, case: :lower)
    else
      id
    end
  end

  defp format_id(id), do: inspect(id)

  defp entry_session_id(%{session_id: v}), do: v
  defp entry_session_id(%{"session_id" => v}), do: v
  defp entry_session_id(_), do: nil

  defp entry_severity(%{severity: v}), do: v
  defp entry_severity(%{"severity" => v}), do: v
  defp entry_severity(_), do: nil

  defp entry_description(%{description: v}), do: v
  defp entry_description(%{"description" => v}), do: v
  defp entry_description(_), do: nil

  defp entry_identity(%{identity: v}) when is_map(v), do: v
  defp entry_identity(%{"identity" => v}) when is_map(v), do: v
  defp entry_identity(_), do: %{}

  defp entry_metadata(%{metadata: v}) when is_map(v), do: v
  defp entry_metadata(%{"metadata" => v}) when is_map(v), do: v
  defp entry_metadata(_), do: %{}

  defp entry_inserted_at(%{inserted_at: v}), do: v
  defp entry_inserted_at(%{"inserted_at" => v}), do: v
  defp entry_inserted_at(_), do: nil

  defp format_when(entry) do
    case entry_inserted_at(entry) do
      %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      %NaiveDateTime{} = ndt -> Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
      str when is_binary(str) -> str
      _ -> "—"
    end
  end

  defp format_identity(identity) do
    case identity do
      %{"kind" => "user", "attrs" => %{"email" => email}} when is_binary(email) and email != "" ->
        email

      %{"kind" => "user", "id" => id} when is_binary(id) and id != "" ->
        id

      %{"kind" => kind} ->
        to_string(kind)

      _ ->
        "—"
    end
  end

  defp truncate(nil, _), do: nil

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_number(v), do: to_string(v)
  defp format_value(v) when is_atom(v), do: to_string(v)
  defp format_value(v), do: inspect(v)
end
