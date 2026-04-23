# Plan: On-Demand Recording Mode — Implementation

**Status**: ready (ADR accepted)
**Started**: —
**ADR**: [0002-on-demand-recording](../../decisions/0002-on-demand-recording.md)

## Overview

Implement ADR-0002: add `recording :: :continuous | :on_demand` attr
to `phoenix_replay_widget`, parallel and orthogonal to
`mode :: :float | :headless` (ADR-0001). Goal is that consumers with
privacy/compliance constraints or lower runtime-budget tolerance can
opt into an explicit start-stop reproduction flow — recorder idle at
mount, user clicks Start, reproduces, clicks Stop, submits.

Two-phase rollout. Phase 1 is the JS recorder lifecycle refactor +
attr plumbing, usable in headless mode immediately. Phase 2 adds the
pill UI + panel flow states that make `mode={:float}, recording={:on_demand}`
feel first-class.

ADR-0002 is Accepted; all five open questions are resolved in its
"Resolved items" section. This plan's Decisions log indexes them for
quick reference during implementation.

## Phase 1 — Recorder lifecycle + `recording` attr wiring

**Goal**: ship the JS API (`startRecording` / `stopRecording` /
`isRecording`) + `recording` attr + lazy session handshake. No new
panel UI yet. Headless consumers can immediately wire their own
start/stop UX.

### Changes

**`lib/phoenix_replay/ui/components.ex`**
- Add attr:
  ```elixir
  attr :recording, :atom,
    default: :continuous,
    values: [:continuous, :on_demand],
    doc: "`:continuous` starts rrweb capture on mount (current behavior). `:on_demand` waits for startRecording()."
  ```
- Emit `data-recording={@recording}` on the mount div.

**`priv/static/assets/phoenix_replay.js`**
- Split `createClient` internals so that `startSession` + `startRecording`
  can be invoked independently of `start()`:
  ```js
  return { start, report, flush, startRecording, stopRecording, resetRecording, isRecording, _internals }
  ```
  where `start` (legacy public) = `startSession()` + `startRecording()`
  as today.
- `autoMount`:
  - read `el.dataset.recording` (fallback `"continuous"`) into `cfg.recording`
  - if `cfg.recording === "continuous"`: call `client.start()` as today
  - if `cfg.recording === "on_demand"`: skip; register instance for
    global API access only
- Global API additions (delegate to first registered instance, same
  policy as `open`/`close` in ADR-0001):
  ```js
  PhoenixReplay.startRecording = () => firstInstance()?.startRecording();
  PhoenixReplay.stopRecording  = () => firstInstance()?.stopRecording();
  PhoenixReplay.resetRecording = () => firstInstance()?.resetRecording();
  PhoenixReplay.isRecording    = () => !!firstInstance()?.isRecording();
  ```
- `startRecording` behavior:
  - if already recording: no-op, return
  - in `:continuous` mode: no-op (recorder already started at mount)
  - otherwise: call `startSession()` (lazy), call internal rrweb
    recorder start (factored out of current `start()`), flip internal
    `recording = true` flag
  - session handshake failure: reject the returned promise with a
    typed error so the UI layer (Phase 2) can render the error state
- `stopRecording` behavior:
  - if not recording: no-op
  - call `recorder?.stop()`
  - flush buffered events (await)
  - flip flag, **do not** call `/submit` — submission remains the
    user's report action
  - a `stopRecording()` without subsequent `report()` leaves the session
    open-but-drained; next `startRecording()` starts a fresh session
- `resetRecording` behavior:
  - continuous: stop recorder, drop buffer, close current session
    (best-effort), start new session, restart recorder against the
    fresh buffer. Recorder is never idle during the swap (or idle
    only for a single tick).
  - on-demand: if `isRecording()`: `stopRecording()` then
    `startRecording()`; else no-op.
  - shared implementation: wrap around the same session + recorder
    primitives used by start/stop — no new server endpoint.
- `report()` unchanged semantically, but must work whether called
  while recording or after `stopRecording()`.

### Tests

- **Component render test** — render widget with each `recording`
  value, assert `data-recording` pass-through. Default case covered.
- **JS behavior (manual smoke in dummy host)** — checklist:
  - `recording={:on_demand}` mount: no `/session` request fires until
    `PhoenixReplay.startRecording()`
  - `startRecording()` → `/session` fires, rrweb recorder active,
    events flush to `/events`
  - `stopRecording()` → recorder halts, final flush fires, no further
    `/events` traffic
  - `startRecording()` after `stopRecording()` → new `/session`, fresh
    buffer
  - `isRecording()` returns truthy only between start and stop
  - `resetRecording()` in `:continuous`: old buffer dropped, new
    `/session` fires, recorder keeps streaming without a visible idle
    window
  - `resetRecording()` in `:on_demand` while recording: equivalent to
    stop + start, new session token
  - `resetRecording()` in `:on_demand` while idle: no-op, no network
    traffic
  - `startRecording()` in `:continuous` (always-on): no-op, no
    duplicate `/session`
  - Session handshake failure in `:on_demand`: `startRecording()`
    promise rejects with typed error (UI error state lives in
    Phase 2; Phase 1 just needs the rejection to be catchable)
  - `recording={:continuous}` (default) unchanged: session + recorder
    start at mount as today

