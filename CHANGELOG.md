# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Mode-aware panel addons (2026-04-25)

- `registerPanelAddon` accepts an optional `modes` array. When present, the addon
  mounts only on widgets whose configured `recording` value (`:continuous` /
  `:on_demand`) is in the list. Omitting `modes` preserves the previous behavior
  (mount on any widget). Filter operates on recording mode only — control style
  (`:float` / `:headless`) is independent.
- The Path B trigger label changed from "Start reproduction" to "Record and report"
  for plainer end-user language. Code symbols (`:continuous` / `:on_demand` /
  `:headless`) and routes are unchanged.

Smoke verified in Chrome on the ash_feedback_demo continuous + on-demand-float +
on-demand-headless pages — see Phase 1.5 smoke matrix in
`docs/superpowers/plans/2026-04-25-mode-aware-panel-addons.md`.

### ADR-0006 Phase 1 — capture model + Path A ingest (2026-04-25)

Recorder restructured around an internal `:passive` / `:active` state
machine. In `:passive` (the new default at widget mount) rrweb continues
to capture into a sliding ring buffer (default 60s window via the new
`bufferWindowMs` option), but **no** `/session` or `/events` POST is
issued. The 5-second flush timer never starts, and `flushOnUnload` is a
no-op. The server is unaware of the user's page activity until they
explicitly report.

`:active` is reached via `startRecording()` and behaves as the old
`:continuous` mode did: handshake `/session`, periodic `/events`
flushes, finalize via `/submit`. `stopRecording()` returns to
`:passive` while preserving the session token so a follow-up `report()`
can still submit using the just-closed session. `report()` itself
clears the token after the submit POST.

`isRecording()` is now derived from the internal state, not a separate
flag — single source of truth.

New `POST /report` endpoint mounted by `feedback_routes/2` (alongside
`/session` `/events` `/submit`) accepts the full Path A payload —
`{description, severity, events, metadata, jam_link, extras}` — in a
single request. The controller mints a synthetic session via
`Storage.Dispatch.start_session/2`, persists events as one batch, and
finalizes immediately. No long-lived `Session` GenServer is involved
(Path A reports are one-shot, not in-flight sessions, so live admin
session-watch correctly does not see them as in-flight).

**Interim regression**: with autoMount no longer calling
`client.start()`, a widget configured with the legacy
`recording={:continuous}` host attr no longer auto-starts an active
session. The widget panel's "Send" button (which routes through
`report()`) succeeds only when the user has previously called
`startRecording()` — i.e., the legacy `:continuous` "always-on"
submit no longer works without an explicit start. The Path B
"Record → Stop → form → Send" flow on `:on_demand` widgets continues
to work because the session token is preserved across `stopRecording`.
The new `/report` endpoint is the substrate for the Phase 2 entry UX
which restores Path A submission for `:continuous` widgets.

Internal: `_testInternals.createRingBuffer` exposed for the
`node test/js/ring_buffer_test.js` smoke. `bufferWindowMs` joins
`maxBufferedEvents` in `DEFAULTS`. The `transitionToPassive()` helper
centralizes teardown for `resetRecording` and `report` (full token
clear); `stopRecording` does a partial teardown (keeps token alive
for follow-up submit).

### Added

- Panel addon API: `window.PhoenixReplay.registerPanelAddon({ id, slot, mount })`
  registers a JS hook into the widget panel form. `mount(ctx)` returns
  optional `beforeSubmit` and `onPanelClose` callbacks. `beforeSubmit`
  returns `{ extras }` which is merged into the `/submit` POST body.
  First consumer: `ash_feedback`'s audio narration recorder.
- DOM slot `<div data-slot="form-top">` rendered between description
  and severity inside the panel form.
- `extras` field on `report()` and on the `/submit` POST body. The
  configured `PhoenixReplay.Storage` adapter receives extras inside
  `submit_params` under the `"extras"` key. Adapter behaviour signature
  unchanged.
- Replay player timeline event bus — Phase 2 (ADR-0005). Friendlier
  subscription helper on top of the Phase 1 window bus.
  - `window.PhoenixReplayAdmin.subscribeTimeline(sessionId, callback,
    opts)` returns an `unsubscribe` function. Callback receives the
    same `{session_id, kind, timecode_ms, speed}` payload as the
    window event.
  - `opts.tick_hz` (default `10`, `0` disables ticks) controls the
    `kind: "tick"` cadence per subscriber. Subscribers throttle
    independently — high-rate consumers don't tax low-rate ones.
  - `opts.deliver_initial` (default `true`) fires one `:tick`
    synchronously on subscribe so consumers don't render blank until
    the first interval.
  - State events (`play`/`pause`/`seek`/`ended`) reach every
    subscriber regardless of `tick_hz`.
