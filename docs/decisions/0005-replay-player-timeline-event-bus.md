# ADR-0005: Replay Player Timeline Event Bus

**Status**: Accepted
**Date**: 2026-04-24
**Builds on**: ADR-0004 (Live Session Watch)

> **2026-04-26 update (phoenix_replay@2074a12):** the bus implementation
> moved from `priv/static/assets/player_hook.js` (admin-only) into
> `priv/static/assets/phoenix_replay.js`, where it's exposed on
> `window.PhoenixReplay.subscribeTimeline / wireTimelineBus /
> registerPlayer`. `player_hook.js` now delegates to those helpers.
> Reason: the panel mini-player (review modal in user-facing pages)
> needs to publish on the same bus so review-media addons can sync
> audio without an admin-only dependency. Public surface is unchanged
> for existing admin consumers — `PhoenixReplayAdmin.subscribeTimeline`
> stays as a delegating alias.

## Context

The replay player today is a one-way black box: it consumes an
`events` array (or live stream from ADR-0004) and renders rrweb
playback. Nothing escapes from the player — there's no way for code
on the same page to know "what time are we at," "did the user
pause," or "did the user scrub to T+15s."

Real consumers want exactly that. The immediate motivator is
microphone narration in `ash_feedback`: an `<audio>` element that
needs to play in lock-step with the rrweb timeline. Looking past
audio:

- An LV-side state debugger that, given a recorded
  `socket.assigns` snapshot stream, shows the assign tree at the
  current timecode.
- A network-timeline highlight panel that draws focus to the fetch
  call happening at the current cursor.
- An external dashboard sync — Grafana / Sentry breadcrumbs jumping
  to the same wall-clock as the player.
- Future: video clips, screenshot timelines, captions, pointer
  overlays.

**The common denominator is not "secondary media" but "any
time-ordered consumer."** A media-only API would prematurely close
the design space. We want phoenix_replay to broadcast timeline state
and let consumers build whatever sync they need on top.

## Question A — what does phoenix_replay broadcast?

Two broad options.

1. **Media-track slot** — `<.replay_player>` accepts `<:media>`
   children and `player_hook.js` wires them as `<audio>` /
   `<video>` elements bound to the rrweb timeline. Easy for the
   audio case; closed for the LV-state-debugger case (no media
   element to attach).
2. **Timeline event bus** — `player_hook.js` emits a stream of
   timeline events on a public JS channel. Consumers subscribe and
   do whatever they want with the events. Audio playback is one
   client of that bus; the LV-state debugger is another; future
   things are more.

**Decision (proposed)**: option (2). The slot pattern in (1) bakes
in an assumption ("consumer = media element with `currentTime`")
that the LV-state debugger violates. The event-bus pattern composes:
ash_feedback can ship an audio component that subscribes to
phoenix_replay's bus, and phoenix_replay never imports
`<audio>` / `<video>` semantics. ADR-0004 already established the
"phoenix_replay broadcasts, consumers subscribe" pattern with
PubSub on the server; this extends the same pattern to the client.

## Question B — what events fire on the bus?

Two natural categories: **state-change events** (rare,
demand-driven) and **tick events** (frequent, time-driven).

State-change events:
- `:play` — playback resumed (or started).
- `:pause` — playback paused.
- `:seek` — user scrubbed; the new position is in `timecode_ms`.
- `:ended` — playback reached the end.
- `:speed_changed` — playback rate changed.

Tick events:
- `:tick` — periodic "current time is now X" updates.

**Decision (proposed)**: ship both, plus a public payload shape:

```js
window.addEventListener("phoenix_replay:timeline", (e) => {
  // e.detail = {
  //   session_id: "...",       // scope (ADR-0004 multi-player)
  //   kind: :tick | :play | :pause | :seek | :ended | :speed_changed,
  //   timecode_ms: 12345,      // current player position in ms
  //   speed: 1.0               // current playback rate
  // }
});
```

State-change events always fire. Tick events fire at a rate
controlled by the consumer (Question C). Both ride the same window
custom-event channel — same scoping rule (`session_id`), same
payload shape.

## Question C — tick rate (the "playback observation rate")

rrweb itself records at variable density (events fire when the DOM
changes, not on a clock). The replay player advances `currentTime`
via `requestAnimationFrame` — typically 60Hz. **Tick rate is a
separate concept from either**: it's how often phoenix_replay tells
consumers what `currentTime` currently is.

A fixed default doesn't fit. Different consumers need different
cadences:

- **Audio narration sync** at 60Hz — pull is so cheap (set a
  property on `<audio>`) that a smooth cursor matters more than
  cost.
- **Visual progress bar** at ~10Hz — perceptually smooth, 6× cheaper
  than 60Hz.
- **LV state debugger** at ~1Hz — re-rendering an assigns tree at
  60Hz would be obscene.
- **Logging / annotation** at 0Hz — only state changes are
  interesting; tick is useless.

**Decision (proposed)**: phoenix_replay exposes a subscription
helper that takes a per-subscriber rate. Each subscriber pays only
their own throttle:

