# Design: Mode-aware Panel Addons + Path A/B Feedback IA

**Date**: 2026-04-25
**Owners**: phoenix_replay (primary, addon-API change), ash_feedback (consumer), ash_feedback_demo (host smoke)
**Driving conversation**: User feedback during ash_feedback Phase 3 audio playback smoke (2026-04-25) — see ash_feedback_demo memory `project_two_report_paths.md`.
**Status**: Draft — brainstorm session of 2026-04-25 produced the decisions captured here.

## Context

ash_feedback Phase 3 (admin audio playback) shipped and the sync logic is correct. Smoke surfaced a deeper IA issue that pre-dates Phase 3: the widget exposes the audio-recording affordance in **both** `:continuous` and `:on_demand` recording modes, but audio is only meaningful in one of them.

The user's framing — to be treated as the binding product framework going forward:

**Path A — "Quick report" / cached (continuous mode)**
- User hits "Report issue" after something breaks.
- Backend captures the trailing buffer of rrweb events that was already being recorded (LogRocket-style).
- The replay session may be 15–25+ minutes long; the report is *retrospective*.
- **Audio commentary is not meaningful here** — the rrweb timeline and any voice note exist in different time spaces and cannot be usefully synced.
- This path is **text description only**.

**Path B — "Record and report" / on-demand mode**
- User hits "Record and report".
- Both the rrweb session AND the audio recording start fresh from that moment.
- User narrates while reproducing the bug.
- The dev gets a short focused replay with **audio commentary correctly synced** to the timeline.
- This is where the Phase 3 audio playback work pays off.

## Architectural decisions

### D1 — Scope: minimum viable IA fix, no code-symbol churn

Three scope options were considered (A: minimum fix only, B: rename code symbols too, C: full widget UX redesign). **A.** The user's pain points are (i) audio surfaced on the wrong path and (ii) jargon-y user-facing labels. Both are addressed without renaming `:continuous` / `:on_demand` / `:headless` symbols, which would cost host migrations (gs_net, demo, future installers) for no UX gain — devs already understand the symbols.

### D2 — Mount policy lives in phoenix_replay's panel-addon API

`registerPanelAddon({id, slot, mount})` becomes `registerPanelAddon({id, slot, mount, modes})` where `modes` is an array of recording-mode strings. Mount logic compares the addon's declared `modes` against the widget's `data-recording` attribute and skips registration when no match.

```js
// Audio addon — meaningful only in on-demand mode
window.PhoenixReplay.registerPanelAddon({
  id: "audio",
  slot: "form-top",
  modes: ["on_demand"],
  mount: (ctx) => { /* ... */ },
});
```

**Default**: `modes` omitted means "any" — preserves backwards compat for existing addons (zero migration burden for current consumers). New addons opt in to mode filtering.

