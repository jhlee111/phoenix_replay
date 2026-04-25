# Mode-aware Panel Addons + Path A/B IA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `registerPanelAddon` mode-aware so the audio recorder only mounts on `:on_demand` widgets (Path B), rename user-facing labels to plain English, and update the demo to teach the two-path framework.

**Architecture:** phoenix_replay's `registerPanelAddon` gains a `modes` opt; the panel's mount loop filters addons against the widget's `data-recording` value. ash_feedback's audio addon opts in to `["on_demand"]` only. User-facing strings switch to "Record and report" / "Add voice commentary". Code symbols and routes unchanged for backwards compatibility.

**Tech Stack:** phoenix_replay (vanilla JS panel + Elixir component), ash_feedback (panel addon JS), ash_feedback_demo (host LiveView pages).

**Spec:** [`docs/superpowers/specs/2026-04-25-mode-aware-panel-addons.md`](../specs/2026-04-25-mode-aware-panel-addons.md)

---

## File Structure

**Modified files:**

- `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` — `registerPanelAddon` accepts `modes`, panel mount loop filters addons, Path B trigger label change.
- `~/Dev/phoenix_replay/CHANGELOG.md` — entry for the addon API addition + label rename.
- `~/Dev/phoenix_replay/README.md` — addon API doc updated; mode prose mentions plain-English names alongside symbols.
- `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js` — register call adds `modes: ["on_demand"]`, button text "Add voice commentary".
- `~/Dev/ash_feedback/CHANGELOG.md` — entry noting Path B-only audio addon + label change.
- `~/Dev/ash_feedback/README.md` — note that audio addon is on-demand-mode only.
- `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/continuous.html.heex` — heading "Quick report mode (`:continuous`)" + note "Audio commentary not available in this mode — see Record-and-report mode demo".
- `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex` — heading "Record-and-report mode (`:on_demand` floating widget)".
- `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex` — heading "Record-and-report mode (`:on_demand` headless control)".
- `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/index.html.heex` — landing page links updated to use new heading names.

**No file moves, no symbol renames, no route changes.**

---

## Task 1.1 — phoenix_replay: `registerPanelAddon({modes})` + panel mount filter

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (registerPanelAddon at line 924, PANEL_ADDONS Map declaration at line 60, mount loop at line 592)

**Recon Note:** the widget's `data-recording` attribute is emitted by `lib/phoenix_replay/ui/components.ex:176` and read into `init` opts at `phoenix_replay.js:949` as `recording: el.dataset.recording`. The mount loop runs inside the panel-init code with the panel `root` element in scope; we need the widget's recording mode at that point. The cheapest path: stash `init.recording` on the client/panel context so the mount loop can read it.

- [ ] **Step 1: Confirm threading path for `recording` into the panel mount loop**

```bash
cd ~/Dev/phoenix_replay
grep -n "recording" priv/static/assets/phoenix_replay.js | head -25
grep -n "init.*recording\|opts\.recording" priv/static/assets/phoenix_replay.js | head -10
```

Confirm where `init({ recording })` is consumed and whether the value is already retained on the client / panel context. If yes (most likely as `client.recording` or `opts.recording`), the mount loop can read it directly. If no, you need to thread it through one extra hop. Document the chosen path inline (1-line comment) before Step 3.

- [ ] **Step 2: Update PANEL_ADDONS Map shape declaration**

Edit `priv/static/assets/phoenix_replay.js` line 60:

```javascript
const PANEL_ADDONS = new Map();  // id -> { id, slot, mount, modes }
```

- [ ] **Step 3: Extend `registerPanelAddon` to accept `modes`**

Edit `priv/static/assets/phoenix_replay.js` line 924-932. Replace with:

```javascript
    registerPanelAddon({ id, slot, mount, modes }) {
      if (typeof id !== "string" || id.length === 0) {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a string id");
      }
      if (typeof mount !== "function") {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a mount function");
      }
      // `modes` opt: array of recording-mode strings the addon mounts on.
      // Omitted = mount on any mode (backwards-compat default for existing addons).
      // Example: { id: "audio", modes: ["on_demand"] } — mounts only on on-demand widgets.
      const normalizedModes = Array.isArray(modes) && modes.length > 0 ? modes : null;
      PANEL_ADDONS.set(id, { id, slot: slot || "form-top", mount, modes: normalizedModes });
    },
```

- [ ] **Step 4: Add mode-filter guard in the panel mount loop**