- Replay player timeline event bus — Phase 1 (ADR-0005). The replay
  player now broadcasts state-change events to the window so any
  consumer on the page can sync with playback (audio narration, LV
  state debuggers, network-timeline overlays, etc).
  - New window `CustomEvent` channel `phoenix_replay:timeline` with
    payload `{session_id, kind, timecode_ms, speed}`.
  - Event kinds: `play`, `pause`, `seek`, `ended`. Tick events plus a
    `subscribeTimeline` helper land in Phase 2.
  - Both one-shot replay players (`<.replay_player />`) and live-mode
    players (`PhoenixReplay.Live.SessionWatch`) emit on the bus.
  - `<.replay_player>` accepts an optional `session_id` attr that
    scopes its timeline events; falls back to the element id when
    omitted.
- Igniter-based installer (Phase 5f). `mix igniter.install phoenix_replay`
  now patches the host project end-to-end:
  - `:phoenix_replay` config block in `config/config.exs` with TODO-
    marked defaults for `session_token_secret`, `identify`, and
    `storage`.
  - Router patches: `import PhoenixReplay.Router`, the
    `:feedback_ingest` and `:admin_json` pipelines, and scope blocks
    invoking `feedback_routes "/api/feedback"` and
    `admin_routes "/feedback"`. Handles both `use Phoenix.Router`
    and `use <WebModule>, :router` shapes.
  - Endpoint: `plug Plug.Static, at: "/phoenix_replay",
    from: {:phoenix_replay, "priv/static/assets"}` after the `use
    Phoenix.Endpoint` line.
  - Root layout: a widget snippet inserted before `</body>`,
    gated by `Application.get_env(:phoenix_replay, :widget_enabled,
    false)` so installer-generated apps default to capture-off.
  - `<HostApp>.Feedback.Identify` stub module with
    `fetch_identity/1` and `fetch_metadata/1` defaulting to
    anonymous.
  - The `create_phoenix_replay_tables` migration (was already
    copied; now generated through Igniter so it composes with the
    rest).
  Every patcher is idempotent — re-running over its own output
  produces zero diff. Falls back to the original plain-Mix path
  (migration copy + manual README pointer) when Igniter isn't in
  the host's deps. README install section rewritten to lead with
  the one-shot.
- Live session watch — Phase 2 (ADR-0004). `PhoenixReplay.Live.SessionsIndex`
  LiveView lists every in-flight session — the entry point for the
  watch surface. On mount, seeds from `Session.list_active/0` and
  subscribes to a new global topic for live delta. New rows appear on
  `:session_started`; rows disappear on `:session_closed` /
  `:session_abandoned`. Each row links to the watch LV from Phase 1.
  Crash safety net: pids are monitored, so a Session that exits
  without a clean termination broadcast is still cleaned up via the
  `:DOWN` resync path.
- Global PubSub topic `"\#{prefix}:sessions"` — fans out
  `{:session_started, session_id, identity, started_at}` from
  `Session.init/1` and `{:session_closed, ...}` /
  `{:session_abandoned, ...}` alongside the existing per-session
  broadcasts. Per-session subscribers are unaffected; consumers who
  only need "what's active right now" subscribe to the new topic.
  Exposed via `PhoenixReplay.Session.sessions_topic/0`. ADR-0004 OQ1.
- `Session.list_active/0` — snapshot of every running Session,
  serialized via `Task.async_stream/3` (timeout 200ms,
  kill-on-timeout) so a stuck process can't stall the scan. Returns
  a list of state-summary maps `%{session_id, identity, started_at,
  last_event_at, seq_watermark}`. ADR-0004 OQ2 — payload shape.
- `:state_summary` `handle_call` on the Session GenServer — backs
  `list_active/0` and any future "what's the current shape of this
  session" introspection.
- Router macro (`phoenix_replay_live_routes`) updated to mount BOTH
  the index LV (at `:path/`) and the watch LV (at `:path/:id/live`).
  Wrapped in `scope "/", alias: false` so hosts can call the macro
  inside a non-aliased outer scope.
- 10 new tests: 4 for the global topic + state_summary + list_active
  in `session_test.exs`; 6 for `Live.SessionsIndex` covering mount,
  insert/remove broadcasts, empty state, and the crash-DOWN resync
  path.
- Live session watch — Phase 1 (ADR-0004). `PhoenixReplay.Live.SessionWatch`
  LiveView streams an in-flight recording into rrweb-player in real
  time. On mount: catch up from the persisted buffer, then subscribe
  to the per-session PubSub bus from ADR-0003 Phase 2. Appends arrive
  via `push_event` → `phx:phoenix_replay:append` window events, which
  the updated `player_hook.js` dispatches to the live player via
  `rrweb-player.addEvent/1`. `:session_closed` / `:session_abandoned`
  render an overlay banner alongside a status pill.
- `Session.catchup/1` — atomically returns `{events, seq_watermark}`
  for a running session (serialized against `handle_call({:append, ...})`
  so broadcasts strictly > the returned watermark are new). Falls back
  to `Storage.Dispatch.fetch_events/1` when the session is no longer
  registered; in that case the watermark is `:infinity` and dedup is
  disabled.
- `data-mode="live"` branch in `player_hook.js` — scans for
  `[data-phoenix-replay-player][data-mode="live"]`, waits for the first
  `phx:phoenix_replay:catchup` event to seed rrweb-player, and appends
  subsequent frames via `player.addEvent(ev)`. Buffered queueing handles
  the small window between DOM mount and player-script ready.
