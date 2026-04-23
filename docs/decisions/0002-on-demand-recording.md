# ADR-0002: On-Demand Recording Mode — "Start Reproduction"

**Status:** Accepted
**Date:** 2026-04-23
**Accepted:** 2026-04-23 (five open questions resolved — see *Resolved items* below)

## Context

The `phoenix_replay` widget currently runs an **always-on continuous
capture** model. When the widget mounts, `client.start()` fires: rrweb
plus the console-record and network-record plugins spin up
immediately, events flow into a 10k-bounded ring buffer, and the
buffer is flushed to `/events` every 5 seconds. When the user submits
a report the buffer is drained and `/submit` finalizes the session.

The core strength of this model is retroactive replay — **"I already
saw the bug, now let me report it"** works, because the DOM
mutations, console errors, and network timeline from the moment the
bug happened are already in the buffer. No re-reproduction needed.

But the always-on model is an adoption blocker in several situations:

- **Privacy / compliance.** Organizations subject to GDPR, HIPAA, or
  stricter internal data-governance policy need capture to start only
  at an explicit user action. `phoenix_replay` today leans on an
  implicit "the privacy policy said we might record" contract, which
  is insufficient where explicit per-session consent is required.
- **Runtime budget.** rrweb plus console-record plus network-record
  run on every page view, not just those that lead to a report. On
  heavy DOM or on low-end devices this cost is paid by every session.
- **Developer reproduction flow.** "Let me capture this cleanly for
  the bug report" has no well-defined entry point. The recorder is
  already running when the user thinks to report, so they have no
  control over where the capture starts.
- **Distance from industry consent UX.** Jam, Loom, CleanShot, Chrome
  DevTools Recorder — the norm is **explicit start → do the thing →
  stop**. Users arrive expecting that flow.

Consumers in the first category (apps embedded in external SaaS
contexts rather than internal tools like gs_net) cannot adopt
`phoenix_replay` today. ADR-0001's follow-up pointer flagged this as
the next architectural decision for the same reason.

## Decision

Add a **`recording` attr** to the widget, **orthogonal** to ADR-0001's
`mode` attr (trigger UX).

```elixir
attr :recording, :atom,
  default: :continuous,
  values: [:continuous, :on_demand]
```

### `recording={:continuous}` (default, backward-compatible)

Current behavior. Recorder and session handshake start at widget
mount. Ring buffer captures continuously. Report drains the buffer.
No change.

### `recording={:on_demand}`

Recorder is idle at mount. Capture starts and stops only via explicit
user action.

**Float mode (`mode={:float}`) flow:**

1. User clicks the floating toggle → panel opens with **"Start
   reproduction"** as the primary CTA (replacing the description form
   as the first screen).
2. Click Start → recorder and session handshake kick off, the panel
   closes, and a fixed **"● Recording — Stop"** pill takes its place.
   The pill defaults to the same corner as the toggle (reads
   `position`), but exposes its own CSS var family
   (`--phx-replay-pill-{bottom,right,top,left,z}`) for independent
   fine-tune.
3. User reproduces the bug.
4. Click the pill's Stop button → recorder halts, events flush, the
   panel reopens showing the standard form (description / severity /
   metadata).
5. Submit → `/submit` closes the session, widget returns to idle.

**Headless mode (`mode={:headless}`) flow:**

Consumer provides the entry point. Two idioms:

- **(A) Via the panel.** Consumer calls `window.PhoenixReplay.open()`;
  the panel shows the same Start CTA screen as the float flow. From
  there the flow is identical.
- **(B) Direct control.** Consumer calls
  `window.PhoenixReplay.startRecording()` (no panel opened, no
  library-supplied pill). The consumer renders its own
  "recording in progress" indicator (e.g. a top-of-app banner).
  `stopRecording()` opens the panel to the form state.

### JS API additions

```js
window.PhoenixReplay.startRecording()   // start recorder + session. no-op if already recording.
window.PhoenixReplay.stopRecording()    // stop + open panel with form. no-op if not recording.
window.PhoenixReplay.resetRecording()   // drop current buffer + session, begin a fresh one.
                                        //   continuous: recorder keeps running against a fresh buffer/session.
                                        //   on_demand:  equivalent to stopRecording() + startRecording(),
                                        //               no-op if not currently recording.
window.PhoenixReplay.isRecording()      // boolean
```