Edit `priv/static/assets/phoenix_replay.js` line 592 (the `PANEL_ADDONS.forEach((addon) => {` block). Insert a guard immediately after `const slotEl = slotEls.get(addon.slot);` and before the existing `if (!slotEl) {` check, so the filter runs first:

```javascript
    PANEL_ADDONS.forEach((addon) => {
      // Mode filter — addons that declare `modes` only mount when the
      // widget's recording mode matches. Recording mode is read from the
      // client context (set in init from data-recording).
      if (addon.modes && !addon.modes.includes(currentRecordingMode())) {
        return;
      }

      const slotEl = slotEls.get(addon.slot);
      if (!slotEl) {
        console.warn(`[PhoenixReplay] addon "${addon.id}" requested unknown slot "${addon.slot}"`);
        return;
      }
      // ... rest unchanged
```

Where `currentRecordingMode()` returns the recording mode threaded through from `init` per Step 1's recon. If Step 1 found `client.recording` already exists, this is `() => client.recording || "continuous"`. If not, you wired `panelOpts.recording` through and it's `() => panelOpts.recording || "continuous"`. Default to `"continuous"` when undefined to match the library's own default.

- [ ] **Step 5: Smoke-verify the change with a tiny in-browser script**

Phoenix_replay has no JS test infrastructure (cross-repo backlog item — see `docs/plans/README.md` line 19). The behavior is verified manually:

After the demo wiring lands in Task 1.5, the smoke matrix in Task 1.5 covers this. For now, a syntax check is the only automated guard:

```bash
cd ~/Dev/phoenix_replay
node --check priv/static/assets/phoenix_replay.js
```

Expected: no output (no syntax errors).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/phoenix_replay
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(panel): registerPanelAddon accepts modes for mount filtering (Phase 1.1)"
```

---

## Task 1.2 — phoenix_replay: Path B trigger label "Record and report"

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (lines 507 + 514, both occurrences of "Start reproduction")

- [ ] **Step 1: Replace the two label strings**

Edit `priv/static/assets/phoenix_replay.js`:

Line 507: `<h2>Start reproduction</h2>` → `<h2>Record and report</h2>`

Line 514: `<button type="button" class="phx-replay-start-cta">Start reproduction</button>` → `<button type="button" class="phx-replay-start-cta">Record and report</button>`

(Verify there are exactly TWO occurrences with `grep -n "Start reproduction" priv/static/assets/phoenix_replay.js` first. If more than two are found, replace all of them — they all refer to the Path B trigger.)

- [ ] **Step 2: Syntax check**

```bash
cd ~/Dev/phoenix_replay
node --check priv/static/assets/phoenix_replay.js
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/phoenix_replay
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(panel): rename Path B trigger 'Start reproduction' → 'Record and report' (Phase 1.2)"
```

---

## Task 1.3 — ash_feedback: audio addon opts in to `:on_demand` only + button label

**Files:**
- Modify: `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js` (registerPanelAddon call near line 335, button text strings around lines 90 + 108)

- [ ] **Step 1: Add `modes: ["on_demand"]` to the registerPanelAddon call**

Edit `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js`. Find the `buildAddon()` function (called at line 335 — `window.PhoenixReplay.registerPanelAddon(buildAddon())`). Locate the object it returns; add `modes: ["on_demand"]` alongside the existing `id`, `slot`, `mount`:

```javascript
  function buildAddon() {
    return {
      id: "audio",
      slot: "form-top",
      modes: ["on_demand"],  // Path B only — see ash_feedback ADR-0001 + phoenix_replay 2026-04-25 mode-aware-panel-addons spec
      mount: function (ctx) {
        // ... existing mount body unchanged
      },
    };
  }
```

If `buildAddon()`'s return object is structured differently in the actual file (e.g., assembled across multiple lines or via a builder pattern), insert `modes: ["on_demand"]` in the equivalent position. Read the function first; don't blindly paste.

- [ ] **Step 2: Update the button label**

Edit `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js`. Two strings to change:

Line ~90 (unsupported state): `unsup.textContent = "🎙 Voice note (unsupported)";` → `unsup.textContent = "🎙 Voice commentary (unsupported)";`

Line ~108 (idle state): `btn.textContent = "🎙 Record voice note";` → `btn.textContent = "🎙 Add voice commentary";`

(Search `grep -n "Voice note\|Record voice note" priv/static/assets/audio_recorder.js` to find any others — replace consistently. The "🎙" emoji stays.)

- [ ] **Step 3: Syntax check**

```bash
cd ~/Dev/ash_feedback
node --check priv/static/assets/audio_recorder.js
```

Expected: no output.

- [ ] **Step 4: Run the existing Elixir suite to confirm no regression**

Run: `cd ~/Dev/ash_feedback && mix test`
Expected: 46/46 pass (no Elixir behavior touched, but worth verifying nothing depends on the old strings).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/ash_feedback
git add priv/static/assets/audio_recorder.js
git commit -m "feat(audio): scope addon to :on_demand mode + 'Add voice commentary' label (Phase 1.3)"
```

