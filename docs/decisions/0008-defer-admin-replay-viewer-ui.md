# ADR-0008: Defer Admin Replay Viewer UI for LiveView Snapshots (Phase 2)

**Status**: Accepted
**Date**: 2026-04-28
**Accepted**: 2026-04-28
**Supersedes (partially)**: ADR-0007 § "Replay UI" sub-decision and the `Replay UI — admin sidebar `LiveView` tab` section of `docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md` (Phase 2 work)
**Related**: ADR-0005 (Replay Player Timeline Event Bus), ADR-0007 (LiveView Snapshot Stream)

## Context

ADR-0007 shipped Phase 1 of the LiveView snapshot stream: server-origin
capture via `attach_hook`, the `PhoenixReplay.CaptureStream` API,
shape-only redaction, and ingest-time merge into the existing events
table. Captured LiveView state is now in the database, alongside rrweb
DOM/console/network events, with browser-timeline-aligned timestamps.

Phase 2 was scoped as the **admin replay viewer UI**: a new
`admin-sidebar-tab` panel addon slot rendering a "current snapshot"
section + an "event timeline" list synced to the rrweb player cursor
via the timeline bus (ADR-0005). The Phase 1 design document
(`2026-04-28-liveview-snapshot-design.md` § "Replay UI — admin
sidebar `LiveView` tab`) carried this design as a forward-looking
specification.

Before opening Phase 2, two questions surfaced:

1. **Are we reinventing the wheel?** Commercial RUM products
   (LogRocket, Sentry Replay, PostHog, Highlight.io, Datadog RUM)
   already render this kind of "session replay + state inspector
   sidebar" UX. If one of them is a viable substitute, building our
   own viewer is a poor use of effort.
2. **Is a human-facing viewer UI even the right primary consumer?**
   phoenix_replay/ash_feedback's data lives in the host's Postgres
   database with Ash code interfaces. An LLM agent can query it
   directly — no API tokens, no rate limits, no JSON marshaling — and
   that may be the higher-leverage debugging surface for the
   project's actual users.

A research pass was done on (1) before any Phase 2 code was written.
Findings:

| Candidate | Verdict |
|---|---|
| Sentry Cloud / self-host | Best UX match (User Feedback widget auto-links last 60s of session replay). But: FSL license (not OSI open source), Kafka+ClickHouse+Snuba operational footprint for self-host, `sentry_elixir` SDK is generic (no `attach_hook`-style automatic LV state capture). |
| PostHog Cloud free / FOSS | 1M events/mo free is workable, but Surveys ↔ Replay link is **not automatic** (requires manual `$session_id` wiring). Premium features in `ee/` are Cloud-only per their own self-host docs. No first-party Elixir SDK. |
| Highlight.io Hobby self-host | Apache 2.0 + `enterprise/` open-core split. Hobby tier ceiling is ~10k sessions/mo and **own docs say "not meant for production"**. **No official Elixir SDK** — GitHub issue #5082 is open with "wrap OpenTelemetry yourself." |
| Highlight.io Enterprise self-host | $3k/mo+. Out of scope for the project's positioning. |
| Sentry self-host | Closest to feature parity with Cloud (no software limits) but operationally heavy and FSL-licensed. |

The conclusion is that **no OSS RUM tool simultaneously satisfies**
the project's combined requirements: in-app feedback widget, automatic
session-replay link on submit, arbitrary server-side state
attachment, triage workflow, Phoenix-native deep integration, zero new
infrastructure, permissive license, and free tier sufficient for
production use. phoenix_replay/ash_feedback's slot is empty.

Question (1) therefore does not invalidate the project. It does,
however, change the scoping calculus: the unique value is on the
**capture and integration side** (Phase 1 work) and the **agent-friendly
data layer** (Postgres + Ash actions). The viewer UI is the most
substitutable component — both because commercial tools have
better-funded UX and because the human-viewer hypothesis is unproven
for our actual use case.

## Decision

Defer Phase 2 (admin replay viewer UI) indefinitely. Continue running
on Phase 1 capture + the existing ash_feedback admin (list, filter,
expandable LV snapshot JSON view).

Specifically:

- **Do not implement** the `admin-sidebar-tab` panel addon slot, the
  client-side LV state addon, click-to-seek wiring, navigation
  dividers in the timeline list, or any associated CSS in
  phoenix_replay's `priv/static/assets/`.
- **Do not implement** a `PhoenixReplay.seekTo(sessionId, ms, opts)`
  JS API. (The seek API was identified as a Phase 2 prerequisite gap;
  there's no consumer for it now.)
- **The Phase 1 design document's `Replay UI — admin sidebar
  LiveView tab` section is preserved as-is** for future reference. It
  is not deleted, edited, or rewritten — only marked as deferred via
  this ADR.

Capture-side work continues as planned. The Phase 1 spec's
`v1 explicitly deferred` list (custom shape extractors via app
config, allowlist macro for literal values, telemetry events,
LiveComponent assigns, render-as-trigger snapshots) remains a valid
backlog and can land independently of any viewer UI.

## When to revisit

Re-open this decision when there is concrete signal — not merely
intuition — that the agent + ash_feedback admin is insufficient. Such
signals include:

- Multiple cases (≥ 3) where a bug investigation stalled because the
  current admin's JSON view of LV snapshots was harder to reason
  about than a synced timeline view would have been.
- A user (host application operator) explicitly asks for replay
  scrubbing with state inspection, not as a "would be nice" but as a
  hard blocker.
- The project gains hosts beyond the current sole consumer, and one
  of them ships their own viewer integration that we'd rather absorb
  than fork.
- A future phase work item (e.g., bulk session triage at scale)
  produces requirements that obviously need a viewer.

Until then, the substantial design thinking already captured in
`2026-04-28-liveview-snapshot-design.md` § "Replay UI" stands as a
ready-to-use blueprint — restart cost is low.

## Consequences

- **Capture stays opt-in and ships value as-is.** Hosts adding the
  Phase 1 `on_mount` line still get LV snapshots in the events table.
  The ash_feedback admin already surfaces them at the row level.
- **No client-side admin-sidebar-tab slot exists.** Future addons
  intended for admin-replay context will need to introduce their own
  slot (or this one) at the time they land — there is no pre-built
  hook today.
- **The seek API gap remains open.** Any future addon that needs to
  drive the rrweb player programmatically will be the one to define
  that API; it is not a precondition handled here.
- **Spec drift risk.** The Phase 1 spec describes a "Replay UI"
  section that is no longer the active plan. Mitigation: the spec
  carries a status note pointing at this ADR; this ADR's "When to
  revisit" section makes the deferral explicit.
- **Reduced ongoing maintenance surface.** No additional
  vanilla-JS/CSS to keep aligned with rrweb-player upgrades or with
  panel addon API changes.
- **Project positioning sharpens.** phoenix_replay's distinctive
  value is now framed as: capture-side primitives + opaque data
  delivery, not "another session replay viewer." This makes future
  decisions about scope easier (the bar for any "viewer UX" work
  rises explicitly).

## Migration

None. Nothing was implemented.

The Phase 1 design document keeps its `Replay UI` section, with a
status note added at section top:

> **Status (2026-04-28):** Phase 2 (admin replay viewer UI) deferred —
> see [ADR-0008](../../decisions/0008-defer-admin-replay-viewer-ui.md).
> This section remains as the design-of-record for if/when work
> resumes.

No code, configuration, or downstream consumer is affected.