### DoD (Phase 1)

- [ ] `recording` attr exists with two values + default
- [ ] `data-recording` pass-through verified in component test
- [ ] JS API (`startRecording` / `stopRecording` / `resetRecording` /
      `isRecording`) accessible on `window.PhoenixReplay`
- [ ] Lazy session handshake in `:on_demand` (no `/session` at mount)
- [ ] Eager session handshake in `:continuous` unchanged
- [ ] Manual smoke matrix above passes on dummy host
- [ ] `asset_path={nil}` opt-out still works (no regression)
- [ ] CHANGELOG unreleased entry

### Non-goals (Phase 1)

- No new panel UI states — headless consumers wire their own Start
  button; float consumers get no visible change (panel still opens
  directly to form, recorder starts/stops via developer tooling only
  if they manually call JS API)
- No pill UI
- No session-failure error state polish — deferred to Phase 2

## Phase 2 — Pill UI + float-mode Start/Stop flow

**Goal**: make `mode={:float}, recording={:on_demand}` first-class.
Panel gains a Start CTA as its initial state, a pill appears during
recording, stopping routes to the form, submit closes the session.
Resolve the open UX questions from ADR-0002.

### Decisions log

All five ADR-0002 open questions resolved; the ADR is Accepted.
Full resolutions live in the ADR's "Resolved items" section — this
log is just the index.

- [x] **OQ1** — `/session` failure during `startRecording()` surfaces
      as a visible panel error with Retry CTA; no pill until live.
- [x] **OQ2** — Pill defaults to the toggle's `position` preset;
      independent `--phx-replay-pill-*` CSS var family for override.
      No new `pill_position` attr.
- [x] **OQ3** — Headless `open()` renders the Start CTA screen by
      default; consumers bypass by calling `startRecording()` first.
      No new attr.
- [x] **OQ4** — On-demand is tab-local (parity with continuous).
      Cross-tab coordination is a consumer concern, layered on the
      JS API via `BroadcastChannel` if needed.
- [x] **OQ5** — `startRecording()` no-op in `:continuous`; new
      `resetRecording()` in both modes (continuous keeps running
      against a fresh buffer/session; on-demand restarts).

### Changes

**`priv/static/assets/phoenix_replay.js`**
- Panel state machine additions for `:on_demand`:
  - `idle_start` — initial panel render. Primary CTA: "Start
    reproduction". Optional subtext explaining what will be captured.
  - `recording` — panel hidden (or minimized), pill visible.
  - `form` — post-stop panel render. Current form (description /
    severity / metadata).
  - `submitting` / `submitted` / `error` — existing.
- `renderPill(cfg, panelApi, clientApi)` helper (mirrors ADR-0001's
  `renderToggle` split):
  - mount a fixed-position element with `position: relative` host + a
    recording-dot + label + Stop button
  - reads `position` preset for default placement (OQ2 resolution)
  - click handler: `clientApi.stopRecording().then(panelApi.openForm)`
- Wire state transitions:
  - `mode={:float}, recording={:on_demand}`:
    - toggle click → `panelApi.openStart()` (idle_start state)
    - Start click → `clientApi.startRecording()` → `panelApi.close()` +
      `pillApi.show()`
    - pill Stop click → `clientApi.stopRecording()` → `pillApi.hide()`
      + `panelApi.openForm()`
    - Submit click → `clientApi.report()` → `panelApi.openSubmitted()`
  - `mode={:headless}, recording={:on_demand}`:
    - `open()` → `panelApi.openStart()` (same Start CTA screen as
      the float flow — OQ3 resolution).
    - Consumers with their own Start UI bypass by calling
      `startRecording()` before `open()` (or skipping `open()`
      entirely); their pill/indicator is their concern, but a
      `stopRecording()` call opens the form state so they still
      land in the library's submit flow.

**`priv/static/assets/phoenix_replay.css`**
- Add `.phx-replay-pill` with:
  - fixed position driven by `--phx-replay-pill-{bottom,right,top,left,z}`
    (independent CSS var family, parallel to toggle's
    `--phx-replay-toggle-*`)
  - pulse/dot animation for the recording indicator
  - Stop button affordance
- Modifier classes `.phx-replay-pill--{bottom-right,bottom-left,top-right,top-left}`
  mirror the toggle preset pattern. Pill defaults to the same
  modifier as the toggle's current `position` (read from
  `data-position` on the mount div) so they share a corner by
  default; the CSS var family is the override lane.

