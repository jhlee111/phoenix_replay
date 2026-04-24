# Plan: Live Session Watch — Admin "Shoulder-Surf"

**Status**: Completed (2026-04-24). Phase 1 in `d65d0f7`, Phase 2 in `b4fa097`.
**Drafted**: 2026-04-23
**Promoted**: 2026-04-24 (ADR-0004 Accepted; OQ1–4 defaults confirmed)
**ADR**: [0004-live-session-watch](../../decisions/0004-live-session-watch.md)
**Phase 3** (reusable component for power-user composition) explicitly deferred — defer until a real consumer needs it.

## Why

ADR-0003 Phase 2 wired `PhoenixReplay.Session` to broadcast
`:event_batch` / `:session_closed` / `:session_abandoned` on
`"phoenix_replay:session:#{session_id}"`. The broadcast has no
consumer yet. The natural one is an admin LiveView that streams the
recording into `rrweb-player` as it happens — the SaaS-replay "live
cobrowse" experience, self-hosted.

This proposal turns ADR-0004's decisions into a phased
implementation plan. ADR-0004's recommended path is assumed; revisit
phases if any of the four open questions resolve differently.

## Phases

Each phase is intentionally small and revertable. Phase 1 ships the
"watch one known session_id" surface; Phase 2 layers discoverability
+ the index LV.

### Phase 1 — Single-session watch LV (no discoverability)

**Goal**: an admin can navigate to
`/phoenix_replay/sessions/:id/live` and see a single session's
recording stream into rrweb-player in real time, with catch-up from
the historical buffer.

**Changes**

- `lib/phoenix_replay/live/session_watch.ex` (new) —
  `use Phoenix.LiveView`. On `mount/3`:
  - `Storage.Dispatch.fetch_events/1` for catch-up
  - `Phoenix.PubSub.subscribe/2` to the per-session topic
  - track `:seq_watermark` in assigns so subsequent
    `:event_batch` messages dedup against the catch-up tail
  - render the player component
- `lib/phoenix_replay/ui/components/session_watch.ex` (or extend
  existing `UI.Components`) — `<.session_watch session_id />`
  function component that renders the rrweb-player mount div with
  `data-mode="live"`. Reusable outside the LV.
- `priv/static/assets/player_hook.js` — extend with a
  `data-mode="live"` branch:
  - initialize player with `events: []`
  - subscribe via `this.handleEvent("phoenix_replay:append", ...)` →
    iterate batch, call `player.addEvent(ev)` per event
  - subscribe to `this.handleEvent("phoenix_replay:closed", ...)` and
    `phoenix_replay:abandoned` → render an overlay banner
- `lib/phoenix_replay/router.ex` — add a router macro
  `phoenix_replay_live_routes "/sessions"` that mounts the index +
  watch LVs under a host-wrapped scope. Documented in README under
  the existing router section.

**Tests**

- `SessionWatchTest` (LV unit) — `Phoenix.LiveViewTest`:
  - mount with a fixture session_id → catch-up frames in rendered
    HTML
  - send `{:event_batch, ...}` to the LV pid → assert
    `push_event` recorded with the right payload
  - `:session_closed` → assert overlay markup present
- `player_hook` JS smoke (manual until JS test infra lands —
  Follow-up reused from ADR-0003).

**DoD**

- [ ] `Live.SessionWatch` LV mounts, catches up, subscribes
- [ ] `data-mode="live"` JS hook ingests pushed events
- [ ] `:session_closed` + `:session_abandoned` render an overlay
- [ ] Router macro + README example
- [ ] CHANGELOG unreleased entry
- [ ] Manual smoke in `ash_feedback_demo`: open
      `/phoenix_replay/sessions/<known_id>/live` while a recording
      is in flight; confirm frames stream live + overlay on submit

**Non-goals (Phase 1)**

- Index of all in-flight sessions (Phase 2)
- Clickable list (Phase 2)
- Auth — host wraps the route in its own pipeline

### Phase 2 — In-flight session index + global broadcasts

**Goal**: an admin can navigate to `/phoenix_replay/sessions` and see
every active session, click one to watch live. New sessions appear
without refresh.

**Changes**

- `lib/phoenix_replay/session.ex` — add to `init/1`:
  ```elixir
  Phoenix.PubSub.broadcast(pubsub, sessions_topic(),
    {:session_started, session_id, identity, started_at})
  ```
  and to `terminate/2` (which fires for both close + abandon):
  fan out `:session_closed` / `:session_abandoned` to the global
  `sessions_topic()` in addition to the per-session topic.
- `lib/phoenix_replay/session.ex` — new public function:
  ```elixir
  def list_active() do
    PhoenixReplay.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {sid, pid} ->
      try do
        GenServer.call(pid, :state_summary, 100)
      catch
        :exit, _ -> nil  # process died mid-call
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
  ```
  Also a new `:state_summary` `handle_call` returning
  `%{session_id, identity, started_at, last_event_at, seq_watermark}`.
