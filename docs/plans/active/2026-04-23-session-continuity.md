# Plan: Session Continuity Across Page Loads — Implementation

**Status**: Phase 1 shipped (2026-04-23, `044f250`); Phase 2 pending
**Started**: 2026-04-23
**ADR**: [0003-session-continuity](../../decisions/0003-session-continuity.md)

**Next**: kick off Phase 2 — introduce `PhoenixReplay.SessionRegistry`
+ `PhoenixReplay.Session` GenServer + `PhoenixReplay.SessionSupervisor`
under `application.ex`, switch `EventsController` writes to route
through the `Session` process, add PubSub broadcasts (`event_batch` /
`session_closed` / `session_abandoned`), add the idle-timeout teardown,
and wire config keys `:pubsub` + `:pubsub_topic_prefix`. The Phase 1
DB-fallback resume stays in place — Phase 2 adds a Registry-first
lookup that falls back to the DB path on no-process (covers crash
restarts cleanly).

## Overview

Implement ADR-0003: make recordings survive full page loads. Today
every `<a href>`, form submit, or LV↔dead-view navigation destroys
the client context and orphans the recording. The fix is two layers
that each do something the other can't — client-side
`sessionStorage` + `sendBeacon` to carry the session across unloads
(Layer 1) and a per-session GenServer with PubSub + timeout (Layer 2)
to give the server a crisp continuity story.

**Two phases, orthogonal.** Phase 1 is pure client JS plus a small
server-side resume hook — a complete but thin end-to-end thread.
Phase 2 replaces the server-side lookup with the GenServer layer,
unlocking the live-admin feed + clean abandonment signal.

ADR-0003 is Accepted; all five open questions resolved in its
"Resolved items" section. This plan's Decisions log indexes them.

## Phase 1 — Client persistence + basic server resume

**Goal**: a recording that starts on page A continues on page B as
one session, with one session row and one continuous event stream.
No new runtime deps, no supervisor change in the host.

### Changes

**`priv/static/assets/phoenix_replay.js`**

- Introduce storage helpers wrapping `sessionStorage`:
  ```js
  const STORAGE_KEYS = { TOKEN: "phx_replay_token", RECORDING: "phx_replay_recording" };
  function readStoredToken()  { return sessionStorage.getItem(STORAGE_KEYS.TOKEN); }
  function writeStoredToken(t) { sessionStorage.setItem(STORAGE_KEYS.TOKEN, t); }
  function clearStoredToken() { sessionStorage.removeItem(STORAGE_KEYS.TOKEN); }
  // + matching readStoredRecording / writeStoredRecording / clearStoredRecording
  ```
- `ensureSession()` becomes resume-aware:
  - read `readStoredToken()`; if present, call `/session` with
    `x-phoenix-replay-session: <stored>` header
  - server response shape extended: `{ token, session_id, resumed, seq_watermark }`
  - on `resumed: true`, client adopts the returned `token` + aligns
    `seq` to the returned watermark + 1
  - on `resumed: false` (stale token, server minted fresh), behavior
    diverges per `cfg.recording`:
    - `:continuous` → **silent fresh-start** (OQ1); overwrite stored
      token + continue recording; user sees nothing
    - `:on_demand` → the promise rejects with a typed
      `PhoenixReplaySessionInterruptedError`; the panel orchestrator
      surfaces it as the existing `error` screen (from ADR-0002
      Phase 2) with language like "Your previous recording was
      interrupted. Start over?" and a Retry CTA that mints a fresh
      session
- `startRecording()` persists the recording flag:
  `writeStoredRecording("active")` after a successful session
  handshake. `stopRecording()` + `report()` clear it.
- `autoMount` checks stored recording flag for `:on_demand` widgets:
  if `readStoredRecording() === "active"` AND `cfg.recording === "on_demand"`,
  auto-resume by calling `startRecording()` at mount — no user click
  required. Continuous mode ignores the flag (it always mounts with
  a recorder anyway).
- `pagehide` handler:
  - drain the ring buffer up to `3 × cfg.maxEventsPerBatch` events
    (OQ3 cap); any overflow is dropped with a single `console.warn`
  - post each chunk as `navigator.sendBeacon(${eventsPath}, blob)`
    where `blob` is a `Blob` with the same JSON shape as the
    `/events` POST body
  - server-side CSRF exemption needed for beacon path — see server
    changes below
