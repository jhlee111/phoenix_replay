# ADR-0007: LiveView Snapshot Stream — Server-Origin Capture via `attach_hook` + `CaptureStream` API

**Status**: Accepted
**Date**: 2026-04-28
**Accepted**: 2026-04-28
**Builds on**: ADR-0003 (Session Continuity), ADR-0005 (Replay Player Timeline Event Bus), ADR-0006 (Unified Feedback Entry)
**Spec**: [docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md](../superpowers/specs/2026-04-28-liveview-snapshot-design.md)
**Phase 1 plan**: [docs/superpowers/plans/2026-04-28-liveview-snapshot-phase-1.md](../superpowers/plans/2026-04-28-liveview-snapshot-phase-1.md)

## Context

phoenix_replay records browser sessions and surfaces them in an admin
replay UI for triage. When a report comes in, an admin can scrub the
timeline and see what the user saw — but cannot see what the LiveView
process was holding at any given timestamp (assigns, in-flight async
calls, the PubSub message that just fired). That gap is the
difference between "I see the broken UI" and "I see why it broke."

LiveDebugger provides this in dev. It is not portable to staging/prod
— `:erlang.dbg`-based, node-wide global tracer; full-socket
persistence with no PII redaction; authors explicitly state dev-only.
Forking the capture half is effectively rebuilding it.

Phoenix-blessed primitives (`attach_hook` + LiveView's existing
callback structure) plus phoenix_replay's existing per-session
infrastructure (Session GenServer, timeline event bus, panel addon
API) yield a complete capture-and-replay pipeline that is prod-safe
by construction.

## Decision

Introduce a new public API, `PhoenixReplay.CaptureStream`, that
models server-origin capture streams as a first-class concept. Build
`PhoenixReplay.LiveView.Snapshots` on top of it as the first internal
consumer. External libraries (e.g., a future ash_feedback Oban-state
addon) use the same API.

Sub-decisions:

- **Capture mechanism**: `Phoenix.LiveView.attach_hook/4` per stage,
  not `:dbg`. No node-wide tracer.
- **Activation**: per-session opt-in via `live_session`'s `on_mount`,
  O(1) ETS lookup gates the hot path.
- **Redaction**: shape-only by default. Allowlist for literal values
  is Phase 2.
- **Wire format**: rrweb type-6 plugin events with namespaced plugin
  name (`phx-replay/liveview@1`).
- **Storage**: existing `phoenix_replay_events` table — no migration.
- **Time alignment**: single-shot session-start clock offset, applied
  once at flush.
- **Cookie bridge**: `/session` POST sets `phx_replay_session_id`
  cookie; `PhoenixReplay.Plug.SessionLink` (host-installed in
  `:browser` pipeline) copies it to `Plug.Session` so LV `mount/3`
  reads it from the `session` arg.

## Host integration (Phase 1)

Two lines:

```elixir
# In :browser pipeline
plug PhoenixReplay.Plug.SessionLink

# In live_session block
on_mount: [{PhoenixReplay.LiveView.Snapshots, :install}]
```

That's it. Sessions recorded via Path B (record-and-report) have LV
state captured automatically. Path A (single-shot Report Now) does
not start a Session GenServer and therefore has no LV state in this
phase — accepted limitation since the user never explicitly opted
into recording.

## Consequences

- Hosts that don't add the `on_mount` line see no behavior change.
- Hosts that do see captured events appearing in their session
  records, alongside rrweb DOM/console/network events.
- Capture failures are isolated by `try/rescue` — they cannot crash
  the host LV.
- Memory cost per recording session is bounded by `:max_events`
  (default 5000) ring queue per stream and Session idle teardown.
- The `PhoenixReplay.CaptureStream` API is now public; external libs
  can build their own server-origin streams using the same
  primitives. Future deprecations require ADR.
- LiveDebugger-style features that need full assigns capture
  (specifically: live navigation between LVs with full state diffs,
  LiveComponent assigns, render-trigger snapshots) are explicitly
  out of v1 scope; they may arrive in later phases or be permanently
  deferred.

## Migration

None. Phase 1 is opt-in via `on_mount`.

## Related

- ADR-0003 — Session Continuity (Session GenServer state extension)
- ADR-0005 — Timeline Event Bus (replay-side panel addon will subscribe via this)
- ADR-0006 — Unified Feedback Entry (Path A and Path B both apply)
