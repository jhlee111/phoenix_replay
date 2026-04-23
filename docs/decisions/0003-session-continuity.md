# ADR-0003: Session Continuity Across Page Loads

**Status:** Accepted
**Date:** 2026-04-23
**Accepted:** 2026-04-23 (five open questions resolved — see *Resolved items* below)

## Context

A realistic QA reproduction is rarely one page. The user lands on a
dashboard, clicks through to a detail page (maybe dead view, maybe
LiveView), submits a form, gets redirected, sees the bug. Today
`phoenix_replay` captures only whatever happens **on the page the
widget was mounted on**. Every full page load — `<a href>` links, form
submits, LiveView↔dead-view transitions, hard-refreshes — destroys
the client JS context: `window.PhoenixReplay` is a new object, the
ring buffer is a new array, and the session token is either missing
(`:on_demand`) or newly minted (`:continuous`). The event stream the
QA member thought they were recording is actually N disconnected
recordings, one per page.

Concretely, what survives and what doesn't:

| Navigation | Client JS context | Widget mount div | Recording state |
|---|---|---|---|
| `<.link patch>` (same LV) | preserved | preserved | **survives** |
| `<.link navigate>` (LV→LV, widget in root layout) | preserved | preserved | **survives** |
| `<.link navigate>` (widget inside `inner_content`) | preserved | destroyed | **broken** |
| `<a href>` / form submit | destroyed | re-mounts from fresh HTML | **broken** |
| LV ↔ dead view | destroyed | re-mounts | **broken** |
| Hard refresh | destroyed | re-mounts | **broken** |

Three of the six rows break every reproduction. The first two
(patches + root-layout navigate) are the happy path we have today;
everything else is the missing 80%.

On-demand mode (ADR-0002) sharpens the problem: the user explicitly
clicks **Start reproduction**, and then loses their recording the
moment they click a link. "Your click-through session across these
three pages" is the whole product promise — if it doesn't survive the
clicks, the mode isn't useful.

## Decision

Two layers, both required. Each does a thing the other can't.

### Layer 1 — Client-side session persistence

The browser must carry the session identity across the page unload.
All of this is in `phoenix_replay.js`, no server changes:

- **Session token in `sessionStorage`**. The current in-closure token
  becomes a read-through cache for `sessionStorage.phx_replay_token`.
  On new-page `init`, if a stored token exists, the client attempts
  to resume it instead of minting a new one. `sessionStorage` is
  tab-local (matches ADR-0002 OQ4: on-demand is tab-local) and
  survives reloads + same-tab navigations; does not bleed across tabs
  or survive tab close.

