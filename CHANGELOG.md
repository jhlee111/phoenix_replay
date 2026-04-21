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
