# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Phase 0 scaffold: repo, Hex metadata, CI, module stubs with docstring
  contracts for `PhoenixReplay.Router.feedback_routes/2`,
  `PhoenixReplay.Storage` (behaviour), and `PhoenixReplay.Config`.
- Phase 1 client: `priv/static/assets/phoenix_replay.js` — widget UI
  (floating button + modal), ring buffer, session-token handshake
  against `/session`, batched POST to `/events`, final `/submit`,
  optional gzip via `CompressionStream`, CSRF header handling, auto-
  mount on `[data-phoenix-replay]` elements. Gracefully degrades when
  rrweb is missing (metadata-only submissions still work).
- Phase 1 server: `PhoenixReplay.UI.Components.phoenix_replay_widget/1`
  Phoenix function component — emits the mount div + CSS link + script
  tags for client JS and rrweb (jsdelivr CDN by default;
  `rrweb_src`/`rrweb_console_src`/`rrweb_network_src` all overridable
  including `nil` to disable). 5 component tests + Storage behaviour
  tests all green.
- Phase 1 styles: `priv/static/assets/phoenix_replay.css` — themeable
  via CSS custom properties (`--phx-replay-primary`, etc.).
- `position` attr on `phoenix_replay_widget/1` with four corner presets
  (`:bottom_right` default, `:bottom_left`, `:top_right`, `:top_left`).
  Emitted to client JS via `data-position`; client appends a
  `.phx-replay-toggle--<corner>` modifier class to the toggle button.
- Position customization via CSS custom properties
  (`--phx-replay-toggle-{bottom,right,top,left,z}`) on `.phx-replay-toggle`
  or any ancestor. Preset modifier classes use `:where()` so host
  overrides win without needing `!important`. Implements ADR-0001
  Phase 1.
- `mode` attr on `phoenix_replay_widget/1` with two values: `:float`
  (default, renders the floating toggle button) and `:headless` (no
  toggle — host wires its own trigger). Implements ADR-0001 Phase 2.
- `[data-phoenix-replay-trigger]` HTML hook: any element with that
  attribute opens the panel on click. Uses document-level event
  delegation, so dynamically-added triggers work without re-binding.
- `window.PhoenixReplay.open()` / `window.PhoenixReplay.close()` JS
  API. Delegates to the first mounted widget (common 1-widget-per-page
  case). Multi-mount emits a console warning.
- `asset_path={nil}` opt-out: both the stylesheet link and the client
  script tag are skipped, leaving only the mount element. Intended for
  hosts that bundle library assets through their own toolchain or want
  to ship fully custom styling in `:headless` mode.
- Internal refactor: `renderWidget` split into `renderPanel`
  (always-created, owns open/close) and `renderToggle` (only in
  `:float` mode). Enables the headless API and `open`/`close` hook
  without duplicating form logic.
- `recording` attr on `phoenix_replay_widget/1` with two values:
  `:continuous` (default, unchanged behavior — recorder starts at
  mount) and `:on_demand` (recorder idle until explicit start).
  Implements ADR-0002 Phase 1.
- `window.PhoenixReplay.startRecording()` /
  `window.PhoenixReplay.stopRecording()` /
  `window.PhoenixReplay.resetRecording()` /
  `window.PhoenixReplay.isRecording()` JS API. Delegate to the first
  mounted widget. `startRecording()` returns a promise that rejects
  on session-handshake failure so hosts can surface errors in their
  own UI. `resetRecording()` drops the buffer + session and
  restarts against a fresh session when recording is active.
- Lazy session handshake for `recording={:on_demand}` — `/session`
  fires on `startRecording()`, not at widget mount. Sessions that
  never lead to a reproduction create no server state.
- Internal refactor: the `createClient` factory in
  `phoenix_replay.js` exposes `startRecording` / `stopRecording` /
  `resetRecording` / `isRecording` alongside the legacy `start` /
  `report` / `flush`. `start` now delegates to `startRecording` for
  continuity; no breaking change for hosts calling it directly.
- Panel state machine for `:on_demand`: the modal now renders
  `idle_start` (Start CTA with short explanation), `error` (session
  handshake failure with Retry), and the existing `form` screen. In
  `:float` + `:on_demand`, toggle clicks route to `idle_start`;
  submit flow unchanged. Implements ADR-0002 Phase 2.
- Recording pill (`.phx-replay-pill`): visible during an active
  `:on_demand` reproduction in `:float` mode. Pulsing dot + Stop
  button. Clicking Stop halts the recorder, flushes the buffer, and
  opens the report form. The pill replaces the toggle while recording
  (continuous mode keeps the toggle visible as before).
- Pill position presets `.phx-replay-pill--{bottom-right,bottom-left,top-right,top-left}`
  default to the toggle's corner (derived from the widget's
  `position` attr). Fine-tune via the independent
  `--phx-replay-pill-{bottom,right,top,left,z}` CSS var family on
  `.phx-replay-pill` or any ancestor.
- Session handshake failure during an `:on_demand` Start click now
  surfaces as a visible error screen with a Retry button (previously
  the promise rejection was swallowed by auto-mount). Programmatic
  `window.PhoenixReplay.startRecording()` still rejects the promise
  for consumers handling their own UI.
- `window.PhoenixReplay.stopRecording()` in `:on_demand` now also
  opens the report form so headless consumers land in the submit flow
  without extra glue. `:continuous` behavior unchanged.
- `window.PhoenixReplay.open()` routes to the Start CTA when the
  widget is `:on_demand` and idle (previously always opened the
  form). `:continuous` behavior unchanged.
- `docs/guides/on-demand-recording.md` — end-to-end guide covering
  continuous vs on-demand trade-offs, privacy positioning, the
  `:float` and `:headless` flows with worked examples, and multi-tab
  scope note.