Flat namespace, consistent with `open()` / `close()` (ADR-0001).
`resetRecording()` exists because continuous-mode consumers sometimes
want to discard accumulated noise and capture only the next window
("I've been on this page an hour, a bug is starting, clear and
re-capture"); that use case has no other clean entry point.

### Server-side

The `/session` endpoint itself is unchanged. What changes is **when**
it's called: in `:on_demand` mode, `/session` fires on
`startRecording()`, not on widget mount. Sessions that never lead to
a reproduction never create server state. `:continuous` mode stays
eager — the ring buffer must already be filling for retroactive
capture to work.

## Why this shape

### Why `recording` is orthogonal to `mode`

ADR-0001 decided the **trigger UX** — how the panel opens. This ADR
decides the **capture policy** — when recording runs. Those axes are
independent:

|                         | `recording: :continuous` | `recording: :on_demand` |
|-------------------------|--------------------------|--------------------------|
| `mode: :float`          | Current default behavior | Pill-based reproduction flow |
| `mode: :headless`       | Always recording, consumer-controlled trigger | Explicit start/stop, consumer-controlled UI |

All four cells are legitimate. Headless + continuous makes sense for
internal tools like gs_net where the recorder should always run but
the trigger UX is owned by the host app. Collapsing the two axes into
one attr would blow up to six enum values and obscure the structure.

### Why the pill UI is non-negotiable

On-demand's value proposition is *"the user is in control of when
capture starts."* Without a visible indicator while recording is
active, that contract collapses — the user can forget a session is
running, or leave the page with no way to know whether they're still
being captured. Explicit consent UX requires explicit visual
reassurance.

Exception: headless consumers calling `startRecording()` directly are
assumed to own their indicator UI. The library does not force a pill
on them.

### Why the default stays `:continuous`

Existing consumers (including gs_net) depend on retroactive capture.
Flipping the default would silently degrade report quality and behave
as a breaking change. New consumers with privacy constraints opt in
explicitly with `recording={:on_demand}`.

### Why a capability flag (`autostart: false`) isn't enough

A flag that just disables the recorder leaves the question
*"so how does the user start it?"* unanswered. Without defining the
visible flow (Start CTA → pill → Stop → form), every consumer
reinvents it and starts reading internal event names — exactly the
pattern ADR-0001 closed off in the headless case. Lifting this to a
mode contract makes the flow part of the library's public API.

### Why lazy session handshake

In `:on_demand`, opening a session at mount would (a) waste server
state — most sessions never lead to a report — and (b) contradict the
mode's intent: "the user has not started yet, but the server thinks
they have." Lazy matches the semantics.

`:continuous` stays eager because its retroactive guarantee requires
the buffer to already be filling.

### Impact on the Ash wrapper (ash_feedback)

None. Recording mode is a client-side flow concern. From the
`ash_feedback` Feedback resource's perspective, the submission simply
carries one additional metadata key (e.g.
`metadata.recording_mode: "on_demand"`). If triage or audit later
warrants promoting this to a first-class attribute, that's an
`ash_feedback` ADR — this ADR requires no wrapper changes.

## Alternatives rejected

- **`autostart: true|false` capability flag alone.** Leaves the UX
  undefined; consumers re-invent it. See above.
- **Flip the default to on-demand.** Breaking change; erases
  retroactive capture for existing consumers.
- **Per-page targeting (continuous on `/checkout`, off on
  `/landing`).** Conflates policy (capture or not) with routing
  (where). A consumer who wants this today can already pass a dynamic
  `recording` attr from the root layout — the library doesn't need a
  separate API.
- **Hybrid sampled continuous + burst on-demand** (e.g. 10% of
  sessions record continuously, the rest on demand). Demand signal
  unclear; complexity high.
- **Third-party consent integration (OneTrust, Cookiebot).** Out of
  scope. Consumers handle consent upstream and then choose
  `recording`.
- **Full-page "you are being recorded" overlay banner.** Too
  intrusive. A single pill is sufficient signaling (Loom / Jam
  pattern).

## Consequences

### Positive

- Privacy- and compliance-constrained consumers can adopt, opening an
  enterprise path for the library.
- Sessions that never lead to a report cost effectively nothing for
  rrweb runtime (plugins still load, but the recorder is idle).
- The reproduction flow becomes an explicit, well-scoped artifact —
  captures produced via on-demand mode are higher quality because the
  user intentionally framed them.
- The pill aligns with industry consent UX and increases user trust.
- The `mode` × `recording` matrix is explicit and contracted,
  widening the surface consumers can customize without reaching into
  internals.

### Negative

- More UI surface: Start CTA screen, pill component, Stop → form
  transition logic.
- Two recording modes to document, test, and smoke-check.
- Lazy session changes `/session` failure timing. It used to fail
  near mount (silent warn acceptable); now it fails right after the
  user clicked Start (silent fail is not acceptable — a new visible
  error state is required).
- On-demand surrenders retroactive capture. Docs must make this
  trade-off unmissable so consumers don't pick the wrong mode.
- Three new JS API names become public contract
  (`startRecording` / `stopRecording` / `isRecording`).

### Neutral

- Backward-compatible: omitting `recording` → `:continuous` →
  unchanged behavior.
- Server ingest, storage, and the Ash wrapper are unaffected.
- Pill CSS adds ~40 lines to the shared asset; `asset_path={nil}`
  opt-out still works.

## Scope

**In scope (this ADR):**

- `recording :: :continuous | :on_demand` attr.
- Lazy session handshake for `:on_demand`.
- Panel state flow for on-demand: Start CTA → Recording (pill) →
  Stop → Form → Submit.
- JS API: `PhoenixReplay.startRecording()` / `stopRecording()` /
  `resetRecording()` / `isRecording()`.
- CSS for the pill UI, with an independent
  `--phx-replay-pill-{bottom,right,top,left,z}` var family (same
  shape as the toggle's; default to the toggle's `position`).
- `/session` failure during `startRecording()` surfaces as a visible
  panel error state with a Retry CTA — no pill shown until the
  session is actually live.
- Docs: recording-mode trade-off, privacy guidance.

**Out of scope (future candidates):**

- Per-page / route-level recording policy.
- Built-in consent modal (OneTrust / Cookiebot integration).
- `pause` / `resume` during a recording (Jam has this; value vs.
  complexity unclear).
- Countdown UI ("starting in 3...").
- `recording_mode` as a first-class `ash_feedback` attribute —
  defer to a wrapper-side ADR if needed.
- Panel state events (still deferred, per ADR-0001 out-of-scope).

## Resolved items (decided on acceptance, 2026-04-23)

- **OQ1 — Session failure UX.** When `startRecording()` triggers a
  `/session` request that returns 401 / 403 / 500, **the panel flips
  to a visible error state with a Retry CTA; no pill is shown until
  the session is actually live.** Silent fail is inappropriate for
  on-demand because the user just performed an explicit action (Start
  click) and expects immediate feedback. Error state reuses the
  existing panel-error styling (same as a failed `/submit`) so the
  patterns are consistent. Continuous-mode session failures keep
  their current silent-warn behavior at mount — not a user-initiated
  moment, so no UX obligation changes.
- **OQ2 — Pill position.** **Pill defaults to the toggle's
  `position` preset** (`:bottom_right` unless overridden), so the
  pill appears in the same corner as the toggle — consistent spatial
  mapping, no new attr to learn. Fine-tune is via an independent
  CSS var family `--phx-replay-pill-{bottom,right,top,left,z}`,
  parallel to the toggle's `--phx-replay-toggle-*` family. Consumers
  who want the pill in a different corner than the toggle do so via
  those vars rather than a `pill_position` attr. Keeps the public
  attr surface at one positional knob; the var families provide the
  escape hatch. (Same philosophy as ADR-0001 — preset + CSS var,
  no `:custom` enum.)
- **OQ5 — `startRecording()` in continuous mode + `resetRecording()`
  API.** `startRecording()` stays a no-op in `:continuous` (the
  recorder is already running). The real request — "discard the
  accumulated buffer and capture fresh from now" — is served by a
  new **`resetRecording()`** API that works in both modes.
  Continuous: drops the current buffer + session, starts a new
  session, recorder continues running against the fresh buffer. On-
  demand: if currently recording, equivalent to `stopRecording()` +
  `startRecording()`; if not recording, no-op. Included in scope
  (not deferred) because the continuous reset case has no other
  clean entry point and asking consumers to reach into `_internals`
  would invalidate the internal-isn't-public contract from
  ADR-0001.

- **OQ3 — Headless + on-demand default entry.** When a consumer
  running `mode={:headless}, recording={:on_demand}` calls
  `window.PhoenixReplay.open()`, **the panel renders the Start CTA
  screen by default** — the same screen the float flow uses. The
  library owns the reproduction flow end-to-end so headless
  consumers get a working UX with one call. Consumers who already
  have their own Start UI bypass this by calling `startRecording()`
  before `open()` (or skipping `open()` entirely — they retain full
  control via the JS API). No new attr; the bypass pattern is
  documented in the headless-integration guide. Rejected
  alternatives: opening an empty panel (leaves the quick-integration
  path broken), or parameterizing via a `start_cta_on_open` attr
  (adds surface for a question that has a clear right answer).

- **OQ4 — Multi-tab scope.** **On-demand is tab-local.**
  `startRecording()` in Tab A starts recording only in Tab A; Tab B
  is unaffected until the user clicks Start there too. Each tab
  owns its own session token, pill, `isRecording()` state, and
  submission. This matches the existing `:continuous` semantics
  (which are implicitly tab-local — each tab has independent rrweb
  recorders and sessions — and have not surfaced coordination
  requests). Rejected alternative: global scope via
  `BroadcastChannel` broadcasting `startRecording()` to all tabs
  against a shared session token. Global would auto-consent tabs
  the user didn't interact with, complicate `/session` (multiple
  `/events` streams against one token), and create surprising
  behavior on mid-recording tab close. Consumers with a genuine
  cross-tab need can layer `BroadcastChannel` themselves on top of
  the JS API. If demand surfaces later, a new ADR can introduce
  explicit multi-tab scope as a separate mode — but baking cross-
  tab assumptions into `/session` now would be hard to back out.

## References

- [Jam (jam.dev)](https://jam.dev/) — on-demand capture pattern
  reference.
- [Loom](https://loom.com/) — pill-based recording indicator.
- [Chrome DevTools Recorder](https://developer.chrome.com/docs/devtools/recorder)
  — start/stop flow.
- ADR-0001 — trigger UX (float + headless); this ADR is orthogonal.