- `beforeunload` fallback: on UA strings lacking reliable `pagehide`,
  the same flush path fires from `beforeunload`. Both handlers guard
  against double-flush via a `beaconFired` flag on the instance.
- On successful `/session` resume, if the stored token differs from
  the server-returned token (rotation case), overwrite storage.

**`lib/phoenix_replay/controller/session_controller.ex`**

- Read `x-phoenix-replay-session` header if present
- Branch:
  - **header missing** → current behavior (mint fresh, unchanged)
  - **header present + valid token + session resumable**
    (`Storage.Dispatch.resume_session/3` returns `{:ok, session_id,
    seq_watermark}`) → reuse existing `session_id`, mint a new token
    bound to it (so token TTL resets), respond with
    `resumed: true, seq_watermark: N`
  - **header present + stale/invalid** → behave as header-missing;
    respond with `resumed: false`
- "Session resumable" window = configurable
  `session_idle_timeout_ms` (default 15 minutes per OQ2). Tokens
  whose last-event-at is older than this are treated as stale
  regardless of signature validity.

**`lib/phoenix_replay/storage.ex`**

- New callback:
  ```elixir
  @callback resume_session(session_id(), identity(), now :: DateTime.t()) ::
              {:ok, session_id(), seq_watermark :: non_neg_integer()}
              | {:error, :stale}
              | {:error, :not_found}
              | {:error, term()}
  ```
- Identity-binding re-check happens here: a resumed session must
  match the *identity* of the caller (not just the token). Different
  identities → `{:error, :stale}` (same treatment as a stale token).

**`lib/phoenix_replay/storage/ecto.ex`** (and any other shipped
adapters): implement `resume_session/3` as:
- look up session row by `session_id`
- compare `identity_hash` stored on row to caller's identity hash
- find `max(seq)` from events table
- if row exists, identity matches, and most recent event is within
  the idle timeout → `{:ok, session_id, max_seq}`
- else `{:error, :stale}`

**`lib/phoenix_replay/plug/identify.ex`** (if it exists in that
shape) + controller pipeline: the beacon path from the client skips
CSRF (beacons cannot include headers in a way that survives
browser-side unload reliably). Gate via a dedicated
`:api_with_beacon` router pipeline — or extend the existing one to
check `content-type: application/json` + no cookies required for the
beacon path. Narrow scope: beacon only for `/events`; `/session` and
`/submit` continue to require CSRF.

  Alternative if the above proves fragile: have the client attach
  the session token header (which `sendBeacon` does support via
  `Blob` + fetch-style config) and rely on the existing
  token-validation middleware. Choose at implementation time based
  on what `navigator.sendBeacon` actually lets us set.

**Client-side recording attr check**: when
`cfg.recording === "on_demand"` and `readStoredRecording() === "active"`,
the on-demand auto-resume must not trip the existing
"on-demand waits for an explicit `startRecording()` call" path.
Guard the auto-resume branch explicitly in `autoMount`.

### Tests

- **Storage adapter** — `resume_session/3` contract tests:
  recent-session + matching identity → `{:ok, session_id, N}`;
  older than idle timeout → `{:error, :stale}`; mismatched identity
  → `{:error, :stale}`; nonexistent → `{:error, :not_found}`.
- **`SessionController`** — unit:
  - no header → mints fresh, `resumed: false`, `seq_watermark: 0`
  - valid header + resumable session → `resumed: true, seq_watermark: N`
  - valid header + stale session → `resumed: false`, new token
  - valid header + identity mismatch → `resumed: false`, new token
  - malformed header → same as missing
- **JS manual smoke (dummy host)** — matrix:
  - `:continuous` + hard navigation: check `sessionStorage` has
    token after page A, new page B's `/session` returns
    `resumed: true`, events continue streaming to same session_id
  - `:on_demand` + hard navigation while recording: pill visible on
    page A → navigate → pill visible immediately on page B (auto-resume)
  - `:on_demand` + stale token (manually age the stored token past
    timeout) → panel opens with error screen on next interaction,
    Retry mints fresh
  - `:continuous` + stale token → silent fresh-start, no UI change
    visible
  - `pagehide` beacon delivery — tail events on page A show up in
    the DB after closing the tab (DevTools Network panel with
    "Disable cache" off, filter for `/events` beacon)
  - Beacon 3-batch cap: manually stuff the ring buffer with >150
    events, trigger `pagehide`, confirm 3 beacons sent + console
    warn about tail drop

