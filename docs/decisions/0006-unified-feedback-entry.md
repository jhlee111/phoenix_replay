# ADR-0006: Unified Feedback Entry — Client-Side Ring Buffer + Two-Path UX

**Status**: Proposed
**Date**: 2026-04-25
**Builds on**: ADR-0001 (Widget Trigger UX), ADR-0002 (On-Demand Recording),
ADR-0003 (Session Continuity), Mode-aware panel addons spec (2026-04-25)
**Supersedes (in part)**: ADR-0002 — see Migration

## Context

Today the widget exposes two recording modes as separate host-config
choices: `:continuous` (capture begins on widget mount, server flushes every
5s, "Report issue" submits the accumulated session) and `:on_demand`
(idle until the user clicks "Record and report", then capture begins
fresh). Hosts pick one at compile/render time and end users see the
corresponding flow.

Two independent forces made this split feel wrong during the
mode-aware-panel-addons review (2026-04-25):

1. **End users don't know which mode the host picked.** The "two paths"
   framework is a real distinction in the user's head ("send what just
   happened" vs. "record me showing it"), but the host's compile-time
   mode choice forces one path to be invisible. A `:continuous` host
   has no way to offer the user "actually, let me record fresh" without
   a separate UI; a `:on_demand` host has no way to offer "just send
   what we already captured" because there's nothing captured.

2. **`:continuous` always-flush has an unacceptable side effect.** The
   server accumulates the user's normal page activity continuously,
   even when no report is ever submitted. A 25-minute browsing session
   produces a 25-minute event row in the database. Hosts that care
   about privacy, storage cost, or signal-to-noise of submitted
   reports rejected this as a default.

The two forces resolve to the same architectural change: stop flushing
events to the server until the user explicitly reports.

## Question A — capture model

Three options:

1. **Server-side slicing on submit** — keep continuous client-flush,
   but on submit attach only the trailing N seconds. TTL-clean
   unsubmitted events server-side (e.g., 10 minutes). Smallest delta;
   server still holds normal activity briefly.

2. **Client-side sliding ring buffer** — never flush passively to
   server. Client maintains a ring of the last N seconds (default 60s,
   host-configurable). On submit, the entire ring uploads. Largest
   delta; nothing reaches the server until the user reports.

3. **Mode-aware: keep both, host picks** — current `:continuous` for
   hosts who want full server-side capture (live monitoring, multi-page
   reproductions), new ring-buffer mode as default. More API surface;
   leaves `:continuous` as a footgun.

**Decision (proposed): option (2).** The user constraint
("불필요한 정상 동작이 제출되는 부작용은 not acceptable") is satisfied
by (2) and only by (2). Option (1) still stages normal activity
server-side temporarily. Option (3) keeps the footgun behind a config
flag — every host has to make the right choice, and many won't.

