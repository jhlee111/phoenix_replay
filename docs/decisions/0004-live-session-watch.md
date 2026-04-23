# ADR-0004: Live Session Watch — Admin "Shoulder-Surf"

**Status**: Proposed
**Date**: 2026-04-23
**Builds on**: ADR-0003 (Session Continuity)

## Context

ADR-0003 Phase 2 introduced `PhoenixReplay.Session` — a per-session
GenServer that broadcasts every accepted event batch on
`"phoenix_replay:session:#{session_id}"` via `Phoenix.PubSub`. The
broadcast is wired but nothing consumes it yet. The natural consumer
is an admin "watch live" surface: a LiveView that subscribes to the
topic and streams rrweb frames into `rrweb-player` as they land,
letting an oncall admin see a user's reproduction unfold in real time
— the SaaS-replay "live cobrowse" experience, self-hosted.

Three architectural choices are load-bearing and worth pinning down
before we write code.

## Question A — In-flight session discoverability

The watch-live LV needs to know **which** `session_id` to watch. The
existing Feedback resource only tracks **post-submit** sessions; an
in-flight session lives only as a `PhoenixReplay.Session` GenServer
under `PhoenixReplay.SessionRegistry`. Options:

1. **Registry scan** (`Registry.select/2`) — cheap, no extra state,
   but only gives a snapshot. Newly-started sessions don't appear
   until the LV polls or refreshes.
2. **Global PubSub topic** (e.g. `"phoenix_replay:sessions"`) — Session
   GenServer broadcasts `:session_started` on init and a corresponding
   close/abandon. The admin index LV subscribes once and stays current
   without polling. Adds two new broadcast types.
3. **Dedicated ETS table** owned by `SessionSupervisor` — maintains a
   live "active sessions" map the LV reads on every render. Heavier,
   duplicates state already in Registry.
4. **Ash resource for in-flight sessions** — most integrated, requires
   a custom data layer (Registry-backed, no DB). Heavyweight for a
   list of strings + timestamps.

**Decision (proposed)**: combine (1) + (2). Initial population via
Registry scan exposed as `Session.list_active/0`; live updates via a
new `"phoenix_replay:sessions"` global topic (broadcasts:
`:session_started`, `:session_closed`, `:session_abandoned`). This
mirrors how oncall dashboards already work — snapshot + delta — and
needs only ~10 lines added to `Session.init/1` + `terminate/2`.

**Why not (3)**: ETS duplicates Registry's job. Registry is already
the source of truth for "is this session alive"; an ETS shadow risks
divergence (one updated, the other missed) and offers nothing in
return.

**Why not (4)**: Ash resources for non-persisted process state
overweight the surface. We're not gaining triage / policies /
PaperTrail by modeling a Registry entry as a resource.

## Question B — Where does the watch-live LV live?