### DoD (Phase 1) — shipped 2026-04-23 in `044f250`

- [x] `sessionStorage` token + recording-flag round-trip across page
      reloads
- [x] `fetch keepalive` flush on `pagehide` + `beforeunload` delivers
      tail events (chose `fetch(..., {keepalive: true})` over
      `sendBeacon` — preserves the existing
      `x-phoenix-replay-session` header-based auth; body cap in
      practice is larger than sendBeacon's 64KB so OQ3's 3-batch cap
      still fits comfortably)
- [x] `/session` accepts resume header + returns `{resumed, seq_watermark}`
- [x] Storage adapter `resume_session/2` callback implemented for
      shipped adapters (Ecto + AshFeedback both delegate to shared
      `Storage.Events.resume/4`)
- [x] OQ1 stale-token policy: continuous silent, on-demand error screen
      (reuses ADR-0002 Phase 2 error screen)
- [x] CSRF strategy moot with `fetch keepalive` — existing
      `x-csrf-token` header flows unchanged. No carve-out needed.
- [ ] README `Recording modes` section updated with "multi-page
      continuity" note — deferred; current behavior is "just works"
      for continuous, and the on-demand error screen already
      explains itself in-context. Revisit if a consumer asks.
- [x] CHANGELOG unreleased entry
- [x] All matrix cells pass manual smoke (continuous hard-nav,
      on-demand auto-resume, on-demand stale → error screen, pagehide
      tail delivery)
- [ ] Storage + controller unit tests — blocked on the "Ecto sandbox
      + JS test infra" follow-up (ADR-0001/0002 already flagged it;
      ADR-0003 inherits). Manual smoke + `project_eval` verification
      covers the thread until then.

### Non-goals (Phase 1)

- GenServer / Registry / PubSub — all in Phase 2
- Live admin feed — enabled by Phase 2, UI separate plan
- Cross-tab coordination — ADR-0003 out-of-scope
- Clustered / multi-node — ADR-0003 out-of-scope

## Phase 2 — Server-side GenServer layer

**Goal**: replace the DB-lookup resume path with a supervised
per-session process. Unlocks live admin feed via PubSub, crisp
abandonment signaling, in-flight dedup before the write.

### Changes

**`lib/phoenix_replay/session.ex`** (new):
```elixir
defmodule PhoenixReplay.Session do
  use GenServer
  # state: %{session_id, token, seq_watermark, started_at,
  #          last_event_at, identity, idle_timeout_ms,
  #          recent_seqs :: :queue.queue, pubsub, topic}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:session_id]))
  def via(id), do: {:via, Registry, {PhoenixReplay.SessionRegistry, id}}

  # public API:
  def append_events(session_id, seq, events) ...
  def seq_watermark(session_id) ...
  def close(session_id, reason \\ :normal) ...

  # internals:
  # - on :append, drop seqs already seen, persist via Storage,
  #   broadcast :event_batch, bump last_event_at, reset idle timer
  # - on :idle_timeout, broadcast :session_abandoned, stop
end
```

**`lib/phoenix_replay/session_supervisor.ex`** (new):
```elixir
defmodule PhoenixReplay.SessionSupervisor do
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def start_session(session_id, identity, opts), do: DynamicSupervisor.start_child(__MODULE__, {Session, [session_id: session_id, identity: identity] ++ opts})

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```

**`lib/phoenix_replay/application.ex`**: supervisor spec for
`PhoenixReplay.SessionRegistry` (`Registry, keys: :unique`) +
`PhoenixReplay.SessionSupervisor`. The library's `Application.start/2`
already runs — this just extends `children`.

**`lib/phoenix_replay/config.ex`**: new config keys:
- `:pubsub` — atom, host's `Phoenix.PubSub` name (OQ4). When unset,
  library starts its own `Phoenix.PubSub.PhoenixReplay.PubSub` under
  its supervisor.
- `:pubsub_topic_prefix` — default `"phoenix_replay"` (OQ4).
- `:session_idle_timeout_ms` — default `900_000` (OQ2).