Trade-off accepted: the ADR-0004 multi-page session continuity story
no longer applies to the **passive** capture phase. It still applies
to **active** Record-and-Report sessions (those start a fresh
server-flushed session, exactly as today's `:on_demand`). Hosts that
need pre-trigger multi-page recording (rare; primarily admin
shoulder-surfing via Live Session Watch) keep that capability through
ADR-0004's Live Session Watch path, which is independent of widget
capture mode.

## Question B — what does the user see at entry?

Two options:

1. **Single CTA, mode-determined behavior** — "Report issue" button
   does what the host configured (Path A or Path B). Same as today.
2. **Two-option entry, always** — "Report issue" opens a panel with
   two equal cards: **Report now** (uploads buffer, text-only) and
   **Record and report** (discards buffer, starts fresh server-flushed
   session, optional voice commentary).

**Decision (proposed): option (2).** Both paths are user-meaningful in
every situation — the user, not the host, knows which one fits the
moment. Option (1) preserves the host's compile-time intent at the
cost of forcing every report through one path even when the other was
needed. The two-option panel is shipped on every widget by default;
hosts that want to suppress one option get a config knob (out of scope
for this ADR — see Phase plan).

## Question C — mic / voice-commentary timing in Path B

Two options:

1. **Ask at entry** — checkbox before recording starts ("□ Include
   voice commentary"). Mic permission requested once, fixed for the
   session.
2. **In-flight toggle on the recording pill** — recording starts
   without mic; the pill exposes a `🎙 Add voice commentary` toggle
   the user can flip mid-reproduction. Mic permission requested on
   first toggle-on.

**Decision (proposed): option (2).** Users decide they need narration
*after* hitting the bug ("wait, this is hard to explain in text").
Asking up-front interrupts the start moment with a permission prompt
that most users will dismiss. ADR-0001 (audio narration via
AshStorage, Phase 2) already records `audio_start_offset_ms` on the
blob — the in-flight toggle is the surface where that offset becomes
non-zero, and the playback sync from Phase 3 already handles it.

## Question D — severity in the user-facing form

The Feedback resource (in `ash_feedback`) has a `severity` attribute.
Today the widget exposes Low/Medium/High buttons in the submit form by
default. End users are not equipped to triage their own reports
(no comparative context, no business-impact awareness, observed
patterns: "always High" / "always Low"); QA-internal users are.

**Decision (proposed): default OFF, host opts in.** Widget exposes a
`show_severity` attr (default `false`). When `true`, the submit form
renders the severity buttons (existing UI). When `false`, the field is
omitted from the form and the resulting Feedback row gets `severity:
nil` (admin can triage it later). The phoenix_replay panel doesn't
know about ash_feedback's resource shape — it just renders the field
or doesn't, and the submit POST body carries severity-or-nil through
its existing pass-through. ash_feedback's resource accepts nil already.

## Question E — addon API extension

The mode-aware addon spec (2026-04-25) introduced `modes` filtering on
`registerPanelAddon`. The new UX adds two new mount surfaces:

1. **Recording pill slot** — `slot: "pill-action"`. ash_feedback's
   audio addon mounts its mic toggle here in Path B. Today's
   `slot: "form-top"` no longer applies because the form is hit
   *after* recording stops; the toggle has to live on the pill.
2. **Review-step slot** — `slot: "review-media"`. ash_feedback mounts
   the audio playback player (Phase 3 component) here so the user can
   preview their voice note before sending.

The existing `slot: "form-top"` slot stays — it remains useful for
non-audio addons that want to add fields to the submit form (e.g., a
tag picker, a project selector). The audio addon migrates from
`form-top` to the two new slots.

**Decision (proposed):** add the two new slots to the addon API. The
mount filter (`modes: ["on_demand"]` from the prior spec) is
re-interpreted: `:on_demand` becomes "mounts on Path B surfaces" since
Path B is the new name for the on-demand-style fresh-recording flow.
A future ADR may rename the symbol; this one preserves it for
migration cost reasons (per Mode-aware spec D1).

## Question F — what happens to the `:continuous` / `:on_demand` symbols?

**Decision (proposed): keep both symbols, redefine semantics.**

- `:on_demand` (renamed in user-facing prose to "Record and report") —
  the only fresh-recording-with-server-flush mode. Same code symbol
  as today.
- `:continuous` — repurposed: client-side ring buffer always-on (the
  new default). Same code symbol; capture mechanics changed.

Hosts that explicitly set `recording: :continuous` get the new
ring-buffer behavior automatically (they wanted "captures background
activity for retroactive reports" — that's still the contract; only
the implementation changed).

The default for the widget becomes `recording: :continuous` (ring
buffer) regardless of `:headless` / `:float` mode. The two-option
entry panel renders in both modes.

This is a **breaking semantic change** for hosts that relied on
server-side accumulation of normal activity. Migration: hosts wanting
that behavior wire their own client-side flush via the JS API
(`PhoenixReplay.startRecording()` on page load forces server-flushed
mode). README + CHANGELOG call this out.

## Migration

ADR-0002 is partially superseded:

- The widget no longer needs a host-config recording-mode choice for
  *user-facing path selection* — both paths are always available.
- The `:on_demand` symbol survives as the implementation detail of
  Path B's fresh-recording flow.
- ADR-0002's "Start reproduction" UI flow is replaced by the
  two-option entry → recording pill → two-step submit flow described
  in the design spec.

ADR-0003 (session continuity across page loads) survives unchanged
for Path B (active server-flushed sessions). For Path A (ring buffer),
the buffer is per-page-mount — page navigation discards it. This is a
deliberate scope reduction for Path A; if a user wants multi-page
reproduction they pick Path B.

ADR-0004 (Live Session Watch) is unaffected — admins watching a live
session see the active Path B session (the only one that flushes to
server) once the user starts recording.

Mode-aware panel addons spec (2026-04-25) is extended, not superseded:
the new slots (`pill-action`, `review-media`) sit alongside the
existing `form-top`, and the `modes` filter continues to gate mount.

## Risks

| Risk | Mitigation |
|---|---|
| Hosts relying on server-side continuous accumulation break silently | CHANGELOG + README migration note; the `:continuous` symbol stays so config doesn't break, only the runtime behavior changes |
| Ring buffer cap (default 60s) is too small for some bug-report scenarios | Host-configurable via `data-buffer-window-seconds` attr; default chosen for typical "I just saw it" reporting |
| Two-option panel is one extra click for the common "send what we have" case | Cards are equal-weight; muscle memory for "Report now" forms quickly. No A/B data yet — addendum if smoke shows otherwise |
| Audio addon migration (form-top → pill-action + review-media) breaks ash_feedback Phase 2 surface | ash_feedback gets its own follow-up spec (referenced from this ADR's downstream section); migration is coordinated, not silent |
| Path B's first-mic-toggle permission prompt interrupts reproduction flow | Permission requested at the moment of intent (the toggle click); the prompt is browser-standard and one-time per origin |

## Out of scope

- Renaming code symbols (`:continuous` → `:buffered`, etc.) — same
  rationale as Mode-aware spec D1 (host migration cost > UX gain).
- Server-side enforcement of buffer policy — the client is the source
  of truth for what gets uploaded; the server accepts what it receives.
- Slimming the ring buffer below 60s default — out of scope here, can
  be tuned by hosts.
- Compression / sampling of the ring buffer to fit more time per byte
  — separate ADR if it becomes load-bearing.
- AdminLive UI changes — admin replay still works against submitted
  events; no admin-side change required.

## Decisions log (carry-forward)

| From | Decision | Carried into |
|---|---|---|
| ADR-0001 | Float vs headless control style | unchanged |
| ADR-0002 | `:on_demand` symbol exists | Q-F: kept, semantics redefined |
| ADR-0003 | Session continuity across page loads | Q-A: applies to Path B only |
| ADR-0004 | Live Session Watch | Q-A: unaffected (Path B sessions still flush) |
| ADR-0005 | Replay player timeline event bus | unchanged |
| Mode-aware spec (2026-04-25) | `registerPanelAddon({modes})` | Q-E: extended with new slots |

## Downstream specs

- `docs/superpowers/specs/2026-04-25-unified-feedback-entry-design.md`
  — phoenix_replay UX + capture-model implementation + new addon slots.
- `~/Dev/ash_feedback/docs/superpowers/specs/2026-04-25-audio-addon-pill-relocation-design.md`
  — ash_feedback audio addon migration to `pill-action` + `review-media`
  slots.

Both downstream specs will be drafted alongside this ADR's promotion
to Accepted. Promotion is gated on user review.