`phoenix_replay` is currently Ash-free; it ships JSON endpoints + the
rrweb-player LV hook + reusable `UI.Components`. `ash_feedback` is the
Ash wrapper but ships **zero LiveViews** today (the demo shows
host-side scaffold using `phoenix_replay`'s components).

Options:

1. **Watch-live LV in phoenix_replay**, alongside `UI.Components`.
   No Ash dependency on the consumer. ash_feedback can wrap or extend
   if a Feedback-aware variant ever materializes.
2. **Watch-live LV in ash_feedback**, treating it as the natural home
   for the broader admin UI. Adds Ash as a dependency for anyone who
   wants to watch-live, even if they'd otherwise use the
   plain-Ecto storage adapter.
3. **Reusable `UI.Components` only** (no full LV) in phoenix_replay —
   leave LV assembly to consumers. Maximum flexibility, biggest
   onboarding cost.

**Decision (proposed)**: option (1). The watch-live LV consumes
phoenix_replay's PubSub broadcasts and renders phoenix_replay's
rrweb-player hook — there's no Ash surface in the data flow. Keeping
it Ash-free preserves the "core library is standalone" property
that's already a load-bearing rule
(`docs/decisions/README.md` last paragraph). ash_feedback users get
it for free as a transitive dep; non-Ash users still get it.

**Why not (2)**: would force an Ash dep on Ecto-storage users for a
feature with no Ash semantics.

**Why not (3)**: the JS hook + PubSub subscription + push_event
plumbing is non-trivial; consumers shouldn't have to copy-paste it.
phoenix_replay can ship a LV *and* expose the components for power
users who want to compose their own.

## Question C — rrweb-player live mode

The current `player_hook.js`
(`priv/static/assets/player_hook.js`) is one-shot: it fetches an
`events_url` once and renders a finite session. Live mode needs the
player to keep accepting frames as they arrive. Options:

1. **Extend the existing hook** with a `data-mode="live"` variant that
   initializes with `events: []`, then subscribes to
   `this.handleEvent("phoenix_replay:append", ...)` and calls
   `player.addEvent(ev)` per incoming event. Single hook file, one
   conditional path.
2. **New hook entirely** (e.g. `phoenix_replay_live_player`),
   selected via a different `data-` attr. Cleaner separation, more
   surface to keep in sync.
3. **Hybrid**: separate JS module imported by the same hook entry,
   chosen at runtime by the `data-mode`.

**Decision (proposed)**: option (1). The two modes share ~80% of
their logic (rrweb-player setup, dimensions, controller chrome); the
divergence is the data source (`fetch` vs. `pushEvent` subscription).
A `data-mode="live"` branch is small and keeps the consumer-facing
surface to one HTML hook attribute.

**Open implementation detail**: rrweb-player's `addEvent(ev)` API
exists but consumes one event at a time; an `:event_batch` arrives as
a list. The hook will iterate. If profiling later shows per-event
overhead is real, we can add a batched ingestion path.

## Question D — Catch-up on mount

When the admin opens the watch-live LV mid-session, the recording is
already 30 seconds in. Options:

1. **Live-only**: subscribe and start playback from "now" — no
   history. Simplest; admin sees only what arrives after they joined.
2. **Catch-up + live**: on mount, fetch the historical buffer via
   `Storage.fetch_events/1`, seed the player, *then* subscribe.
   Admin sees the whole reproduction from the start, with live
   frames appended as they arrive. Matches user expectation.

**Decision (proposed)**: option (2). Without catch-up, the LV's value
drops sharply — most reproductions are short (seconds to a couple of
minutes), and a 10-second-late join could miss the entire flow.
Implementation is one extra `fetch/1` call on mount before
`PubSub.subscribe`.

**Race**: an `:event_batch` could arrive between `fetch_events/1`
returning and `subscribe/2` taking effect. The Session GenServer
publishes the seq with each batch; the LV deduplicates incoming
events by seq against the watermark from the initial fetch.

## Out of scope

- **Session abandonment dashboard** (separate plan / ADR). Listing
  recently-abandoned sessions for triage is a different surface — it
  reads from the Storage adapter, not PubSub.
- **Multi-tenant scoping** (who-can-watch-whom). Identity-binding
  belongs in the host's auth pipeline; phoenix_replay's existing
  pattern is "admin scope is yours to wrap" and we're not changing
  that.
- **Recording-mode UX in the watched user's view**. ADR-0002 already
  decided what the user sees (panel pill, etc.). The admin watching
  doesn't change anything client-side for the user.
- **Cross-node clustering**. ADR-0003 already declined `:global` /
  Horde for the Session registry; the same restriction applies here.
  Watch-live works on a single node; multi-node deployments must use
  sticky sessions.

## Consequences

### Positive

- Unlocks the headline "live cobrowse" UX promised by Phase 2's
  PubSub plumbing.
- Stays within the architecture already established in ADR-0003 — no
  new processes, no new datastore, just two new global broadcast
  types and a LiveView consuming what's already broadcast.
- Pure phoenix_replay surface — works whether or not the host
  installs ash_feedback.

### Negative / risks

- Two new broadcast types on `Session.init/1` + `terminate/2` change
  the Session module's public PubSub contract. Consumers who already
  subscribed to `"phoenix_replay:sessions"` (none today) would see
  the new messages. Risk is theoretical — the topic is new in this
  ADR.
- `addEvent` per-frame may have per-event overhead at high frame
  rates. Mitigation: profile, batch if needed (covered in Q-C above).
- Catch-up `fetch_events/1` on mount can be heavy for long sessions.
  Acceptable for now (matches the existing one-shot player's load
  cost) and bounded by the session's natural length.

## Open items

- **OQ1**: Should the global topic be `"phoenix_replay:sessions"` or
  `"#{prefix}:sessions"` (parameterized by `:pubsub_topic_prefix`,
  consistent with per-session topics)? Lean: parameterize.
- **OQ2**: `:session_started` broadcast payload — what does the LV
  index need? Lean: `{session_id, identity, started_at}`. Identity
  may be `nil` for anonymous; admin index renders `(anonymous)`.
- **OQ3**: Default route mount path for the two LVs. Lean:
  `/phoenix_replay/sessions` (index) and
  `/phoenix_replay/sessions/:id/live` (watch). Host wraps in its own
  scope + auth.
- **OQ4**: Component vs. LiveView vs. both — should we ship a
  `<.session_watch session_id={...} />` reusable component alongside
  the full LV? Lean: yes, the LV is `use Phoenix.LiveView` + renders
  the component. Composability + a clean test surface.

## References

- ADR-0003 — Session Continuity (provides the PubSub bus this builds
  on).
- `docs/plans/completed/2026-04-23-session-continuity.md` —
  follow-ups list.
- rrweb-player `addEvent/1` API
  ([rrweb guide](https://github.com/rrweb-io/rrweb/blob/master/guide.md)).
- Phoenix LiveView `push_event/3` + JS hook `handleEvent` (Phoenix
  LiveView docs).