- `phoenix_replay_live_routes/2` router macro — mounts
  `Live.SessionWatch` at `:path/:id/live`. Intended to sit inside an
  admin-authenticated scope.
- Test infrastructure: `PhoenixReplay.TestEndpoint` +
  `PhoenixReplay.TestRouter` +  `PhoenixReplay.ConnCase` in
  `test/support/` so future LV tests have a real endpoint to dispatch
  against. `lazy_html` added as a test dependency (required by
  `Phoenix.LiveViewTest` for DOM assertions).
- 6 new LV unit tests covering mount + catchup push, live append dedup
  by watermark, stale-seq drop, `:session_closed` + `:session_abandoned`
  overlay + push, and fallback when no Session process is registered.
- Session continuity across page loads — Phase 2 (ADR-0003). Adds the
  server-side per-session GenServer layer that Phase 1 deferred:
  `PhoenixReplay.Session` (one process per `session_id`, registered
  under `PhoenixReplay.SessionRegistry`, supervised by
  `PhoenixReplay.SessionSupervisor`). Holds in-memory `seq_watermark`,
  a bounded queue of recent seqs for in-flight dedup, and an
  idle-timer. `EventsController` and `SubmitController` now route
  through this process (with a lookup-or-start fallback that re-seeds
  state from the DB after a crash). `SessionController` resume now
  checks the registry first and falls back to the Phase 1 DB path —
  zero behavior change for cold starts.
- PubSub broadcasts on the new bus
  `"\#{prefix}:session:\#{session_id}"`:
  * `{:event_batch, session_id, events, seq}` after every accepted
    `POST /events`
  * `{:session_closed, session_id, reason}` on `Session.close/2`
    (called from `POST /submit` with reason `:submitted`)
  * `{:session_abandoned, session_id, last_event_at}` when the idle
    timer expires
  Live admin LiveViews can subscribe to stream rrweb frames or render
  abandonment without polling. Topic prefix configurable via
  `:pubsub_topic_prefix`.
- `:pubsub` config key — atom naming the host's `Phoenix.PubSub`
  instance. When unset, the library starts its own
  `PhoenixReplay.PubSub` under its supervisor (zero-config; one extra
  process). ADR-0003 OQ4.
- `:pubsub_topic_prefix` config key — string prepended to every
  Session topic. Default `"phoenix_replay"`. ADR-0003 OQ4.
- `Session.lookup_or_start/2` — idempotent helper used by the events
  ingest path to spawn a Session on first contact (fresh sessions or
  crash-restart recovery).
- README "Subscribe to live session events (optional)" section, new
  `docs/guides/multi-page-reproductions.md` guide, three new rows in
  the config-keys table (`:session_idle_timeout_ms`, `:pubsub`,
  `:pubsub_topic_prefix`).
- 10 new unit tests for `PhoenixReplay.Session` (append + dedup +
  watermark + close + idle teardown + lookup_or_start), backed by an
  in-memory `PhoenixReplay.Storage.TestAdapter` under `test/support`.
- Session continuity across page loads — Phase 1 (ADR-0003).
  Recordings now survive `<a href>` navigations, form posts, LV↔dead-view
  transitions, and reloads. Client caches the session token in
  `sessionStorage` and sends it back to `/session` as a resume header on
  the next page; server calls the new `Storage.resume_session/2` callback
  to decide whether to resume or mint fresh. Full ADR-0003 open questions
  resolved in this phase: `:continuous` silently starts fresh on stale,
  `:on_demand` surfaces the panel error screen (reusing the ADR-0002
  Phase 2 infra); `session_idle_timeout_ms` config (default 15 minutes)
  gates resumability.
- `window.navigator`-like tail flush via `fetch(..., { keepalive: true })`
  on `pagehide` + `beforeunload` — tail events that used to die in the
  unload now deliver. Capped at `3 × maxEventsPerBatch` per unload (OQ3)
  with a single `console.warn` on overflow. Double-flush guard
  coordinates the two event listeners.
- `:on_demand` widgets auto-resume at mount when
  `sessionStorage.phx_replay_recording === "active"`: the pill re-appears
  without a click, carrying the same `session_id` across pages. Stale
  resumes route through the panel's error screen with a Retry CTA.
- `PhoenixReplay.Storage.resume_session/2` behaviour callback +
  `PhoenixReplay.Storage.Events.resume/4` helper shared by shipped
  adapters (Ecto + AshFeedback). Adapters that predate ADR-0003 need to
  implement the new callback.
- `:session_idle_timeout_ms` config key (default `900_000`, 15 minutes
  per OQ2). Last-event-at older than this marks the session stale.
- `POST /session` response shape extended with `resumed :: boolean` and
  `seq_watermark :: integer`. Existing clients (no resume header)
  continue to see `resumed: false, seq_watermark: 0` — backward
  compatible.
- `PhoenixReplaySessionInterruptedError` JS error class raised from
  `ensureSession` when an `:on_demand` widget's cached token fails
  resume. Panel orchestrator catches and renders the error screen.
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