**`lib/phoenix_replay/controller/session_controller.ex`**: resume
branch switches to Registry-first lookup:
- `Registry.lookup(PhoenixReplay.SessionRegistry, session_id)`:
  - alive process → call `Session.seq_watermark/1`, return
    `resumed: true, seq_watermark: N`
  - no alive process → fall through to the Phase 1 DB path
    (recently-terminated sessions still in the DB get resumed there;
    this is intentional — process restart after a crash shouldn't
    break continuity)
  - stale → mint fresh, start a new `Session` via
    `SessionSupervisor.start_session/3`

**`lib/phoenix_replay/controller/events_controller.ex`**: writes go
through `Session.append_events/3` instead of directly calling
`Storage.Dispatch.append_events/3`. The GenServer handles:
- dedup via `recent_seqs` bounded queue (size = 50, covers the worst
  realistic retry fan-out)
- broadcast `{:event_batch, session_id, events, seq}` to
  `"#{prefix}:session:#{session_id}"` after persistence succeeds
- reset idle timer

**`lib/phoenix_replay/controller/submit_controller.ex`**: after
persisting the feedback row, calls `Session.close(session_id, :submitted)`
which terminates the process + broadcasts `{:session_closed, ..., :submitted}`.

**PubSub topic shape**: `"{prefix}:session:{session_id}"`, messages:
- `{:event_batch, session_id, events, seq}`
- `{:session_closed, session_id, :submitted}`
- `{:session_abandoned, session_id, last_event_at}`

**README**: new "Install (manual)" block (OQ5) showing the
`application.ex` children addition — load-bearing until the Igniter
installer (Phase 5f) lands.

**`docs/guides/multi-page-reproductions.md`** (new): the continuity
guide. When does it help, what survives, what the user sees during
navigation, stale-token behavior, privacy note on `sessionStorage`.

### Tests

- **`Session` GenServer** unit:
  - append_events dedups on `{session_id, seq}` repeat
  - broadcasts `:event_batch` to correct topic
  - idle_timeout terminates + broadcasts `:session_abandoned`
  - `close/2` broadcasts `:session_closed`
  - seq_watermark returns max seen seq (for resume)
- **`SessionSupervisor`** unit:
  - start_session spawns registered child
  - dup session_id returns `{:error, :already_registered}` (or
    reuses the alive pid, pick at implementation)
- **`SessionController` resume** integration:
  - alive registry entry → resumed response with current watermark
  - no alive entry + recent DB session → falls back to DB resume
    (Phase 1 path still works)
  - no alive entry + stale DB → fresh session, new `Session`
    spawned
- **`EventsController`** integration: verify writes route through
  `Session`, dedup works, PubSub subscriber receives `event_batch`
- **PubSub subscriber smoke** — test LiveView subscribes, asserts
  on message shape across `event_batch` / `session_closed` /
  `session_abandoned`

### DoD (Phase 2)

- [ ] `PhoenixReplay.Session` + `SessionSupervisor` + `SessionRegistry`
      under the library supervisor
- [ ] `EventsController` + `SubmitController` route through `Session`
- [ ] PubSub broadcasts on `event_batch`, `session_closed`, `session_abandoned`
- [ ] Idle timeout fires → process terminates → abandonment broadcast
- [ ] Config keys documented (`:pubsub`, `:pubsub_topic_prefix`,
      `:session_idle_timeout_ms`)
- [ ] README "Install (manual)" section for supervisor wiring (OQ5)
- [ ] CHANGELOG unreleased entry extended
- [ ] New guide `docs/guides/multi-page-reproductions.md`
- [ ] Continuity still works during a process crash (supervisor
      restart → next `/events` POST finds no process, controller
      falls back to DB resume, events still land)

### Non-goals (Phase 2)

- Admin "watch live" UI — separate plan, after this ships
- Clustered session registry (`:global` / `Horde`) — out of scope
  (ADR-0003)
- Cross-tab session sharing via `BroadcastChannel` — out of scope
- Service-Worker coordination — out of scope
- Auth-bound cross-device resume — out of scope

## Decisions log

All five ADR-0003 open questions resolved; the ADR is Accepted. Full
resolutions live in the ADR's "Resolved items" section — this log
indexes them for quick reference during implementation.