```js
const unsubscribe = PhoenixReplay.subscribeTimeline(sessionId, callback, {
  tick_hz: 10  // default; 0 → no ticks, only state changes
});
```

Internally the helper sets up a `setInterval` (or `null` for
`tick_hz: 0`) that reads `replayer.getCurrentTime()` and dispatches
a `:tick` event. State-change subscriptions are independent of
`tick_hz`.

Raw window custom events still fire at the player's natural rate
for advanced consumers that want to handle their own throttling.
The helper is the friendly path; the window bus is the escape
hatch.

## Question D — sourcing the events from rrweb-player

Empirical recon (`window.rrwebPlayer.default`, against the v2.0.0-
alpha.18 build we ship) confirms:

- `player.addEventListener("ui-update-player-state", cb)` — fires
  with `"playing" | "paused" | "live"`.
- `player.getReplayer()` → returns a `Replayer` instance.
- `replayer.getCurrentTime()` — current playback position in ms.
- `replayer.on(name, cb)` / `replayer.off(...)` — granular event
  subscription on the replayer. Likely `event-cast`,
  `start`, `pause`, `resume`, `finish`, but exact set TBD at impl.

**Decision (proposed)**: phoenix_replay's player_hook will:

- Subscribe to `ui-update-player-state` for `:play` / `:pause`.
- Subscribe to `replayer.on("finish", ...)` for `:ended`.
- Detect `:seek` from a watcher on `getCurrentTime()` deltas
  (jumps not consistent with `speed × elapsed_ms`). Or, if
  rrweb-player exposes a `seek` event directly, use it.
- Read `getCurrentTime()` for every tick and seek payload.

**Why not** push tick payloads from rrweb's
`ui-update-current-time` (which fires at RAF cadence)? Because
RAF-bound dispatch costs each subscriber even at low cadences.
`setInterval` per subscriber lets each consumer pay only its
chosen rate.

## Question E — naming and stability

**Decision (proposed)**:

- Event channel: `phoenix_replay:timeline` (mirrors the existing
  `phx:phoenix_replay:*` pattern from ADR-0004 push_events).
- Helper: `window.PhoenixReplayAdmin.subscribeTimeline/3` — same
  namespace as the existing `initAll` / `initOne` exposed by the
  player_hook.
- API frozen at the "5 kinds + tick" set above. New event kinds
  require a follow-up ADR. New payload fields are additive (don't
  remove or rename existing keys).

## Out of scope

- **Server-side timeline broadcasts** (phoenix_replay LV pushing
  timeline state via push_event). The bus is purely client-side —
  the player is the source of truth, and consumers also live in
  the browser. Server-side observers should subscribe to ADR-0004
  PubSub broadcasts instead.
- **Persisting timeline cursor state** (resume-from-where-you-paused
  across reloads). Out of band; consumers can `localStorage` their
  own state if they want.
- **Cross-tab sync** of timeline cursor. Different tabs → different
  player instances → different cursors. Not a phoenix_replay
  concern.
- **Audio / video / specific media** wiring. Lives in
  ash_feedback (or other consumers). The phoenix_replay bus is
  data-agnostic.

## Consequences

### Positive

- Audio narration in ash_feedback ships without a single line of
  audio code in phoenix_replay.
- Future consumers (LV state debugger, network-timeline overlay,
  Grafana sync) compose without ADR pressure on phoenix_replay's
  player.
- API surface is small — one event channel, one helper function,
  five event kinds.

### Negative / risks

- The window-event channel pollutes a global namespace. Mitigation:
  prefix is unambiguous (`phoenix_replay:timeline`); subscribers
  check `session_id` to scope.
- rrweb-player's event API is alpha (`v2.0.0-alpha.*`) — we're
  binding to a moving target. Mitigation: thin adapter layer in
  `player_hook.js` so a future rrweb upgrade only touches one
  module.
- Tick subscribers can stack (N subscribers × tick_hz polls/sec).
  At reasonable defaults this is fine; explicit cap deferred until
  it bites.

## Open items

- **OQ1**: should `subscribeTimeline` deliver a `:tick` immediately
  on subscribe (so consumers don't render "blank" until the next
  interval)? Lean: yes, `deliver_initial: true` default.
- **OQ2**: should we expose a `:speed_changed` event? rrweb-player's
  speed UI exists; the `ui-update-player-state` payload may or
  may not include it. Confirm at impl. Lean: yes, separate event.
- **OQ3**: tick anchor — `setInterval` (wall-clock) vs.
  `requestAnimationFrame + read` (display-synced). Lean:
  `setInterval`. RAF anchoring is appealing for visual smoothness
  but hidden tabs throttle RAF aggressively, which could starve
  consumers that need cursor advancement (audio sync, etc).

## References

- ADR-0004 — established the "broadcasts + consumers" pattern
  on the server side; this ADR mirrors it on the client.
- rrweb-player v2.0.0-alpha.18 — empirical event API confirmed
  against the bundle we already ship via
  `<.phoenix_replay_admin_assets />`.
- `priv/static/assets/player_hook.js` — current host of the
  rrweb-player init, where this ADR's wiring lands.