**Why phoenix_replay owns this** (vs. ash_feedback's audio addon self-skipping): the next addon (screenshot, tag picker, perf trace) will face the same question. Centralizing the policy in the addon API once is cheaper than every addon re-inventing the check.

### D3 — `:headless` is excluded from path classification

`:headless` is not a *path* — it's a control style (host directly drives `PhoenixReplay.start/stop` without a built-in widget UI). It can host either path semantically; the addon `modes` list can name it explicitly when a host has a use case. Default behavior: addons that don't list `:headless` simply don't auto-mount on headless widgets, and the host is responsible for assembling the UI it wants.

### D4 — User-facing labels

| Surface | Current | New |
|---|---|---|
| Path B widget trigger | "Start reproduction" | **"Record and report"** |
| Audio addon button (Path B only) | "🎙 Record voice note" | **"🎙 Add voice commentary"** |
| Demo page title (continuous) | "Continuous" | **"Quick report mode"** (heading) — route stays `/demo/continuous` |
| Demo page title (on-demand-float) | "On-demand float" | **"Record-and-report mode"** (heading) — route stays `/demo/on-demand-float` |
| README mode prose | "continuous mode" / "on-demand mode" | **"Quick report mode"** / **"Record-and-report mode"** (with `:continuous` / `:on_demand` symbol in parens) |
| Path A widget trigger | "Report issue" | **"Report issue"** unchanged — already plain |

Code symbols (`:continuous`, `:on_demand`, `:headless`) stay. Routes stay. CHANGELOG/git history stays.

### D5 — Backwards compatibility

- `registerPanelAddon` without `modes` → behaves as before (any-mode mount).
- Existing panel-addon callers (none outside ash_feedback today) are not touched.
- The rename of the Path B trigger ("Start reproduction" → "Record and report") IS a user-visible change; flag it in phoenix_replay CHANGELOG.

## Component breakdown

```
┌──────── phoenix_replay ────────────────────────────────────┐
│ • Panel-addon API: add `modes` opt to registerPanelAddon   │
│ • Panel mount logic: read widget data-recording, filter    │
│ • Panel template: Path B trigger label "Record and report" │
│ • README: mode prose + addon API doc updated               │
└────────────────────────────────────────────────────────────┘
           consumed by ▼
┌──────── ash_feedback ──────────────────────────────────────┐
│ • audio_recorder.js: register call adds modes:["on_demand"]│
│ • audio_recorder.js: button label "Add voice commentary"   │
│ • README mode-table mentions audio is on_demand-only       │
└────────────────────────────────────────────────────────────┘
           hosted by ▼
┌──────── ash_feedback_demo ─────────────────────────────────┐
│ • Demo page headings: "Quick report mode" / "Record-and-   │
│   report mode"                                             │
│ • Continuous page: explicit note "Audio not available in   │
│   this mode — see Record-and-report demo"                  │
└────────────────────────────────────────────────────────────┘
```

## Data flow on widget mount (mode filtering)

1. Widget element renders with `data-recording="on_demand"` (or `:continuous` / `:headless`).
2. phoenix_replay panel-init walks registered addons.
3. For each addon: if `addon.modes` is undefined → mount. If defined → mount only when `data-recording` value is in the list.
4. Skipped addons are silent (no warning); the addon's `mount(ctx)` is simply never called for that widget instance.

## Phasing

Single phase; tasks split across three repos.

1. **1.1** — phoenix_replay: addon API gains `modes` opt + panel mount logic + unit test for mount filtering.
2. **1.2** — phoenix_replay: Path B trigger label "Start reproduction" → "Record and report" + CHANGELOG entry.
3. **1.3** — ash_feedback: audio_recorder.js register call adds `modes: ["on_demand"]` + button label "Add voice commentary" + integration test that audio addon does not mount in `:continuous` widget.
4. **1.4** — ash_feedback_demo: demo page headings + continuous-mode note.
5. **1.5** — Cross-repo sync: deps cp + force recompile + restart + manual smoke (continuous page has no audio button; on-demand page has audio button with new label and works as before).
6. **1.6** — Docs: README updates in both libraries; finishing-a-development-branch.

## Test plan

**phoenix_replay (`mix test`):**
- Unit: addon API mount filtering — mode match → mount called; no match → mount not called; `modes` omitted → mount called regardless.
- Unit: existing panel-addon tests still pass (no behavior change for default-modes addons).

**ash_feedback (`mix test`):**
- Existing audio integration tests still pass (they exercise `:on_demand` widgets).
- New: integration test that mounts a `:continuous` widget and confirms `data-audio-clip-blob-id` never appears in submit body (because addon never registered → no extras forwarded).

**Manual smoke (browser):**
- Navigate to `/demo/continuous`, open widget panel: NO audio button visible. Submit text-only feedback works.
- Navigate to `/demo/on-demand-float`, click "Record and report" (renamed from "Start reproduction"), record audio, submit. Admin replay still works as in Phase 3.

## Risks

- **Hidden host dependency on the old "Start reproduction" string**: any host that documented or hard-coded the trigger label gets a surprise. Risk is small (single-author libraries pre-Hex). Mitigation: CHANGELOG entry calls it out.
- **Addon authors expect default = mount-everywhere**: documented in panel-addon README; the change is additive opt-in.
- **`:headless` host that uses audio**: if a future host wires audio in headless mode, they need to add `:headless` to the modes list explicitly. Documented in the addon API doc.

## Out of scope

- Renaming code symbols (`:continuous` → `:report_what_just_happened` etc.) — option B, rejected per D1.
- Widget UX redesign (auto-detect path, intro-step questionnaire) — option C, rejected per D1.
- AdminLive (5g) UX integration — separate gated work; this spec touches only widget-side IA.
- gs_net host migration — gs_net is a private workplace repo (memory `project_gs_net_visibility.md`); changes there are out of scope and the user owns them.
- Server-side enforcement that audio cannot be attached to a `:continuous` submit (the addon-mount fix removes the user-facing path; server-side gating would be belt-and-suspenders for an attack vector that doesn't exist).

## Decisions log (carry-forward)

| From | Decision | Status |
|---|---|---|
| ash_feedback ADR-0001 | Audio narration via AshStorage | shipped Phases 1+2+3 |
| ash_feedback Phase 3 spec D5 | Manual smoke matrix is the only behavioral check for sync logic | unchanged |
| Memory `project_two_report_paths.md` | Path A vs Path B framework | promoted to spec D1 here |

## Addendum trigger

If implementation surfaces facts that contradict the above (e.g., panel-addon API has constraints we missed, or the user wants a different label on review), append an addendum here rather than silently revising — same convention ash_feedback Phase 2/3 used.

## Addendum 2026-04-25 — D3 corrected post-implementation

The original D3 text said "addons that don't list `:headless` simply don't
auto-mount on headless widgets". This conflated two independent dimensions:

- **recording mode** — `:continuous` vs `:on_demand` (whether events buffer
  passively or recording starts on user action)
- **control style** — `:float` vs `:headless` (whether the widget renders its
  own toggle UI or the host drives lifecycle programmatically)

Implementation revealed they are orthogonal. The `modes` filter operates on
**recording mode only**; control style is independent. A widget with
`mode: :headless, recording: :on_demand` mounts the audio addon (because
`recording` matches `["on_demand"]`) — and this is correct, because audio's
meaningfulness is determined by the recording lifecycle, not by who calls
start/stop.

**Revised D3:** `:headless` is excluded from `modes` classification because it's
not a recording mode. Hosts driving the headless control style get whichever
addons match the widget's recording mode; if a host wants further filtering it
can wire its own UI without registering the library addon.

The 1.5 smoke matrix's H3 row is corrected accordingly: audio addon DOES render
on headless + on_demand widgets. The plan was updated to match.
