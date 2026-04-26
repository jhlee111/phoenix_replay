# Replay player timeline event bus

The replay player (`<.replay_player>` and the live-mode session-watch
LV) broadcasts a small stream of timeline events on a public JS
channel. Anything on the same page can subscribe — audio narration in
sync with the rrweb cursor, an LV-state debugger that tracks the
playhead, a network-timeline overlay, a custom captions track — without
having to own the rrweb-player instance.

**Status**: Phases 1 + 2 shipped 2026-04-24 (commits `0a66fab`,
`777d3b0`). Internal-stable contract per ADR-0005 — the surface may
move between alpha releases, but never silently.

**Driving ADR**:
[`0005-replay-player-timeline-event-bus.md`](../decisions/0005-replay-player-timeline-event-bus.md)

---

## What is the bus, exactly?

The bus is a JS-only contract surfaced by `priv/static/assets/player_hook.js`:

- A window `CustomEvent` channel named `phoenix_replay:timeline` on
  which the player dispatches `{session_id, kind, timecode_ms, speed}`
  payloads whenever the playback state transitions.
- A friendlier per-session subscription helper —
  `window.PhoenixReplayAdmin.subscribeTimeline(sessionId, callback,
  opts)` — that fans out the same state events plus a
  consumer-controlled cadence of `:tick` events, and returns an
  `unsubscribe` function.

Both surfaces fire from both player flavors: the one-shot
`<.replay_player>` (admin replay of a finished session) and the
`data-mode="live"` player wired by `PhoenixReplay.Live.SessionWatch`
(admin shoulder-surfing of an in-flight session). Live-mode players
behave identically — events emit as the admin scrubs / pauses /
resumes the live cursor.

## Two consumer paths

| Surface | Choose when | Don't choose when |
|---|---|---|
| `addEventListener("phoenix_replay:timeline", cb)` | You want the raw firehose, you intend to throttle yourself, or you're outside any framework that wants a tear-down hook. | You need tick events at a stable cadence — the window event only fires when rrweb-player itself transitions state. |
| `PhoenixReplayAdmin.subscribeTimeline(sessionId, cb, opts)` | You want state events **and** a regular tick at a chosen rate, scoped to one session id, with a clean `unsubscribe()` for cleanup. | Almost never — this is the recommended path. |

The audio narration consumer in `ash_feedback` uses
`subscribeTimeline`; so should anything that needs cursor advancement
between rrweb-player state changes.

---

## Event kinds

> **`speed` field today:** All event payloads include a `speed` field
> for forward-compat. It is currently hardcoded to `1` in
> `player_hook.js`'s `wireTimelineBus`. Consumers should still read it
> on every event (and reconcile via a `lastSpeed` cache) so they pick
> up real values transparently when the rrweb-player speed-UI wiring
> lands. See [Speed reconciliation](#speed-reconciliation) below.

Every event payload has the same shape:

```js
{
  session_id: "rpr_01HXX...",  // matches the player's data-session-id
  kind: "play" | "pause" | "seek" | "ended" | "tick",
  timecode_ms: 12345,           // current player position, integer ms
  speed: 1                      // see "Speed reconciliation" below
}
```

### `play`

Fires when rrweb-player transitions into the `"playing"` state — first
press of Play, resume after a pause, or auto-play on live-mode
catch-up.

| Field | Notes |
|---|---|
| `timecode_ms` | The position the player resumed from. After a pause the value matches the last `pause` event's `timecode_ms`; on first play it's `0` (or wherever an immediate `seek` left the cursor). |
| `speed` | Current playback rate (see header note). |

The hook deduplicates rapid duplicate state changes — two `playing`
notifications back-to-back from rrweb-player only emit one `play`
event on the bus.

### `pause`

Fires when rrweb-player transitions into the `"paused"` state — user
clicks Pause, the player stops at the timeline end, or the player
auto-pauses while a long-running rrweb event processes.

| Field | Notes |
|---|---|
| `timecode_ms` | The position the cursor sat at when paused. |
| `speed` | Current playback rate (see header note). |

Like `play`, deduplicated against repeat notifications.

### `seek`

Fires when the cursor jumps by more than would be explained by
natural playback at the current speed. The detection is heuristic:
each `ui-update-current-time` from rrweb-player is compared against
`(performance.now() - lastTimeStamp) * speed`; if the actual delta
exceeds the predicted delta by more than 500ms, that's a seek.

| Field | Notes |
|---|---|
| `timecode_ms` | The new cursor position post-jump. |
| `speed` | Current playback rate (see header note). |

**Edge cases**:

- The first `ui-update-current-time` after a `play` does **not** fire
  a `seek` — the wall-clock anchor is reset on play to keep the
  resume-from-pause case clean.
- A scrub while paused still fires `seek` (the threshold logic runs
  on every `ui-update-current-time`, regardless of the `play`/`pause`
  state).
- Very small scrubs (<500ms) are below the heuristic threshold and
  will not emit `seek`. This is intentional — RAF jitter at fast
  playback speeds can produce sub-500ms deltas that aren't user
  intent.

### `ended`

Fires when rrweb-player reaches the end of the event stream and emits
its `finish` event. One-shot players see this at the natural end of a
recording; live-mode players generally don't see it (the timeline
keeps growing as new rrweb events arrive).

