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

  attr :rrweb_src, :string,
    default: @default_rrweb_src,
    doc: "Script URL for rrweb core. Pass `nil` to disable rrweb entirely."

  attr :rrweb_console_src, :string,
    default: @default_console_src,
    doc: "Script URL for rrweb console plugin. Pass `nil` to disable."

  attr :rrweb_network_src, :string,
    default: @default_network_src,
    doc: "Script URL for rrweb network plugin. Pass `nil` to disable."

  attr :asset_path, :string,
    default: "/phoenix_replay",
    doc:
      "Public path prefix where `phoenix_replay.js` / `phoenix_replay.css` " <>
        "are served. Mount `Plug.Static, at: asset_path, from: {:phoenix_replay, \"priv/static/assets\"}`."

  attr :rest, :global

  @doc """
  Renders the PhoenixReplay mount point, stylesheet, and scripts.

  Emits a hidden `<div data-phoenix-replay>` with all configuration on
  data-attributes. The included `phoenix_replay.js` auto-mounts on
  DOMContentLoaded.
  """
  def phoenix_replay_widget(assigns) do
    ~H"""
    <link rel="stylesheet" href={"#{@asset_path}/phoenix_replay.css"} />
    <script :if={@rrweb_src} src={@rrweb_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_console_src} src={@rrweb_console_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_network_src} src={@rrweb_network_src} crossorigin="anonymous"></script>
    <script src={"#{@asset_path}/phoenix_replay.js"} defer></script>
    <div
      data-phoenix-replay
      data-base-path={@base_path}
      data-csrf-token={@csrf_token}
      data-widget-text={@widget_text}
      {@rest}
    />
    """
  end
end