**`lib/phoenix_replay/ui/components.ex`**
- No new attr. Pill shares the toggle's `position` (OQ2) and headless
  `open()` renders the Start CTA by default (OQ3) — neither needs a
  knob.
- Update `@doc` with on-demand flow description and link to guide.

### Error state polish

- `/session` 401/403 during Start click → panel flips to `error` state
  with retry CTA (not a silent warn). Keeps consent UX honest — user
  who clicked Start must know whether capture actually started.
- `/session` 500 → same treatment, different message ("server error,
  try again").

### Tests

- **Component render** — no new cases beyond Phase 1 (no new attrs
  in Phase 2).
- **JS manual smoke (dummy host)** — matrix:
  - float + on_demand: toggle → Start CTA → click Start → pill visible
    → click Stop → form appears → submit → session closed
  - headless + on_demand via `open()`: Start CTA flow as above
  - headless + on_demand via direct `startRecording()`: no panel, pill
    visible (or consumer handles own UI), `stopRecording()` opens form
  - `/session` failure during Start click: error panel, no pill shown
  - pill positioning: each of four presets renders pill in correct
    corner

### DoD (Phase 2)

- [ ] Tab-local scope documented in the guide (no code; absence of
      cross-tab sync)
- [ ] Panel state machine handles `idle_start` / `recording` / `form`
      for `:on_demand` mode
- [ ] Pill UI renders with four-corner preset + CSS var fine-tune
- [ ] `/session` failure surfaces as visible error state during Start
- [ ] All matrix cells of (`mode` × `recording`) pass manual smoke on
      dummy host
- [ ] CHANGELOG unreleased entry extended
- [ ] New guide at `docs/guides/on-demand-recording.md`:
  - when to use continuous vs on-demand (trade-off)
  - privacy/compliance positioning
  - headless + on-demand worked example (custom consent modal →
    `startRecording()`)
  - multi-tab note

### Non-goals (Phase 2)

- `pause` / `resume` during recording — deferred
- Countdown UI ("starting in 3...") — deferred
- Built-in consent modal — out of scope (ADR-0002)
- Recording time limit / automatic stop — deferred
- Panel state events — still deferred (ADR-0001 out-of-scope, tracked
  separately)

## Documentation (after Phase 2 DoD)

- [ ] Top-level `README.md` — new "Recording modes" section adjacent
      to existing "Positioning" / "Headless mode"; matrix table of
      `mode` × `recording` combinations with one-line descriptions
- [ ] Privacy guidance paragraph in README — when continuous is
      acceptable (with privacy-policy language), when on-demand is
      required
- [ ] Component `@doc` extended for `recording` attr, cross-link to
      guide
- [ ] CHANGELOG unreleased section enumerates public API additions
      (`recording` attr, 3 JS API fns, 5 CSS vars for pill)

## Risks & rollback

| Risk | Mitigation |
|---|---|
| Lazy session breaks existing metadata pipeline (e.g. server expects session to exist before `/events`) | Lazy only applies in `:on_demand`. `:continuous` path unchanged. Verify `/events` handler gracefully rejects unknown session (already does — returns 401 triggering re-handshake). |
| `stopRecording()` without subsequent `report()` leaks open sessions on server | Session has TTL on server already; this is the same abandonment case as user closing tab mid-recording. Document + monitor. |
| Pill UI conflicts with `mode={:float}` toggle button during `:continuous → :on_demand` switch after mount | Recording attr is static per widget instance; no live switching. If future requirement, separate ADR. |
| Consumer relying on mount-time session handshake for auth side effects | Not expected — session endpoint is internal to phoenix_replay. Grep for external dependencies before Phase 1 merge. |
| JS API names (`startRecording` / `stopRecording` / `isRecording`) conflict with host app globals | Namespaced under `window.PhoenixReplay`. Unchanged risk profile from ADR-0001. |

Rollback: `git revert` each phase's commits. Phase 1 alone is
usable-and-reversible (consumers can opt in or not). Phase 2 revert
restores Phase 1's "JS API only, no UI" state. No migrations, no
storage touches.

## Follow-ups (separate plans/ADRs)

- **phoenix_replay ADR candidate**: panel state events
  (`replay:opened` / `replay:closed` / `replay:recording_started` /
  `replay:recording_stopped`) if observer/telemetry consumer requests
- **ash_feedback ADR candidate**: `recording_mode` as a first-class
  attribute on Feedback resource, for triage filtering ("show me
  on-demand reports only — these came from users who explicitly
  reproduced")
- **Plan**: per-page recording targeting (route-aware `recording`) if
  real consumer case emerges — ADR-0002 explicitly out-of-scope
- **Plan**: JS test infrastructure — rising relevance as JS surface
  grows (ADR-0001 already flagged this)