- **`navigator.sendBeacon` flush on `pagehide`**. The only reliable
  way to post events during page teardown. Hook into `pagehide` (and
  `beforeunload` on browsers where `pagehide` doesn't fire reliably),
  drain the ring buffer, post the final batch as a beacon. Beacons
  are fire-and-forget but the browser commits to delivering them
  after the page is gone — `fetch` from an unloading page is frequently
  cancelled.

- **`isRecording` flag in `sessionStorage`**. For on-demand: when
  `startRecording()` runs, set `phx_replay_recording=active`. On new
  page `init`, if the flag says `active` and mode is `:on_demand`,
  the library resumes automatically (reattaches rrweb, keeps using
  the stored token). If the flag is absent or the mode is continuous,
  standard behavior. `stopRecording()` and `report()` clear the flag.

### Layer 2 — Server-side per-session GenServer

A supervised process per active session. This is where continuity
earns its quality:

```
PhoenixReplay.SessionSupervisor (DynamicSupervisor)
  └─ PhoenixReplay.Session (GenServer, one per session_id)
       state: %{
         session_id, token, seq_watermark, started_at,
         last_event_at, identity, metadata,
         subscriber_refs   # for live admin view
       }
```

- **Resume semantics**. Client sends `/session` with an
  `Idempotency-Key` header carrying the stored token. The controller
  asks `Registry.lookup/2` for an alive `Session` process. If found,
  it's a resume: the process replies with the current `seq_watermark`
  so the client can pick up cleanly (and reject any client-side
  duplicate retry that somehow slipped through). If not found, the
  token is stale (expired / crashed / restarted node) — fresh session
  minted, client discards the stale `sessionStorage` entry.

- **Live admin view**. `Session` broadcasts via `Phoenix.PubSub` on
  `"phoenix_replay:session:#{id}"`. Admin LiveViews that subscribe see
  events stream in as they arrive — "watch this QA's reproduction
  live." Also enables a future "session_started" /
  "session_abandoned" feed for triage dashboards.

- **Cleaner abandonment**. `Session` sets a last-event timestamp on
  each `/events` POST. A per-process timer (or an hourly sweep) marks
  the session `abandoned` after N minutes of silence and terminates,
  firing a final PubSub event. Much cleaner than DB-row scans.

- **In-flight dedup**. Holds a bounded set of recent `seq` values in
  memory. Client retries after a flaky network don't create duplicate
  event rows. The existing DB path could also enforce this via unique
  constraint, but the GenServer catches it before the write and keeps
  the error handling local.

### Why both layers

Neither solves the problem alone.

**Client-only**: works for the *simple* case. Events still reach the
server on subsequent page loads via the resumed token. But without a
server process the "resume" is just a DB lookup per request — fine
functionally, weak for live view and abandonment detection, and
race-prone for in-flight dedup.

**Server-only (GenServer without client persistence)**: **does not
solve the problem.** The client's new JS context has no way to know
which session to rejoin unless the client itself remembers. Events
captured in the ring buffer before the navigation are also gone
regardless of server architecture — they never left the client. Any
GenServer proposal that skips the client persistence layer is solving
the wrong half.

The two-layer split also matches library scope: Layer 1 is a
`phoenix_replay.js` concern, pure client JS. Layer 2 is a
`phoenix_replay` Elixir concern, supervised under the host's
supervision tree. No Ash-layer changes.

## Why this shape

### Why `sessionStorage` and not `localStorage` / cookies

- `localStorage` survives tab close and bleeds across tabs — violates
  ADR-0002 OQ4's tab-local on-demand scope. A user who recorded in
  Tab A, closed it, then opened Tab B two hours later should not see
  a stale pill.
- Cookies are larger and get sent with every HTTP request, including
  completely unrelated ones. The token belongs in a client-only slot.
- `sessionStorage` is exactly the right scope: same tab, across
  reloads and navigations, gone when the tab closes.

### Why `sendBeacon` and not "just keep using `fetch`"

`fetch` during page unload is best-effort at best; browsers
aggressively cancel in-flight requests. `sendBeacon` is the only API
with a browser commitment to deliver after the tab is gone. The cost
is no response body — but flushing the buffer is fire-and-forget
anyway; the response wasn't being used.

### Why per-session GenServer rather than a single session registry

Per-session isolation means a runaway client (flooding `/events`)
only blocks its own process. The supervisor + Registry pattern is
standard Phoenix; the per-session state is tiny (KB); and the process
count grows linearly with active sessions, which is already capped by
how many simultaneous QA reproductions the app realistically sees.
ETS-backed single registry would save memory but complicate the
resume + PubSub + timeout story.

### Why not Cachex / Nebulex / distributed cache

Single-node today. The host's Phoenix app runs on a single BEAM node
for the scenarios this library targets. If a consumer later deploys
clustered, `Session` processes can be registered via
`:global` or `Horde` — but that's a separate ADR and not required for
the 1.0 story.

### Why not rely solely on DB TTL for cleanup

Works, but expensive at scale (scanning session rows to find dead
ones) and has no live signal — admin UIs can't subscribe to "this
session just went abandoned." GenServer termination is the signal.

## Alternatives rejected

- **Server-only** (GenServer, no client sessionStorage). Solves the
  wrong half: the client has no way to rejoin. Described above.
- **Client-only** (sessionStorage + sendBeacon, no GenServer). Works
  but thin — no resume race protection, no live admin feed, no
  graceful abandonment signal.
- **`BroadcastChannel` cross-tab session sharing.** ADR-0002 OQ4
  rejected this: on-demand is tab-local. A cross-tab extension is a
  future-ADR concern.
- **Single-page-app style — tell consumers not to do full reloads.**
  Unrealistic. Real apps mix LV + dead views + form-post redirects.
  The library must work with the framework, not against it.
- **Persist the full ring buffer to `sessionStorage` on every event.**
  Too expensive (thousands of events/sec × JSON serialize × storage
  quota). `sendBeacon` on `pagehide` is the bounded-cost version of
  the same idea.
- **Service Worker as a coordination point.** Solves cross-tab but
  hugely complicates the integration story (SW registration, scope,
  HTTPS) and requires the host to grant a SW slot. Not proportional.

## Consequences

### Positive

- Multi-page reproductions become one session row with one event
  stream, not N orphans. QA's actual workflow is captured.
- `:on_demand` mode becomes useful across navigations — the whole
  reason to add it (privacy-conscious enterprises need explicit
  consent, but their reproductions span pages).
- Admin UI can offer "watch live" via PubSub subscription — new
  product capability, falls out of the GenServer.
- Abandonment handling gets crisp — not a DB sweep, a process
  terminate + broadcast.
- Client-side ring buffer loss on unload stops being a silent data
  gap; `sendBeacon` closes it.

### Negative

- Real surface area increase: two concurrent pieces of state
  (sessionStorage + GenServer) that must agree on "this session is
  alive." Divergence (client thinks alive, server expired) handled
  via the 401/410 retry path, but adds a code path that must stay
  correct.
- GenServer supervision in the host's app. `phoenix_replay.install`
  (5f) must add a supervisor to the host's supervision tree; not
  previously required.
- Process count = active session count. Pathological consumer load
  (thousands of simultaneous QA reproductions) would need tuning;
  small shops won't notice.
- `sendBeacon` delivery is best-effort — not 100%. Some tails will
  still be lost on browser crash or abrupt network drop. Acceptable;
  current behavior is "100% of tails lost on every navigation."
- `sessionStorage` persistence means the library now touches browser
  storage. Privacy-review should note it (no PII — just a signed
  token string + a recording-active flag).

### Neutral

- No schema change. Existing `session_id` / `seq` already support
  multi-page streams; the DB just sees more rows per session_id.
- No wrapper (`ash_feedback`) changes. Feedback resource is
  downstream of session.
- Backward-compatible. Consumers who don't upgrade the JS keep
  getting per-page sessions; upgrading doesn't force any host changes
  beyond adding the supervisor.

## Scope

**In scope (this ADR):**

- `sessionStorage` token + `isRecording` flag in `phoenix_replay.js`.
- `navigator.sendBeacon` flush on `pagehide` / `beforeunload`.
- `PhoenixReplay.SessionSupervisor` + `PhoenixReplay.Session`
  GenServer, registered by `session_id`.
- `/session` controller handling of resume (existing token header) vs.
  fresh mint.
- PubSub broadcasts on session events (`event_batch`,
  `session_closed`, `session_abandoned`).
- Host wiring via `phoenix_replay.install` task (5f) — add the
  supervisor to the app's supervision tree.
- Docs: multi-page flow diagram, privacy note on `sessionStorage` use.

**Out of scope (future candidates):**

- Clustered / multi-node session registry (Horde, libcluster
  integration) — single-node is sufficient for 1.0.
- Cross-tab session sharing via `BroadcastChannel` — ADR-0002 OQ4
  declined; revisit only with a concrete consumer story.
- Service-Worker-based coordination.
- Admin "watch live" UI — this ADR enables it but the UI itself lives
  in a Phase 3+ plan.
- Replay-time fragment boundary rendering — rrweb-player handles
  multi-snapshot sessions natively; no library work needed.
- Arbitrary session resume across devices (user starts on laptop,
  continues on phone) — requires an auth-bound identity layer that
  lives in `ash_feedback`'s territory.

## Resolved items (decided on acceptance, 2026-04-23)

- **OQ1 — Stale token resume policy.** **Hybrid.** `:continuous`
  does a **silent fresh-start** — the server mints a new session,
  returns a new token, the client overwrites the stale
  `sessionStorage` entry and keeps recording. `:on_demand` instead
  surfaces a **visible error state** — "Your previous recording was
  interrupted. Start over?" — via the same panel error styling
  introduced for Phase 2's `/session` failure handler (ADR-0002
  OQ1). The user must acknowledge before a new session is minted.
  Rationale: continuous is implicit; silently recovering matches
  user expectation. On-demand's contract is explicit consent per
  reproduction; silently losing the chain would break trust.