| Field | Notes |
|---|---|
| `timecode_ms` | The final cursor position when the player finished. |
| `speed` | Current playback rate (see header note). |

The hook attaches the `finish` listener defensively (`try`/`catch`)
because rrweb-player's `getReplayer()` may not be ready synchronously
after construction. If it isn't, the `ended` event simply won't fire
for that player — `pause` is the more reliable end-of-playback
signal.

### `tick`

Periodic "the cursor is at X right now" pings. **Only fired by the
`subscribeTimeline` helper**, never on the raw window-event channel —
ticks are per-subscriber to keep cost proportional to demand.

| Field | Notes |
|---|---|
| `timecode_ms` | `Math.round(replayer.getCurrentTime())` at the moment the tick fires. |
| `speed` | Current playback rate (see header note). |

**Cadence rules** (more in `subscribeTimeline` below):

- Default `tick_hz: 10` → one tick every 100ms.
- `tick_hz: 0` disables ticks for that subscriber. State events still
  flow.
- `deliver_initial: true` (default) fires one tick synchronously on
  subscribe so the consumer doesn't render blank until the first
  interval.
- Ticks fire **regardless of play / pause**. A paused player still
  ticks, just with `timecode_ms` unchanging. Consumers that only care
  about advancement should compare against their own last-seen value.
- Each tick reads `getCurrentTime()` fresh — drift never compounds
  across ticks. Individual ticks can land slightly early or late
  under load, but the next tick re-anchors.

### Speed reconciliation

ADR-0005 OQ2 floated a dedicated `:speed_changed` event. **The
shipped implementation does not include one.** Instead, every payload
carries the `speed` field, and consumers reconcile playback rate by
comparing `detail.speed` to their last-seen value on every event.

In practice the `speed` field is currently hard-coded to `1` — the
player_hook doesn't yet wire up rrweb-player's speed UI to update the
internal `speed` variable inside `wireTimelineBus`. This means
playback-rate changes are not reflected in payloads today. Consumers
that need rate-aware sync (audio playback included) should treat the
field as a forward-compatible contract: read it on every event, set
their own playback rate when it differs from the last-seen value, and
they'll start receiving real values as soon as the player_hook ships
the speed wiring.

> **Note**: this differs from ADR-0005's original draft, which
> proposed `:speed_changed` as a separate kind. The decision to merge
> speed into every payload was taken at implementation time to keep
> the consumer logic uniform; the ash_feedback audio consumer is
> built against the merged shape and works correctly when
> `speed: 1`. Wiring the speed source into `wireTimelineBus` is a
> follow-up ticket — the API shape doesn't change when it lands.

---

## `subscribeTimeline` API

```js
const unsubscribe = window.PhoenixReplayAdmin.subscribeTimeline(
  sessionId,        // string — must match the player's data-session-id
  callback,         // function(detail) — called for every event
  opts              // optional — see below
);

// ...later, on teardown:
unsubscribe();
```

### Options

