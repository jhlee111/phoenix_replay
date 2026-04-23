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