---

## Task 1.4 — Demo: page headings + continuous-mode "no audio here" note

**Files:**
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/continuous.html.heex`
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex`
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex`
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/index.html.heex`

- [ ] **Step 1: Read the four files to find the existing headings**

```bash
cd ~/Dev/ash_feedback_demo
for f in lib/ash_feedback_demo_web/controllers/demo_html/{continuous,on_demand_float,on_demand_headless,index}.html.heex; do
  echo "=== $f ===";
  grep -nE "<h1|<h2|<title>|page_title" "$f" | head -5
done
```

Lock down the exact tag/class shapes used so your edits match the file's existing style.

- [ ] **Step 2: Update `continuous.html.heex` heading + add no-audio note**

Replace the page's main heading (likely `<h1>Continuous</h1>` or similar — adjust to match what Step 1 found) with:

```heex
<h1 class="text-2xl font-semibold">Quick report mode <code class="text-sm opacity-60">(:continuous)</code></h1>
<p class="text-sm opacity-70 mt-1">
  Captures the trailing buffer of rrweb events and ships them when the user clicks "Report issue".
  Best for "I just hit a bug, send what was happening" reports.
</p>
<p class="text-xs opacity-60 mt-2 border-l-2 border-amber-400 pl-2">
  <strong>Audio commentary is not available in this mode</strong> — the replay timeline
  predates any voice note by minutes, so the two can't be usefully synced.
  Try the <a href="/demo/on-demand-float" class="underline">Record-and-report mode</a> for narrated reports.
</p>
```