- **OQ2 — GenServer idle timeout.** **15 minutes** default,
  configurable via `config :phoenix_replay,
  session_idle_timeout_ms: 900_000`. Rationale: QA reproductions
  include thinking time — reading docs, asking a colleague, pausing
  to examine state — so 5 minutes is too aggressive. 30 minutes
  leaves crashed-tab processes lingering. 15 is the practical sweet
  spot. Hosts with long manual reproduction workflows can override.

- **OQ3 — `sendBeacon` payload size.** **Chunk, capped at 3
  batches.** The final unload flush drains the ring buffer into
  `maxEventsPerBatch`-sized chunks and sends up to three
  `sendBeacon` calls. Any remaining tail is dropped and documented
  as a known edge case. Rationale: with the default batch size
  (50 events ≈ 15KB per beacon) this covers ~150 events ≈ well
  within all browsers' 64KB cap per beacon. The cap prevents a
  runaway buffer from locking up the unload path. Tail loss at this
  extreme is far less painful than the status quo (100% tail loss
  on every navigation).

- **OQ4 — PubSub topic namespacing + instance.**
  - Prefix: `config :phoenix_replay, pubsub_topic_prefix:
    "phoenix_replay"` (default). Topic name:
    `"#{prefix}:session:#{session_id}"`.
  - Instance: `config :phoenix_replay, pubsub: MyApp.PubSub` — hosts
    pass the name of their existing `Phoenix.PubSub` (no new process
    started). If unset, the library's supervisor starts its own
    `Phoenix.PubSub.PhoenixReplay.PubSub`. Most consumer apps
    already have a `PubSub` — sharing it avoids an unnecessary
    process.
  Rationale: hosts with heavy PubSub usage shouldn't find their
  namespace polluted or a duplicate process eating a BEAM slot.