| Option | Type | Default | Effect |
|---|---|---|---|
| `tick_hz` | number | `10` | Tick frequency in hertz. `0` disables ticks for this subscriber. State events still flow. |
| `deliver_initial` | boolean | `true` | When `true` and `tick_hz > 0`, fire one synchronous `:tick` immediately on subscribe. With `tick_hz: 0` this opt is a no-op (state-only consumers don't need a kick-start). |

### Callback contract

The callback receives the same payload shape for every event kind —
state events come from the same `dispatchTimeline` path that emits
the window event, and tick events are constructed by the helper
itself. Wrap any code that can throw — the helper logs uncaught
callback errors to the console but does not propagate them, so a bad
subscriber can't take down its peers.

### Subscriber independence

Each subscriber's tick cadence is independent — a 60Hz audio-sync
subscriber and a 1Hz state-debugger subscriber on the same session
each pay only their own `setInterval`. The shared `dispatchTimeline`
path fans state events to every subscriber regardless of `tick_hz`.

### Unsubscribe

Calling the returned function:

- Clears the per-subscriber `setInterval` (if `tick_hz > 0`).
- Removes the entry from the per-session subscriber list.
- Removes the per-session entry entirely if no subscribers remain.

Unsubscribing twice is safe — the second call is a no-op.

---

## Use cases

### 1. Audio narration sync

The killer consumer. `ash_feedback` ships an `<.audio_playback>`
component whose hook subscribes to the bus and reconciles a hidden
`<audio>` element on every event. See the
[ash_feedback audio narration guide](https://github.com/jhlee111/ash_feedback/blob/5e64137/docs/guides/audio-narration.md)
for the full sync rules (drift correction, offset windows, autoplay-policy
fallback).

The minimal version:

```html
<div id="my-audio-sync"
     data-session-id="rpr_01HXX..."
     data-audio-url="/uploads/narration.webm">
  <audio></audio>
</div>
```

```js
const root = document.getElementById("my-audio-sync");
const audio = root.querySelector("audio");
audio.src = root.dataset.audioUrl;

const unsubscribe = window.PhoenixReplayAdmin.subscribeTimeline(
  root.dataset.sessionId,
  (detail) => {
    switch (detail.kind) {
      case "play":  audio.play().catch(() => {}); break;
      case "pause": audio.pause(); break;
      case "ended": audio.pause(); break;
      case "seek":  audio.currentTime = detail.timecode_ms / 1000; break;
      case "tick": {
        const drift = Math.abs(audio.currentTime * 1000 - detail.timecode_ms);
        if (drift > 200) audio.currentTime = detail.timecode_ms / 1000;
        break;
      }
    }
  },
  { tick_hz: 10, deliver_initial: true }
);
```

ash_feedback's production hook adds: an `audio_start_offset_ms`
window so audio that starts mid-recording stays muted before its
offset; LiveView `mounted`/`destroyed` lifecycle integration; and
graceful degradation when `subscribeTimeline` isn't on the page yet.

### 2. LiveView state debugger overlay

> Sketch — none of this snapshot-stream infrastructure ships today;
> the example shows how you'd wire it if you had one.

Given an offline snapshot stream of `socket.assigns` keyed by
recording timecode, render the assigns tree at the current cursor
position.

```js
const stop = window.PhoenixReplayAdmin.subscribeTimeline(
  sessionId,
  ({ kind, timecode_ms }) => {
    // 1Hz is plenty for a debugger surface — re-rendering a deep
    // assigns map at 60Hz would be visually noisy and CPU-heavy.
    if (kind === "tick" || kind === "seek") {
      renderAssignsAt(timecode_ms);
    }
  },
  { tick_hz: 1, deliver_initial: true }
);
```

### 3. Network-timeline highlight

If you've captured a parallel stream of network requests with their
own start times, draw focus to whatever request is in-flight at the
current cursor.

```js
window.PhoenixReplayAdmin.subscribeTimeline(
  sessionId,
  ({ kind, timecode_ms }) => {
    if (kind === "play" || kind === "tick" || kind === "seek") {
      highlightRequestsCovering(timecode_ms);
    }
  },
  { tick_hz: 5 }
);
```

### 4. Annotation / logging — state-only consumer

Some consumers don't care about cursor advancement at all — they
only want to log when the user transitions state (for analytics, or
for a separate annotation track that records "user paused at 12.3s
to read the error message").

```js
window.PhoenixReplayAdmin.subscribeTimeline(
  sessionId,
  ({ kind, timecode_ms }) => {
    if (kind === "play" || kind === "pause" || kind === "seek") {
      annotations.push({ kind, timecode_ms, at: Date.now() });
    }
  },
  { tick_hz: 0 } // no ticks, no setInterval, no per-frame cost.
);
```

---

## Lifecycle and cleanup

### Subscriber registration is per-session

`subscribers` is keyed on `session_id`. Two players on the same page
broadcasting under different ids fan their events to disjoint
subscriber lists. Subscribing under a session id that no player has
registered yet is allowed — the entry sits there until a player with
that id constructs and starts emitting.

### Player teardown does not auto-unsubscribe

The hook does not currently call `unsubscribe()` on its own when a
player is destroyed (one-shot finish, live-mode `:session_closed` /
`:session_abandoned`, page navigation). Subscribers continue to live
in the registry, and tick intervals continue to fire — but the per-
tick `getPlayerForSession()` lookup returns `null` and the callback
is a no-op until a player with that id mounts again.

If your consumer outlives the player (e.g., a LiveView hook that
re-mounts on patches), call `unsubscribe()` from the hook's
`destroyed()` to release the `setInterval`. The ash_feedback
`AudioPlayback` hook does exactly this.

### One-page-mount, no cross-tab sync

Subscribers live in the JS module's closure scope. A page reload, a
navigation that reloads `player_hook.js`, or a tab close all clear
the registry entirely. Cross-tab coordination is out of scope per
ADR-0005 — different tabs run different player instances and have
different cursors.

---

## Tick semantics

- **Wall-clock anchored**: `setInterval(tick, 1000 / tickHz)`. Each
  call reads `replayer.getCurrentTime()` fresh, so drift never
  compounds — individual ticks may land slightly early or late under
  load, but the cursor value is always current.
- **Hidden tabs throttle**: browsers throttle `setInterval` in
  hidden tabs (typically to 1Hz minimum). High-cadence consumers
  (60Hz audio sync) will see degraded rates while the tab is
  backgrounded. This is OS-level behavior and intentional. ADR-0005
  OQ3 chose `setInterval` over `requestAnimationFrame` precisely
  because RAF in hidden tabs gets throttled even more aggressively.
- **No back-pressure**: the helper does not coalesce or skip ticks if
  the callback runs slow — slow callbacks compound over time. Keep
  callbacks cheap, or move heavy work to a `requestIdleCallback` or
  worker thread.

---

## Decisions log (from ADR-0005)

| Open item | Resolution |
|---|---|
| **OQ1** — `deliver_initial` default | Shipped as `true`. Consumers that want state-only behavior set `tick_hz: 0`, in which case `deliver_initial` is a no-op. |
| **OQ2** — `:speed_changed` event | **Not shipped as a separate kind.** Speed is merged into every payload's `speed` field; consumers reconcile by comparing against their last-seen value. The internal `speed` variable in `wireTimelineBus` is currently fixed at `1` — wiring it to rrweb-player's speed UI is a follow-up. The API shape is forward-compatible. |
| **OQ3** — tick anchor (interval vs RAF) | `setInterval`, per OQ3's leaning. RAF was rejected because hidden tabs throttle RAF to roughly one frame per second, which would starve audio-sync consumers running in a backgrounded tab. |

---

## Related

- [ADR-0005](../decisions/0005-replay-player-timeline-event-bus.md)
  — design rationale, alternatives considered, scope boundaries.
- [ADR-0004](../decisions/0004-live-session-watch.md) — the
  live-mode player flavor that also emits on this bus.
- [`ash_feedback` audio narration guide](https://github.com/jhlee111/ash_feedback/blob/5e64137/docs/guides/audio-narration.md)
  — first production consumer; the worked example for audio-element
  sync at scale.
- `priv/static/assets/player_hook.js` — the implementation. Read
  `wireTimelineBus`, `dispatchTimeline`, and `subscribeTimeline` for
  the source of truth.