(Adjust class names to match the existing demo's Tailwind conventions visible in Step 1.)

- [ ] **Step 3: Update `on_demand_float.html.heex` heading**

Replace the page heading with:

```heex
<h1 class="text-2xl font-semibold">Record-and-report mode <code class="text-sm opacity-60">(:on_demand floating widget)</code></h1>
<p class="text-sm opacity-70 mt-1">
  Recording starts when the user clicks "Record and report". Voice commentary is in sync with
  the rrweb timeline because both start at the same moment.
</p>
```

- [ ] **Step 4: Update `on_demand_headless.html.heex` heading**

Replace the page heading with:

```heex
<h1 class="text-2xl font-semibold">Record-and-report mode <code class="text-sm opacity-60">(:on_demand headless control)</code></h1>
<p class="text-sm opacity-70 mt-1">
  Same recording semantics as the floating-widget variant, but the host drives start/stop directly
  via <code>PhoenixReplay.startRecording()</code> / <code>PhoenixReplay.stopRecording()</code>.
</p>
```

- [ ] **Step 5: Update `index.html.heex` link labels**

Find the link list pointing to the three demo modes. Update the visible link text:
- "Continuous" → "Quick report mode"
- "On-demand (float)" → "Record-and-report mode (float)"
- "On-demand (headless)" → "Record-and-report mode (headless)"

(Routes — `/demo/continuous`, `/demo/on-demand-float`, `/demo/on-demand-headless` — stay unchanged.)

- [ ] **Step 6: Compile demo**

Run: `cd ~/Dev/ash_feedback_demo && mix compile`
Expected: no errors (existing pre-existing `height="600px"` warning may surface, ignore — unrelated).

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/ash_feedback_demo
git add lib/ash_feedback_demo_web/controllers/demo_html/{continuous,on_demand_float,on_demand_headless,index}.html.heex
git commit -m "demo: rename mode pages to plain-English headings + continuous-mode no-audio note (Phase 1.4)"
```

---

## Task 1.5 — Cross-repo sync + manual smoke matrix

**Files:**
- Copy library files into `~/Dev/ash_feedback_demo/deps/` per the standard deps-cp + force-recompile workflow.

- [ ] **Step 1: Copy phoenix_replay JS + ash_feedback JS into demo deps**

```bash
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/

cp ~/Dev/ash_feedback/priv/static/assets/audio_recorder.js \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/priv/static/assets/

cd ~/Dev/ash_feedback_demo
mix deps.compile phoenix_replay --force
mix deps.compile ash_feedback --force
```

- [ ] **Step 2: Restart the demo app server**

Use the Tidewave `mcp__Tidewave-Web__restart_app_server` tool. Reason: `deps_changed`. (Memory pointer: `feedback_deps_force_recompile.md` — bare restart uses cached beams; force-recompile is required.)

- [ ] **Step 3: Smoke matrix — Continuous mode (Path A)**

Navigate to `http://localhost:4006/demo/continuous`. Verify:

| # | Check | Pass condition |
|---|---|---|
| C1 | Page heading | "Quick report mode (`:continuous`)" |
| C2 | No-audio note | Visible amber-bordered note linking to Record-and-report demo |
| C3 | Open widget panel | "🎙 Add voice commentary" button is **NOT** rendered (this is the core fix) |
| C4 | Submit text-only feedback | Works as before; appears in `/admin/feedback` index |

- [ ] **Step 4: Smoke matrix — Record-and-report mode (Path B)**

Navigate to `http://localhost:4006/demo/on-demand-float`. Verify:

| # | Check | Pass condition |
|---|---|---|
| R1 | Page heading | "Record-and-report mode (`:on_demand` floating widget)" |
| R2 | Trigger button | Reads "Record and report" (was "Start reproduction") |
| R3 | Open widget panel after starting | "🎙 Add voice commentary" button IS rendered |
| R4 | Record audio + submit | Audio attaches; admin replay still auto-syncs (no regression vs. Phase 3 smoke) |

- [ ] **Step 5: Smoke matrix — Headless mode**

Navigate to `http://localhost:4006/demo/on-demand-headless`. Verify:

| # | Check | Pass condition |
|---|---|---|
| H1 | Page heading | "Record-and-report mode (`:on_demand` headless control)" |
| H2 | Manual control buttons (`startRecording()` / `stopRecording()`) | Still work |
| H3 | Audio addon button | DOES render — `modes: ["on_demand"]` filters by recording mode, not control style. Headless + on_demand widgets are valid audio hosts. See spec addendum 2026-04-25. |

- [ ] **Step 6: If any smoke step fails, STOP and report**

Document the failure with: which step, what was expected, what was observed. Do NOT proceed to Task 1.6.

If all 11 checks pass, proceed to commit any cross-repo bookkeeping if needed (the deps cp itself is not committed — it's a local dev artifact).

- [ ] **Step 7: No-op if there's nothing to commit; otherwise note skipped**

Cross-repo sync produces no demo commit on its own (the deps copy lives only in `deps/`, which is gitignored). Document smoke results in the Task 1.6 CHANGELOG entry instead.

---

## Task 1.6 — Docs (CHANGELOG + README in both libs) + finishing-a-development-branch

**Files:**
- Modify: `~/Dev/phoenix_replay/CHANGELOG.md`
- Modify: `~/Dev/phoenix_replay/README.md`
- Modify: `~/Dev/ash_feedback/CHANGELOG.md`
- Modify: `~/Dev/ash_feedback/README.md`

- [ ] **Step 1: phoenix_replay CHANGELOG entry**

Edit `~/Dev/phoenix_replay/CHANGELOG.md`. Append under the unreleased section (read existing structure first):

```markdown
### Mode-aware panel addons (2026-04-25)

- `registerPanelAddon` accepts an optional `modes` array. When present, the addon
  mounts only on widgets whose `data-recording` value is in the list.
  Omitting `modes` preserves the previous behavior (mount on any widget).
- The Path B trigger label changed from "Start reproduction" to "Record and report"
  for plainer end-user language. Code symbols (`:continuous` / `:on_demand` /
  `:headless`) and routes are unchanged.

Smoke verified in Chrome on the ash_feedback_demo continuous + on-demand-float +
on-demand-headless pages — see Phase 1.5 smoke matrix in
`docs/superpowers/plans/2026-04-25-mode-aware-panel-addons.md`.
```

- [ ] **Step 2: phoenix_replay README — addon API doc**

Edit `~/Dev/phoenix_replay/README.md`. Find the panel-addon API section. Add to the option list (right after `mount`):

```markdown
- `modes` (optional, array of strings) — recording modes the addon mounts on.
  When present, the addon is skipped for widgets whose `data-recording` value
  isn't in the list. Defaults to "any mode" when omitted.

  Example — an addon that's only meaningful on on-demand recordings:

  ```javascript
  PhoenixReplay.registerPanelAddon({
    id: "audio",
    modes: ["on_demand"],
    mount: (ctx) => { /* ... */ },
  });
  ```
```

If the README also documents recording modes by their bare symbols, add the plain-English mapping so future readers see both:

```markdown
| Symbol | User-facing name | When to use |
|---|---|---|
| `:continuous` | Quick report mode | Cached event buffer; user reports after the fact |
| `:on_demand` | Record-and-report mode | Recording starts on user click; supports voice commentary |
| `:headless` | (Host-controlled) | Host calls start/stop directly; no built-in widget UI |
```

(If the README's existing prose has a different shape, preserve it and weave in the plain-English names. Don't restructure the whole README.)

- [ ] **Step 3: ash_feedback CHANGELOG entry**

Edit `~/Dev/ash_feedback/CHANGELOG.md`. Append:

```markdown
### Audio addon scoped to Record-and-report mode (2026-04-25)

- The audio recorder addon now declares `modes: ["on_demand"]` and only mounts
  on `:on_demand` widgets. On `:continuous` widgets the addon is skipped — audio
  commentary on retrospective replays would not be time-aligned with the rrweb
  timeline (see Path A vs Path B framing in the IA spec).
- Button label changed from "🎙 Record voice note" to "🎙 Add voice commentary"
  to better signal intent.

Requires phoenix_replay ≥ 2026-04-25 (mode-aware panel-addon API). Older
phoenix_replay silently ignores the `modes` opt and mounts the addon everywhere
(graceful degradation — old behavior).
```

- [ ] **Step 4: ash_feedback README**

Edit `~/Dev/ash_feedback/README.md`. Find any reference to the audio recorder. Add:

```markdown
> **Mode availability**: the audio recorder is registered with
> `modes: ["on_demand"]`. It mounts only on `:on_demand` widgets ("Record-and-report
> mode" in user-facing language). On `:continuous` widgets the addon is silently
> skipped — voice commentary on cached/retrospective replays cannot be synced to
> the rrweb timeline. See phoenix_replay's
> [mode-aware panel-addons spec](https://github.com/jhlee111/phoenix_replay/blob/main/docs/superpowers/specs/2026-04-25-mode-aware-panel-addons.md)
> for the full IA framework.
```

(Adjust the link to the actual repo path if phoenix_replay's GitHub URL differs.)

- [ ] **Step 5: Run both libraries' test suites**

```bash
cd ~/Dev/phoenix_replay && mix test
cd ~/Dev/ash_feedback && mix test
```

Expected: both green (no Elixir code touched in this plan; this verifies docs commits didn't accidentally break compilation).

- [ ] **Step 6: Commit docs**

```bash
cd ~/Dev/phoenix_replay
git add CHANGELOG.md README.md
git commit -m "docs(panel): mode-aware panel-addons API doc + CHANGELOG (Phase 1.6)"

cd ~/Dev/ash_feedback
git add CHANGELOG.md README.md
git commit -m "docs(audio): addon mode scoping + label rename (Phase 1.6)"
```

- [ ] **Step 7: finishing-a-development-branch**

Both libraries follow the direct-main-commit convention. Print one-line summaries:

```bash
cd ~/Dev/phoenix_replay && git log --oneline -8
cd ~/Dev/ash_feedback && git log --oneline -5
```

List the SHAs the user will push when ready (do NOT push automatically — single-author libraries, push is an explicit user action).

Phase 1 commits expected (this plan's output):
- phoenix_replay: 1.1 (addon API), 1.2 (label rename), 1.6 docs
- ash_feedback: 1.3 (addon opts in + label), 1.6 docs

---

## Out of scope (do not pull in)

- Renaming code symbols (`:continuous` etc.) — explicitly rejected per spec D1.
- Widget UX redesign (auto-detect path, intro questionnaire) — option C, rejected.
- AdminLive (5g) UX integration — separate gated work.
- gs_net host migration — private workplace repo (memory `project_gs_net_visibility.md`); user owns those changes.
- Server-side enforcement of "no audio on `:continuous`" — belt-and-suspenders for an attack vector that doesn't exist (the addon-mount fix removes the user-facing path; servers still accept any extras for forward-compat).
- JS test infrastructure for phoenix_replay panel behavior — cross-repo backlog item; smoke matrix is the verification surface for this plan.