- [x] **OQ1** — Stale-token resume policy: `:continuous` silent
      fresh-start; `:on_demand` visible error screen with Retry.
      Reuses the ADR-0002 Phase 2 error screen infrastructure.
- [x] **OQ2** — Idle timeout 15 minutes default, configurable via
      `:session_idle_timeout_ms`.
- [x] **OQ3** — `sendBeacon` cap at 3 batches × `maxEventsPerBatch`.
      Overflow dropped + single `console.warn`.
- [x] **OQ4** — PubSub: share host's existing `Phoenix.PubSub`
      instance (configurable via `:pubsub`), topic prefix
      `"phoenix_replay"` configurable via `:pubsub_topic_prefix`.
- [x] **OQ5** — README "Install (manual)" block documents the
      supervisor-wiring step until Phase 5f's igniter task ships.

## Risks & rollback

| Risk | Mitigation |
|---|---|
| `navigator.sendBeacon` blocked by CSP (`connect-src`) on hosts with strict CSP. | Document in guide. Hosts can add the ingest origin to `connect-src`. If beacon fails, no visible error (by API design); the tail is lost as today. |
| Beacon path needs CSRF carve-out. | Narrow to `/events` only. `/session` + `/submit` keep CSRF. Document the scope reduction. |
| `sessionStorage` quota exceeded (rare but possible if host also uses it heavily). | Graceful fail: catch `QuotaExceededError`, log once, keep in-memory only. Session continuity silently reverts to today's per-page behavior. |
| Identity mismatch on resume (user logged out then back in as someone else between page A and B) | `resume_session/3` re-checks identity hash; mismatch → fresh session. Correct behavior. |
| `Session` GenServer crashes mid-session | Supervisor restarts fresh (no state). Next `/events` request hits the controller's DB-fallback resume path and re-spawns a new `Session`. Acceptable — events persist, continuity preserved, some in-memory dedup state lost (unique DB constraint would catch the rare dup). |
| Host doesn't use `Phoenix.PubSub` at all | Library starts its own when `:pubsub` unset (OQ4). Small process overhead, no functional blocker. |
| Pathological consumer: thousands of concurrent sessions exhaust process table | Out of scope for 1.0. Document as a known limit; note `:max_children` on the DynamicSupervisor as the tuning dial. |
| Phase 2 adds supervisor wiring — consumers on older library versions must add it by hand | README "Install (manual)" block (OQ5) + CHANGELOG breaking-change note. Phase 5f's igniter makes this automatic for new installs. |
| `Registry` + `DynamicSupervisor` names collide with host's existing names | All library processes live under `PhoenixReplay.*` namespace. Document in the install block. |

**Rollback**: each phase revertable independently.
- Phase 1 revert: client reads no stored token (mints fresh per page
  as today); server resume header is ignored (unknown header is
  harmless); storage adapters keep `resume_session/3` but nothing
  calls it.
- Phase 2 revert: `EventsController` goes back to calling
  `Storage.Dispatch.append_events/3` directly; supervisor + registry
  keep running (idle); configs keep working. Host can remove the
  supervisor from `application.ex` after the revert.

## Follow-ups (separate plans/ADRs)

- **Plan**: admin "watch live" LiveView — subscribes to session
  PubSub topic, renders rrweb-player that streams in frames as they
  land. Requires Phase 2.
- **Plan**: session timeline / abandonment dashboard in the admin UI
  — consume `session_abandoned` / `session_closed` broadcasts,
  render a feed.
- **ADR candidate**: clustered session registry (Horde / libcluster)
  for multi-node deployments. Revisit when a consumer's topology
  forces the question.
- **ADR candidate**: cross-tab session sharing via
  `BroadcastChannel` — revisit only when a concrete consumer story
  emerges. ADR-0003 explicitly declines it.
- **Plan**: JS test infrastructure — rising relevance as the client
  surface grows (flagged in ADR-0001 Phase 2 and ADR-0002 Phase 2
  follow-ups). Session-continuity edge cases (stale token, beacon
  flush, cross-page resume) are hard to test manually and would
  benefit from Playwright/Puppeteer coverage.
- **ADR candidate for `ash_feedback`**: `session_continuity_mode`
  attribute on Feedback — "was this reported from a multi-page
  session?" — useful for triage dashboards filtering on workflow
  complexity.
