# Design: Unified Feedback Entry — UX, Capture Model, Addon Slots

**Date**: 2026-04-25
**Status**: Draft — brainstorm session 2026-04-25 (with `ash_feedback_demo`
host) produced the decisions captured here.
**Owners**: phoenix_replay (primary), ash_feedback (consumer — see
companion spec).
**ADR**: [0006 — Unified Feedback Entry](../../decisions/0006-unified-feedback-entry.md)
**Driving conversation**: User session 2026-04-25 with `/Users/johndev/Dev/ash_feedback_demo` checkout. Memory `project_two_report_paths.md` framed the
problem; this spec resolves it with a unified UX + capture model.

## Context

ADR-0006 commits the library to a unified entry UX (two equal options on
every "Report issue" click) backed by a client-side ring buffer (no
passive server flushing). This spec is the implementation plan for the
phoenix_replay-side work.

Key UX outcomes the implementation must produce:

- A floating "Report issue" trigger (today's, unchanged).
- A panel with two equal-weight cards: **Report now** / **Record and
  report**.
- A recording pill (Path B in-flight UI) with a `pill-action` addon slot
  for the audio mic toggle.
- A two-step submit for Path B: review (with a `review-media` addon
  slot for the audio playback player) + describe.
- A single-step submit for Path A: notice banner ("recent activity will
  be attached") + description + send. Optional severity if host opts in.
- Capture model: client-side ring buffer (~60s default), no server
  flush until user submits or starts Path B.

## Architectural decisions

### D1 — Capture model: client-side ring buffer

phoenix_replay's `phoenix_replay.js` recorder is restructured into two
states:

- **Passive (default after widget mount)** — rrweb events accumulate in
  a client-side ring buffer of `bufferWindowSeconds` (default 60).
  Older events are evicted by time, not by count. The 5-second flush
  timer is **not started** in this state. No `/session` POST. No
  `/events` POST. Server is unaware the user is on the page.

- **Active (after user clicks "Record and report" OR after Path A
  submit drains the buffer)** — current behavior: handshake `/session`,
  start the flush timer, POST `/events` every 5s, finalize via
  `/submit`. After Active completes (submit or stop), the recorder
  returns to Passive with a fresh empty buffer.

The ring buffer is implemented as a deque of `{event, timestamp}` pairs
with eviction on every push (drop-head while head is older than
`now - bufferWindowSeconds * 1000`). Existing `createRingBuffer` cap
(`maxBufferedEvents: 10000`) stays as a safety net against absurd
event volumes within the window; whichever cap fires first wins.

**Why ring buffer, not deferred-flush queue:** a queue would still need
to upload at submit time, but we'd have no bound on its size. The ring
discards old events as they fall out of the window — memory is
bounded, and "what's in the buffer at submit time" is exactly "the
last N seconds", which is what the UX banner promises.

### D2 — Path A submit flow (passive ring buffer → server)

When the user picks "Report now":

1. Client clones the current ring buffer contents (events array).
2. Client opens the submit form panel (description, optional severity,
   send).
3. On send, client does a one-shot POST to a new endpoint
   `POST /api/feedback/report` (new dedicated route — keeping it
   separate from `/submit` avoids overloading the active-session
   path with a "no session" branch) carrying:
   - `description` (string)
   - `severity` (string or null)
   - `events` (the buffer JSON, pre-uploaded inline since there's no
     prior session)
   - `metadata` (existing fields)
4. Server creates a synthetic `session_id`, persists the events row,
   and creates the feedback record exactly as a normal submit would.
5. Client clears the ring buffer and remains in Passive.

**Why a single inline upload, not handshake-then-events:** Path A is
fire-and-forget — there's no ongoing session to manage. Inlining
the events in the submit POST removes a roundtrip and a partial-failure
window. The server's existing event-storage code path can absorb the
events as if they came in a single `/events` POST followed immediately
by `/submit`.

For very large buffers (rare; ring window caps it), the request body
may exceed the host's Plug body limit. The widget surfaces a friendly
error in that case ("Recording too large to send — try Record and
report for shorter focused capture"). No splitting / chunking is added
in this phase.

### D3 — Path B submit flow (active session, unchanged + new pill UI)

Path B reuses the existing `:on_demand` machinery:

1. User clicks "Record and report" → client discards ring buffer →
   transitions to Active → handshake `/session` → start flush timer →
   rrweb begins fresh capture.
2. **Recording pill** appears (replacing the current pill from ADR-0002
   Phase 2). New pill template renders the timer + Stop button + a
   `<div data-slot="pill-action">` slot that addons can mount into
   (e.g., ash_feedback's mic toggle).
3. User reproduces; events flush every 5s as today.
4. User clicks Stop → flush remaining → transition to **Review state**.
5. Review state opens a new panel with two slots:
   - `<div data-slot="review-media">` — addons (audio playback)
     mount here.
   - The rrweb player (mini, embedded) — phoenix_replay renders via
     existing `<.replay_player>` component embedded in the panel.
   - Re-record button — discards events + starts a new Path B session.
   - Continue button → step 2 (describe + send).
6. Describe step: description + optional severity + Send. Send finalizes
   via existing `/submit`.

**Why two-step (review then describe), not one panel:** the user has
just done a deliberate action ("record fresh") and wants to confirm
the result before committing. Re-record at this stage is one click;
re-record after typing a description loses the description. The
extra step is justified by the deliberate-action context (Path A
keeps a single step because it's the fast path).

### D4 — Two-option entry panel template

Replaces today's panel-open behavior. New template:

```
┌────────────────────────────────────┐
│ Report an issue                    │
│ How would you like to send         │
│ feedback?                          │
│                                    │
│ ┌──────────────────────────────┐   │
│ │ 📨 Report now                │   │
│ │ Includes the recent activity │   │
│ │ from this page.              │   │
│ └──────────────────────────────┘   │
│                                    │
│ ┌──────────────────────────────┐   │
│ │ 🔴 Record and report         │   │
│ │ Start a fresh recording,     │   │
│ │ then describe the issue.     │   │
│ └──────────────────────────────┘   │
└────────────────────────────────────┘
```

Vertical-stacked equal-weight cards. The panel chrome (close button,
positioning) reuses the existing panel container CSS. Each card is a
button-styled clickable region that transitions the panel state.

Headless mode: the host calls `PhoenixReplay.openPanel()` to open this
panel; or `PhoenixReplay.reportNow()` / `PhoenixReplay.recordAndReport()`
to skip the panel and go straight to Path A submit / Path B pill
respectively. The skip APIs are convenience for hosts that want to wire
their own entry choices (e.g., a header button labeled "Report a bug"
goes straight to Path B).

### D5 — `show_severity` host attr

Widget component gains:

```elixir
attr :show_severity, :boolean,
  default: false,
  doc:
    "When true, the submit form (both Path A and Path B's describe " <>
      "step) renders Low/Medium/High severity buttons. When false " <>
      "(default), severity is omitted and the submitted feedback row " <>
      "carries `severity: nil`. End-user widgets should leave this " <>
      "off — severity is a triage decision the receiver makes. Set " <>
      "true for QA-internal portals where the reporter is also the " <>
      "triager."
```

The data attribute `data-show-severity` propagates to the panel JS,
which renders the severity field conditionally. Existing severity UI
(buttons, CSS) is preserved.

### D6 — New addon slots

Extend the `registerPanelAddon` API documented in the Mode-aware spec:

```js
window.PhoenixReplay.registerPanelAddon({
  id: "audio-mic",
  slot: "pill-action",
  modes: ["on_demand"],  // Path B only
  mount: (ctx) => { /* inject mic toggle button */ },
});

window.PhoenixReplay.registerPanelAddon({
  id: "audio-playback",
  slot: "review-media",
  modes: ["on_demand"],
  mount: (ctx) => { /* inject audio player bound to timeline bus */ },
});
```

Slots:

| Slot | Where it renders | Mount lifecycle |
|---|---|---|
| `form-top` (existing) | Above the description textarea in the submit form | Mounts when submit form opens; unmounts on close |
| `pill-action` (new) | Inside the recording pill, between Stop button and the second-line area | Mounts when pill appears (transition to Active); unmounts on Stop |
| `review-media` (new) | Above the rrweb mini-player in the review step | Mounts when review opens; unmounts on Continue or Re-record |

The `ctx` passed to `mount` carries the same shape as today (`addExtras`,
`session_id`, helpers) plus a `timelineBus` reference for slots that
need timeline sync (review-media uses this for the audio playback
component from ADR-0001 Phase 3).

**Mount/unmount contract:** addons return either nothing or a function
from `mount(ctx)`. If a function is returned, phoenix_replay calls it
when the slot DOM disappears (panel close, state transition,
Re-record). This is the addon's signal to release resources (revoke
object URLs, abort fetches, drop blob references). No separate
`unmount` callback registration — the returned function IS the
cleanup. Existing addons that return nothing are unaffected.

### D7 — Host-config opt-out: disable a path

Hosts that want only one path (e.g., a security-sensitive page that
should never offer fresh recording) get:

```elixir
attr :allow_paths, :list,
  default: [:report_now, :record_and_report],
  doc:
    "Which Report Issue paths the panel offers. Default both. Pass " <>
      "`[:report_now]` to hide the Record-and-report card; pass " <>
      "`[:record_and_report]` to hide Report-now. When only one is " <>
      "allowed, clicking the trigger goes straight to that path's UI " <>
      "(no two-option panel)."
```

Single-path hosts get the trigger → submit (Path A) or trigger → pill
(Path B) directly. Both paths is the default.

## Component breakdown

```
┌──────── phoenix_replay (this spec) ────────────────────────────┐
│ Capture                                                          │
│ • phoenix_replay.js: createRingBuffer(windowMs) — sliding eviction│
│ • Recorder state: Passive (ring) ↔ Active (server-flushed)        │
│ • Path A submit: inline events + description in single POST       │
│                                                                  │
│ UX                                                                │
│ • Two-option panel template (Report now / Record and report)      │
│ • Recording pill: timer + Stop + pill-action slot                 │
│ • Review step: rrweb mini-player + review-media slot + Re-record  │
│ • Submit step (both paths): description + optional severity + Send │
│                                                                  │
│ Component API                                                     │
│ • <.phoenix_replay_widget> gains show_severity, allow_paths,      │
│   buffer_window_seconds attrs                                     │
│ • JS API: openPanel(), reportNow(), recordAndReport()             │
│                                                                  │
│ Addon API                                                         │
│ • registerPanelAddon supports slot: "pill-action", "review-media" │
└────────────────────────────────────────────────────────────────┘
                                consumed by ▼
┌──────── ash_feedback (companion spec) ─────────────────────────┐
│ • Audio mic toggle migrates form-top → pill-action               │
│ • Audio playback addon registers at review-media                  │
│ • README updated for Path A/B in new UX                           │
└────────────────────────────────────────────────────────────────┘
                                hosted by ▼
┌──────── ash_feedback_demo ─────────────────────────────────────┐
│ • Demo pages updated to drop the recording=:continuous |        │
│   :on_demand split (single demo page now shows the unified UX)  │
│ • Pages: /demo (default both paths), /demo/path-a-only,         │
│   /demo/path-b-only (allow_paths smoke), /demo/with-severity     │
└────────────────────────────────────────────────────────────────┘
```

## Data flow — Path A submit

```
User clicks Report issue
  → panel opens (two-option)
  → user clicks "Report now"
  → panel transitions to submit form
       (banner: "recent activity will be attached", textarea, Send)
  → user types, clicks Send
  → JS clones ring buffer events
  → POST /api/feedback/report { description, severity, events, metadata }
  → server: create synthetic session_id, persist events, persist feedback
  → response: { ok, feedback_id }
  → JS: clear ring buffer, close panel, return to Passive
```

## Data flow — Path B submit

```
User clicks Report issue
  → panel opens (two-option)
  → user clicks "Record and report"
  → JS: discard ring buffer, POST /api/feedback/session, start rrweb,
        start flush timer, panel closes, pill appears
  → user reproduces; events flush every 5s
  → (optional) user clicks pill-action mic toggle: ash_feedback addon
        starts MediaRecorder, writes audio_start_offset_ms
  → user clicks Stop on pill
  → JS: final flush, stop rrweb, pill disappears, review step opens
  → review: mini rrweb-player (already-uploaded events_url),
            review-media slot (audio player from ash_feedback)
  → user clicks Continue → describe step (textarea + optional severity + Send)
  → POST /api/feedback/submit (existing) with description, severity,
        audio extras (existing forwarding)
  → response: { ok, feedback_id }
  → JS: close panel, return to Passive (fresh empty ring)
```

## Phasing

Single ADR, three phases (each phase commits independently with smoke):

### Phase 1 — Capture model + Passive state

**Scope**: just the recorder restructure. UX is unchanged for one
phase; the widget continues to render the existing panel UI but the
flush behavior is gone in Passive state. Path A submit endpoint added.

- 1.1 Read current `phoenix_replay.js` + tests; map all flush sites.
- 1.2 Implement `createRingBuffer(windowMs)` — time-window eviction +
  unit test (push past window → head evicted; push within window →
  head retained).
- 1.3 Add Passive/Active state machine; remove auto-flush from
  Passive; preserve current Active behavior.
- 1.4 New endpoint `POST /api/feedback/report` (Plug controller in
  `PhoenixReplay.Controllers`) — accepts `{description, severity,
  events, metadata}`, mints session, persists, returns
  `{ok, feedback_id}`. Reuses existing storage adapter calls.
- 1.5 Tests: state-machine unit (transitions), controller unit
  (full submit cycle), integration (widget mount → no `/events`
  POSTs in Passive).
- 1.6 CHANGELOG entry, smoke (deps cp + force recompile + restart);
  verify host page mount makes zero network calls until trigger.

### Phase 2 — Two-option entry panel + Path A UX

- 2.1 Panel template: replace the current open-handler with the
  two-option template; wire card clicks to handlers.
- 2.2 Path A handler: open submit form panel with notice banner +
  textarea + Send; on Send call the new `/report` endpoint with
  ring buffer.
- 2.3 `show_severity` attr + conditional severity field rendering;
  `allow_paths` attr + single-path auto-skip behavior.
- 2.4 JS API: `openPanel`, `reportNow`, `recordAndReport`.
- 2.5 Tests: component test for new attrs; LV-style integration test
  for the two-option panel state transitions; smoke matrix for
  `allow_paths` combinations.
- 2.6 CHANGELOG, README guide update, smoke.

### Phase 3 — Recording pill + review step + new addon slots

- 3.1 Pill template extension: add `pill-action` slot; preserve
  existing timer + Stop button.
- 3.2 Review step panel: rrweb mini-player + `review-media` slot +
  Re-record (discards events, returns to pill) + Continue button.
- 3.3 Describe step (Path B): same UI as Path A submit form (minus
  notice banner; replaced with "Recording 0:24" line). Send hits
  existing `/submit`.
- 3.4 `registerPanelAddon` accepts new slot strings; slot mount
  lifecycle wiring (mount on slot-element appear, unmount on
  disappear).
- 3.5 Tests: addon mount lifecycle (slot appears → mount called;
  slot disappears → unmount called); existing addon tests pass.
- 3.6 CHANGELOG, README addon-API guide update, smoke.

### Phase 4 — Migration notes + ADR-0002 supersede note

- 4.1 ADR-0002 amend addendum: pointer to ADR-0006 supersede.
- 4.2 README migration section: "if you set `recording: :continuous`
  expecting server-side accumulation, that behavior changed — see
  ADR-0006".
- 4.3 Demo pages updated (companion task in `ash_feedback_demo`).

## Test plan

**phoenix_replay (`mix test`):**

- Unit: ring buffer eviction (synthetic clock).
- Unit: state machine — Passive ↔ Active transitions.
- Controller: `POST /report` happy path + body-too-large rejection
  surface.
- Component: `<.phoenix_replay_widget>` with new attrs renders
  expected `data-*` attributes.
- Integration: widget mount → no `/events` POSTs during Passive.

**JS unit (existing harness):**

- `createRingBuffer` time-window eviction.
- Path A submit serializes the buffer correctly.
- `pill-action` / `review-media` slot mount/unmount lifecycle.

**Manual smoke (browser):**

- Mount widget on a fresh page → confirm Network tab shows zero
  requests beyond the assets.
- Type, scroll, click for 30s → click Report issue → click Report
  now → see the events POSTed in the single `/report` request.
- Click Report issue → Record and report → reproduce → Stop → review
  shows the mini-player → Continue → describe → Send → verify
  submit row contains both events and (if mic toggled) audio.
- `allow_paths: [:report_now]` host: trigger goes straight to Path A
  submit form (no two-option panel).

## Risks

| Risk | Mitigation |
|---|---|
| Path A inline-upload body too large for host's Plug body limit | Friendly client-side error + suggestion to use Path B; document `body_reader` config in README |
| Ring buffer cap (60s default) cuts off relevant context for slow bugs | Host-tunable via `buffer_window_seconds`; recommend Path B for any reproduction longer than the window |
| Re-record in review state confuses users (does it discard the audio too?) | Confirmation copy: "Re-record will discard this attempt"; existing addon `unmount` callback is the audio addon's signal to release the blob |
| Addon authors with `slot: "form-top"` + audio-like assumptions break | The audio addon migration is in the companion spec; addon API doc clarifies which slot is appropriate for which mount-time |
| `show_severity: false` default surprises hosts who relied on severity always being present | CHANGELOG entry; the field still exists on the resource and admin can backfill |
| Path B-only hosts (`allow_paths: [:record_and_report]`) lose the fast-text-only escape hatch | Documented as the deliberate trade-off; hosts that want both should leave the default |

## Out of scope

- Server-side TTL for unsubmitted Path B sessions — already covered by
  ADR-0003's idle timeout.
- AdminLive UI changes — admin replay still works against submitted
  events.
- Compression / sampling of the ring buffer — separate ADR if needed.
- Migrating the `:continuous` symbol name — symbol stays per ADR-0006
  Q-F.
- Multi-page Path A reproduction (page navigation discards the ring
  buffer; users wanting multi-page pick Path B).
- gs_net host migration — gs_net is a private workplace repo (memory
  `project_gs_net_visibility.md`); the user owns that migration.

## Decisions log (carry-forward from ADR-0006)

| ADR-0006 question | Decision | This spec implements as |
|---|---|---|
| Q-A capture model | Client-side ring buffer | D1 |
| Q-B entry UX | Two-option always | D4 |
| Q-C mic timing | In-flight pill toggle | D6 (pill-action slot for ash_feedback) |
| Q-D severity | Default OFF, host opt-in | D5 |
| Q-E addon API | Add pill-action + review-media | D6 |
| Q-F symbol fate | Keep `:continuous` / `:on_demand`, redefine | D1 (recorder state names align internally) |

## Addendum trigger

If implementation surfaces facts that contradict the above (e.g.,
ring buffer eviction has a perf problem at high event rates, or the
two-option panel breaks an a11y assumption), append an addendum here
rather than silently revising — same convention prior specs used.
