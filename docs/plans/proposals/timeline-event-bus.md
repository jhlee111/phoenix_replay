# Plan: Replay Player Timeline Event Bus

**Status**: Proposal — pending ADR-0005 acceptance
**Drafted**: 2026-04-24
**ADR**: [0005-replay-player-timeline-event-bus](../../decisions/0005-replay-player-timeline-event-bus.md)

## Why

ADR-0005 declares phoenix_replay's replay player as a **timeline
broadcaster** — emit state-change + tick events on a public JS
channel; let consumers (audio playback, LV state debuggers,
overlays) build whatever sync they need. Audio narration in
ash_feedback is the immediate driver; future consumers come along
for free.

This proposal turns ADR-0005's decisions into a phased
implementation plan.

## Phases

### Phase 1 — Event bus + state events

**Goal**: window custom events fire when the player transitions
between play / pause / seek / ended. No tick events yet. Consumers
can subscribe with raw `addEventListener`.

**Changes**

- `priv/static/assets/player_hook.js`:
  - In the existing one-shot init (and the `data-mode="live"` init
    from ADR-0004), after constructing the rrweb-player, attach:
    - `player.addEventListener("ui-update-player-state", ...)` →
      `:play` / `:pause` (and `:ended` if rrweb fires it as a
      state).
    - `replayer.on("finish", ...)` → `:ended` if not covered
      above.
    - A wrapper around `goto`/scrub UI to detect manual jumps →
      `:seek`. If rrweb-player fires a usable seek event, use it
      directly.
  - On each transition, dispatch
    `new CustomEvent("phoenix_replay:timeline", {detail})` with
    `{session_id, kind, timecode_ms, speed}`.
  - Track per-player state (last known timecode, last speed) on
    the same `livePlayers` map already used for live mode; use a
    parallel map for one-shot players.

**Tests**

- Manual smoke against the live-watch LV in the demo: open a
  recording, attach a `console.log` listener for
  `phoenix_replay:timeline`, click play / pause / scrub, confirm
  payloads.
- Phoenix.LiveViewTest can't observe window events directly. Defer
  automated coverage to Phase 4 (JS test infra) — listed as a
  recurring debt.

**DoD**

- [ ] State events fire correctly for play / pause / seek / ended.
- [ ] Each event's payload includes `session_id`, `kind`,
      `timecode_ms`, `speed`.
- [ ] One-shot AND live-mode players both broadcast (the latter is
      the headline use case for ADR-0004 admins).
- [ ] CHANGELOG entry.

### Phase 2 — `subscribeTimeline` helper + tick events

**Goal**: a friendly subscription helper that handles per-subscriber
tick rate. Most consumers should never need to talk to the raw
window-event channel.

**Changes**

- `player_hook.js`:
  - Expose `window.PhoenixReplayAdmin.subscribeTimeline(sessionId,
    callback, opts)` returning an `unsubscribe` function.
  - `opts.tick_hz`: default 10. `0` (or `:off`) disables ticks for
    that subscriber.
  - `opts.deliver_initial`: default `true`. When the subscriber
    attaches, fire one `:tick` immediately so consumers don't
    render blank until the first interval.
  - Internally: track an array of subscribers per session_id; for
    each, run a `setInterval(1000 / tick_hz, () => dispatch :tick
    with current getCurrentTime())`. State events go to all
    subscribers regardless of `tick_hz`.
  - Cleanup: unsubscribe stops the interval and removes the entry.
    Player destruction (ADR-0004 :session_closed / :session_abandoned
    or one-shot finish) calls all unsubscribers and clears the
    map for that session.

**Tests**

- Manual smoke: attach two subscribers with different `tick_hz`
  (60 and 1) on the same session, confirm both fire at expected
  cadences and state events reach both.
- A simple unit test in JS could go via the future Playwright /
  Puppeteer infra. Skip for now.

**DoD**

- [ ] `subscribeTimeline` returns an `unsubscribe` that actually
      unsubscribes (no leaks).
- [ ] `tick_hz: 0` produces no tick events; state events still
      flow.
- [ ] `deliver_initial: true` fires one `:tick` synchronously on
      subscribe.
- [ ] Ticks include current `timecode_ms` from
      `replayer.getCurrentTime()`.
- [ ] CHANGELOG entry.

### Phase 3 — Documentation + integration guide

**Goal**: make it discoverable so ash_feedback (and other
consumers) can wire in without spelunking through `player_hook.js`.

**Changes**

- `README.md`: short section under the existing "Subscribe to live
  session events (optional)" describing `subscribeTimeline` and
  the `phoenix_replay:timeline` channel. Worked example: minimal
  audio-element sync.
- `docs/guides/timeline-event-bus.md` (new): the full reference —
  every event kind, payload shape, all options on
  `subscribeTimeline`, examples for the four use cases listed in
  ADR-0005 Context.

**DoD**

- [ ] README section + new guide file.
- [ ] Linked from `docs/guides/` index (if there is one) or top of
      README docs section.

## Risks & rollback

| Risk | Mitigation |
|---|---|
| rrweb-player alpha event API changes | Adapter layer in `player_hook.js` keeps the surface area exposed to consumers stable; only the internal `addEventListener` calls move. |
| Dispatch overhead at high tick_hz × N subscribers | Each subscriber is independent; high-rate subscribers don't pay for low-rate ones. Defer hard cap until a real consumer hits it. |
| Tick `setInterval` drift | Wall-clock anchoring; each tick reads `getCurrentTime()` so drift never compounds — only individual ticks may land slightly early or late. |

**Rollback per phase**:

- Phase 1: drop the listener attachments + `dispatchEvent` calls.
  No external API surface changes, no consumer breakage (nothing
  was subscribing yet).
- Phase 2: drop `subscribeTimeline`. Direct window-event consumers
  unaffected.
- Phase 3: doc-only.

## Decisions log (from ADR-0005)

- [ ] **OQ1** — `deliver_initial: true` default. Confirmed in the
      proposal.
- [ ] **OQ2** — `:speed_changed` shipped as a separate kind.
      Pending impl confirmation that rrweb-player exposes the
      hook.
- [ ] **OQ3** — `setInterval` anchor (wall-clock). RAF rejected
      due to hidden-tab throttling.

Promote this proposal to `active/` once ADR-0005 is Accepted.

## Follow-ups (separate plans)

- **JS test infrastructure** (Playwright / Puppeteer) — recurring
  debt across ADR-0001/2/3/4/5. Phase 1 + 2 of this plan rely on
  manual smoke; once JS infra lands, automate the bus contract.
- **ash_feedback audio narration** — first real consumer of this
  bus. Has its own ADR + plan in the `ash_feedback` repo.