- `lib/phoenix_replay/live/sessions_index.ex` (new) —
  `use Phoenix.LiveView`. On mount:
  - `Session.list_active/0` for snapshot
  - `Phoenix.PubSub.subscribe(pubsub, sessions_topic())` for live
    updates
  - assigns hold a sorted-by-started_at list of in-flight sessions
  - LiveView stream for the table (per LiveView usage rules — never
    raw lists for collections)
- Global topic: `"#{prefix}:sessions"` — parameterized by
  `:pubsub_topic_prefix` per ADR-0004 OQ1.
- `Live.SessionsIndex` template — table with session_id (linked to
  `/sessions/:id/live`), identity, started_at, age (relative).
  Empty state: "No sessions in flight".

**Tests**

- `Session` GenServer — `:state_summary` returns the right shape.
- `Session.list_active/0` — snapshot of running sessions; survives
  a process dying mid-iteration (the `try/catch` guard).
- `SessionsIndexTest` — LV unit:
  - mount with two pre-spawned sessions → both in rendered table
  - send `{:session_started, ...}` to LV pid → table grows by one
  - send `{:session_closed, ...}` → row disappears
  - empty-state message when zero sessions

**DoD**

- [ ] Global broadcasts on `Session.init/1` + `terminate/2`
- [ ] `Session.list_active/0` + `:state_summary` `handle_call`
- [ ] `Live.SessionsIndex` LV
- [ ] Router macro mounts both LVs under one scope
- [ ] CHANGELOG entry
- [ ] Smoke: start a recording in browser tab A; admin in tab B
      sees it appear in `/sessions` and click-to-watch streams live

### Phase 3 — Reusable component + power-user composition (optional)

**Goal**: ship `<.session_watch session_id={...} />` and
`<.sessions_index />` as standalone function components so consumers
can compose them into their own admin pages without using the
phoenix_replay-shipped LVs.

**Defer** unless gs_net (or another consumer) actually needs this.
The phoenix_replay-shipped LVs cover 90% of the use case; pulling
the component out adds maintenance surface for a hypothetical user.

## Risks & rollback

| Risk | Mitigation |
|---|---|
| Catch-up `fetch_events/1` is slow for long sessions on mount | Acceptable — bounded by session length. Add a `?since=<seq>` knob if a real consumer hits the wall. |
| `addEvent` per-frame is slow at high frame rates | Profile first. If real, batch via a single `addEvent`-equivalent path. ADR-0004 Q-C open detail. |
| Race between catch-up fetch and PubSub subscribe | Dedup by `seq_watermark` from the fetch result. ADR-0004 Q-D race section. |
| Global `:session_started` broadcast leaks identity to any subscriber | Identity is already in scope of any subscriber to a per-session topic. Watching globally is admin-only by host's auth wrapper. |
| Unbounded number of in-flight sessions in the index | Bound at 200 most-recent by default; scrollable. Document the limit. |
| New router macro adds API surface | Documented + minimal — same shape as `feedback_routes` / `admin_routes`. |

**Rollback per phase**:
- Phase 1: delete `Live.SessionWatch` + the `data-mode="live"` branch
  in the JS hook. Per-session PubSub broadcasts remain (still
  available for any other consumer).
- Phase 2: stop emitting global `:session_started` /
  `:session_closed` / `:session_abandoned` from `Session.init/1` +
  `terminate/2`; delete `Session.list_active/0`. Per-session bus
  unaffected.

## Decisions log

All four ADR-0004 open questions tracked. Defaults assumed in this
proposal:

- [ ] **OQ1** — Topic prefix for the global "sessions" topic.
      Default in this plan: parameterized
      (`"#{prefix}:sessions"`).
- [ ] **OQ2** — `:session_started` payload. Default in this plan:
      `{session_id, identity, started_at}`. Identity is whatever the
      `Identify` hook returned (may be nil).
- [ ] **OQ3** — Default mount paths. Default in this plan:
      `/phoenix_replay/sessions` (index) and
      `/phoenix_replay/sessions/:id/live` (watch).
- [ ] **OQ4** — Reusable component vs. just the LV. Default in
      this plan: ship both — the LV `use Phoenix.LiveView` +
      renders the component.

Promote this proposal to `active/` once the ADR is Accepted and the
above defaults are confirmed (or amended).

## Follow-ups (separate plans)

- **Session abandonment dashboard** — list/filter recently-abandoned
  sessions for triage. Reads Storage, not PubSub. Different surface.
- **JS test infrastructure** (Playwright/Puppeteer) — recurring debt
  flagged across ADR-0001/2/3/4.
- **Session-detail panel inside the watch LV** — show identity,
  started_at, current URL/path of the recording in flight. Once the
  Session GenServer holds the URL trail (it doesn't today), surface
  it.