- **OQ5 — Pre-install-task guidance.** README gets an **"Install
  (manual)"** block for the period before `mix
  phoenix_replay.install` (Phase 5f) lands. Explicitly:
  ```elixir
  # lib/my_app/application.ex
  children = [
    # ...existing children...
    {Phoenix.PubSub, name: MyApp.PubSub},   # skip if already present
    PhoenixReplay.SessionSupervisor
  ]
  ```
  Rationale: library status is PoC; manual wiring is acceptable and
  has precedent (`mix deps.get` -> edit `application.ex` is a known
  Phoenix pattern). When 5f's igniter task ships, it injects exactly
  these children — the README example stays the source of truth for
  what consumers running old versions must do by hand.

## References

- ADR-0001 — trigger UX (float/headless).
- ADR-0002 — on-demand recording mode. OQ4 (tab-local) informs the
  `sessionStorage` choice here.
- [MDN — Page Lifecycle API](https://developer.mozilla.org/en-US/docs/Web/API/Page_Lifecycle_API)
  — `pagehide` / `beforeunload` semantics.
- [MDN — `Navigator.sendBeacon()`](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/sendBeacon).
- [rrweb multi-fragment sessions](https://github.com/rrweb-io/rrweb/blob/master/guide.md)
  — rrweb-player handles successive full-snapshots natively.
- Phoenix / Elixir: `DynamicSupervisor`, `Registry`, `Phoenix.PubSub`
  — standard primitives, no new deps.
