# ADR-0006 Phase 4 — Drop `modes:` Shim + `open()` Alias

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out ADR-0006 by removing the two transitional symbols
the unified-entry rollout left behind: the legacy `modes:` filter on
`registerPanelAddon` and the deprecated `open()` JS API alias. Convert
both to throwing stubs with helpful migration messages so any
out-of-tree consumer hitting them gets a clear, actionable error
instead of silent semantic drift.

**Architecture:** Three-task pass. (1) Migrate all live callers in
phoenix_replay + ash_feedback + ash_feedback_demo from the deprecated
symbols to the canonical ones (`open()` → `openPanel()`, `modes:` →
`paths:`). (2) Drop the shim from `phoenix_replay.js` — replace
`open()` with a throwing stub naming `openPanel()` and reject any
`modes:` argument in `registerPanelAddon` with an explicit error.
(3) Cross-repo deps refresh + browser smoke + CHANGELOG + plan-index.
The two-step ordering (callers first, shim second) keeps the
intermediate working tree green; if the shim were dropped first, the
migrated demo + docs would be unverifiable until the caller migration
landed.

**Tech Stack:** Pure JS edits to `phoenix_replay.js`, HEEx + Markdown
+ Elixir docstring edits across phoenix_replay, ash_feedback, and the
ash_feedback_demo host. No Elixir test changes (no controller
behavior change). Browser smoke verifies the runtime stubs surface
loud errors as designed and the migrated demo still opens the panel.

**Execution location:** Plan executes primarily in
`~/Dev/phoenix_replay`, with smaller edits in `~/Dev/ash_feedback`
(2 doc files) and `~/Dev/ash_feedback_demo` (1 HEEx file). The cross-
repo deps refresh + smoke runs from the demo CWD, which is the only
place all three trees mount as a running system.

**Why throwing stubs instead of silent removal:** the alpha library's
deprecation cycle for these two symbols was exactly one phase
(documented in Phase 3 CHANGELOG). Hosts who missed the upgrade
window need a loud, actionable signal — not a silent
`TypeError: ... is not a function` (for `open()`) or, worse, a silent
mount-on-every-path regression (for `modes:`, since after the
`pathFilterMatches` legacy branch is removed the filter falls through
to "mount everywhere"). Throwing with a one-line migration message
costs almost nothing and prevents the worst-case silent breakage.

---

## File Structure

| Path | Role | Action |
|---|---|---|
| `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex` | Demo headless page; calls deprecated `window.PhoenixReplay.open()` at line 79 | Modify (1 line) |
| `~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex` | Component @doc references `window.PhoenixReplay.open()` at lines 76 + 183 | Modify (2 strings) |
| `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` | Multi-instance warning at line 1370; `open()` alias at lines 1389-1395; legacy `modes:` branch at lines 902-919 in `pathFilterMatches`; `modes:` parsing at line 1463-1485 in `registerPanelAddon` | Modify (drop alias + drop legacy branches; replace with throwing stubs/errors; update warning text) |
| `~/Dev/phoenix_replay/README.md` | Quick-start example uses `window.PhoenixReplay.open()` at line 287; addon Options section documents `modes:` at lines 500-512 with stale example; "Recording modes" table at lines 524-534 references removed `:continuous`/`:on_demand` symbols | Modify (3 sections) |
| `~/Dev/phoenix_replay/docs/guides/headless-integration.md` | Examples use `window.PhoenixReplay.open()` at lines 48, 56, 82, 90, 132 | Modify (5 string replacements) |
| `~/Dev/phoenix_replay/docs/guides/on-demand-recording.md` | One example uses `window.PhoenixReplay.open()` at line 117 | Modify (1 string) |
| `~/Dev/ash_feedback/README.md` | "Mode-scoped" doc paragraph at line 251 still describes `modes: ["on_demand"]` as live | Modify (1 paragraph) |
| `~/Dev/ash_feedback/docs/guides/audio-narration.md` | Audio recorder description at line 22 still describes `modes: ["on_demand"]` as live | Modify (1 paragraph) |
| `~/Dev/phoenix_replay/CHANGELOG.md` | Add `### ADR-0006 Phase 4 — drop modes: shim + open() alias (2026-04-26)` under `[Unreleased]` | Modify |
| `~/Dev/phoenix_replay/docs/plans/README.md` | ADR-0006 row update: mark Phase 4 shipped, drop "Phase 4 next" caveat | Modify (1 row) |

**Out of scope for Phase 4:**
- The README's broader staleness — the addon Options section still
  describes `slot: "form-top"` as the only supported slot (Phase 3
  added `pill-action` + `review-media`). Updating the full Options
  section is README-refresh work; Phase 4 only updates the parts that
  describe the symbols being dropped this phase. Track separately.
- Historical references in `docs/decisions/`, `docs/superpowers/`,
  `docs/plans/completed/`, prior CHANGELOG entries, and any
  prior-phase plan files. Those are time-stamped artifacts; rewriting
  them rewrites history.

---

## Task 1 — Migrate live callers from deprecated symbols to canonical

**Files:**
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex` (line 79)
- Modify: `~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex` (lines 76, 183)
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (line 1370 — multi-instance warning text only)
- Modify: `~/Dev/phoenix_replay/README.md` (lines 287, 500-534)
- Modify: `~/Dev/phoenix_replay/docs/guides/headless-integration.md` (5 sites)
- Modify: `~/Dev/phoenix_replay/docs/guides/on-demand-recording.md` (1 site)
- Modify: `~/Dev/ash_feedback/README.md` (line 251 paragraph)
- Modify: `~/Dev/ash_feedback/docs/guides/audio-narration.md` (line 22 paragraph)

This task touches three repos. Group commits per repo to keep the
history navigable: one commit in ash_feedback_demo, one in
phoenix_replay (combining the lib + README + guides + JS warning
update — single conceptual change), one in ash_feedback. Don't push
yet — Task 3 handles the cross-repo verification first.

### Steps

- [ ] **Step 1: Migrate the demo headless page**

Edit `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex`. Find line 79:

```html
document.getElementById("odh-open").addEventListener("click", () => { window.PhoenixReplay.open(); log("open() called"); });
```

Replace with:

```html
document.getElementById("odh-open").addEventListener("click", () => { window.PhoenixReplay.openPanel(); log("openPanel() called"); });
```

Both the call site and the log message change so the displayed log
line stays aligned with the actual API.

- [ ] **Step 2: Migrate `components.ex` @doc references**

Edit `~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex`.

Line 76 currently reads:
```elixir
        "`window.PhoenixReplay.open()` / `.close()`."
```

Replace with:
```elixir
        "`window.PhoenixReplay.openPanel()` / `.close()`."
```

Lines 182-183 currently read:
```elixir
  control, call `window.PhoenixReplay.open()` and
  `window.PhoenixReplay.close()` from your JS. See the
```

Replace with:
```elixir
  control, call `window.PhoenixReplay.openPanel()` and
  `window.PhoenixReplay.close()` from your JS. See the
```

- [ ] **Step 3: Update the JS multi-instance warning text**

Edit `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js`. Find line 1370 (inside the multi-instance warning):

```js
            "window.PhoenixReplay.open()/close() will act on the first."
```

Replace with:

```js
            "window.PhoenixReplay.openPanel()/close() will act on the first."
```

- [ ] **Step 4: Update phoenix_replay README quick-start example**

Edit `~/Dev/phoenix_replay/README.md`. Find lines 286-289:

```js
window.PhoenixReplay.open();
window.PhoenixReplay.close();
```

Replace with:

```js
window.PhoenixReplay.openPanel();
window.PhoenixReplay.close();
```

- [ ] **Step 5: Update phoenix_replay README addon Options section (`modes:` → `paths:`)**

Edit `~/Dev/phoenix_replay/README.md`. Find lines 508-522:

```markdown
- `modes` (optional, array of strings) — recording-mode strings the addon
  mounts on (e.g., `["on_demand"]`). When present, the addon is skipped for
  widgets whose `recording` value isn't in the list. Default (omitted): mount
  on any recording mode. Filter operates on recording mode only; control style
  (`:float` / `:headless`) is independent.

  Example — an addon that's only meaningful on on-demand recordings:

  ```javascript
  PhoenixReplay.registerPanelAddon({
    id: "audio",
    modes: ["on_demand"],
    mount: (ctx) => { /* ... */ },
  });
  ```
```

Replace with:

```markdown
- `paths` (optional, array of strings) — user-facing path symbols the addon
  mounts on (`"report_now"` and/or `"record_and_report"`). When present, the
  addon is skipped for widgets whose `allow_paths` excludes every listed
  path. Default (omitted): mount on either path. The legacy `modes:` filter
  was removed in ADR-0006 Phase 4.

  Example — an addon that's only meaningful on Path B (Record-and-report):

  ```javascript
  PhoenixReplay.registerPanelAddon({
    id: "audio",
    paths: ["record_and_report"],
    mount: (ctx) => { /* ... */ },
  });
  ```
```

- [ ] **Step 6: Update phoenix_replay README "Recording modes" table**

Edit `~/Dev/phoenix_replay/README.md`. Find lines 524-534 (the
"Recording modes — symbol ↔ user-facing name" subsection):

```markdown
### Recording modes — symbol ↔ user-facing name

| Symbol | User-facing name | When to use |
|---|---|---|
| `:continuous` | Quick report mode | Cached event buffer; user reports after the fact (Path A — no audio commentary, replay timeline predates any voice note by minutes) |
| `:on_demand` | Record-and-report mode | Recording starts on user click; supports voice commentary (Path B — rrweb + audio start at the same moment, sync is meaningful) |

(`:headless` is a control style — `:float` vs `:headless` — not a recording mode.
It composes with either of the above. The addon `modes` filter operates on
recording mode only, so a `:headless` + `:on_demand` widget mounts on-demand
addons normally.)
```

Replace with:

```markdown
### User paths — symbol ↔ user-facing name

| Symbol | User-facing name | When to use |
|---|---|---|
| `"report_now"` | Quick report | The user clicks Report Now in the entry panel. The buffered ring of the last `buffer_window_seconds` is uploaded with the description. Text-only — no audio commentary because the buffer predates any voice note. |
| `"record_and_report"` | Record and report | The user clicks Record-and-report in the entry panel. A fresh server-flushed session begins; addons targeting `pill-action` (e.g. ash_feedback's mic toggle) mount on the recording pill. Audio commentary is supported here because rrweb + voice start together. |

The `paths:` filter on `registerPanelAddon` selects which user paths an
addon mounts on. The control-style attr `mode: :float | :headless` is
orthogonal — it governs whether the widget renders its own toggle button
or whether the host wires a `[data-phoenix-replay-trigger]` element / calls
`window.PhoenixReplay.openPanel()` directly. A `:headless` widget that
allows both paths still mounts a `paths: ["record_and_report"]` addon on
Path B.
```

- [ ] **Step 7: Update phoenix_replay headless-integration guide**

Edit `~/Dev/phoenix_replay/docs/guides/headless-integration.md`. Five
sites use `window.PhoenixReplay.open()` or `PhoenixReplay.open()`:

- Line 48: prose `call \`window.PhoenixReplay.open()\``
- Line 56: code `window.PhoenixReplay.open();`
- Line 82: prose `\`PhoenixReplay.open()\`,`
- Line 90: code `window.PhoenixReplay.open();`
- Line 132: prose `\`window.PhoenixReplay.open()\` / \`close()\``

Use `Edit` with `replace_all: false` per occurrence (the surrounding
context differs at each site so the edits are localized). Replace
each `open()` with `openPanel()` — preserve all other surrounding
text.

- [ ] **Step 8: Update phoenix_replay on-demand-recording guide**

Edit `~/Dev/phoenix_replay/docs/guides/on-demand-recording.md`. Find line 117:

```markdown
Call `window.PhoenixReplay.open()` from anywhere — a menu item, a
```

Replace with:

```markdown
Call `window.PhoenixReplay.openPanel()` from anywhere — a menu item, a
```

- [ ] **Step 9: Update ash_feedback README "Mode-scoped" paragraph**

Edit `~/Dev/ash_feedback/README.md`. Find the paragraph at line 251
that begins with `**Mode-scoped**: the recorder addon declares
\`modes: ["on_demand"]\` and only`. Read the full paragraph first
(typically 3-4 lines), then replace `modes: ["on_demand"]` with
`paths: ["record_and_report"]` and update the surrounding prose to
reference user-paths instead of recording modes:

```markdown
**Path-scoped**: the recorder addon declares `paths: ["record_and_report"]`
and only mounts when the host's `allow_paths` includes
`:record_and_report`. Path A widgets (text-only Report Now flow) silently
skip the addon — no mic surface appears.
```

(Adjust the trailing prose to match what the original paragraph
described — preserve any cross-references to other paragraphs.)

- [ ] **Step 10: Update ash_feedback audio-narration guide**

Edit `~/Dev/ash_feedback/docs/guides/audio-narration.md`. Find the
paragraph at line 22 describing `modes: ["on_demand"]`. Read the
paragraph, then update it:

Old (verbatim from current file):
```markdown
The audio recorder addon enforces this — it declares `modes: ["on_demand"]` at registration time, so the 🎙 button only appears on `:on_demand` widgets. On `:continuous` widgets the addon is silently skipped. Hosts who try to attach audio to a Quick-report flow get the description-only experience automatically.
```

Replace with:
```markdown
The audio recorder addon enforces this — it declares `paths: ["record_and_report"]` at registration time, so the 🎙 button only appears when the user picks Record-and-report from the entry panel. On Quick-report (Path A) the addon is silently skipped. Hosts whose `allow_paths` excludes `:record_and_report` get the description-only experience automatically.
```

- [ ] **Step 11: Verify no live `open(` or stale `modes:` references remain in active code**

Run from `~/Dev/`:

```
cd ~/Dev
grep -rn "PhoenixReplay\.open(" \
  ~/Dev/phoenix_replay/lib \
  ~/Dev/phoenix_replay/priv/static \
  ~/Dev/phoenix_replay/README.md \
  ~/Dev/phoenix_replay/docs/guides \
  ~/Dev/ash_feedback/lib \
  ~/Dev/ash_feedback/priv/static \
  ~/Dev/ash_feedback/README.md \
  ~/Dev/ash_feedback/docs/guides \
  ~/Dev/ash_feedback_demo/lib 2>/dev/null
```

Expected: no matches. Any remaining match is a missed migration site.

```
grep -rn 'modes:\s*\[' \
  ~/Dev/phoenix_replay/lib \
  ~/Dev/phoenix_replay/priv/static \
  ~/Dev/phoenix_replay/README.md \
  ~/Dev/phoenix_replay/docs/guides \
  ~/Dev/ash_feedback/lib \
  ~/Dev/ash_feedback/priv/static \
  ~/Dev/ash_feedback/README.md \
  ~/Dev/ash_feedback/docs/guides 2>/dev/null
```

Expected: no matches. The historical CHANGELOG / specs / plans / ADR
references are intentionally NOT covered by the grep above (they live
under `docs/decisions/`, `docs/superpowers/`, `docs/plans/completed/`,
and `CHANGELOG.md`, which are time-stamped artifacts).

- [ ] **Step 12: Commit per-repo (do NOT push)**

In `~/Dev/ash_feedback_demo`:
```
git add lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex
git commit -m "demo: openPanel() replaces deprecated open() alias (ADR-0006 Phase 4)"
```

In `~/Dev/phoenix_replay`:
```
cd ~/Dev/phoenix_replay
git add lib/phoenix_replay/ui/components.ex \
        priv/static/assets/phoenix_replay.js \
        README.md \
        docs/guides/headless-integration.md \
        docs/guides/on-demand-recording.md
git commit -m "docs: migrate open()/modes: to openPanel()/paths: (ADR-0006 Phase 4)"
```

In `~/Dev/ash_feedback`:
```
cd ~/Dev/ash_feedback
git add README.md docs/guides/audio-narration.md
git commit -m "docs: audio addon describes paths:, not legacy modes: (ADR-0006 Phase 4)"
```

Three local commits, none pushed. Task 2 will land the JS shim drop
in phoenix_replay; Task 3 handles cross-repo verification + push.

---

## Task 2 — Drop the JS shim in `phoenix_replay.js`

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (drop `open()` alias method; drop legacy `modes:` branch in `pathFilterMatches`; remove `modes` parameter from `registerPanelAddon` destructuring; replace both with helpful throwing stubs)

### Steps

- [ ] **Step 1: Drop the `open()` alias and replace with a throwing stub**

Edit `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js`.
Find the `open()` method (around line 1392):

```js
    // Open the first mounted panel. Routes per the widget's
    // allow_paths: both → CHOOSE screen; report_now-only → Path A
    // submit form directly; record_and_report-only → Path B start.
    // Backwards-compat alias for openPanel(); the existing
    // [data-phoenix-replay-trigger] delegated listener keeps working
    // unchanged because it routes through inst.routedOpen().
    open() {
      const inst = firstInstance();
      if (inst) inst.routedOpen();
    },
```

Replace with:

```js
    // ADR-0006 Phase 4 (2026-04-26): the deprecated `open()` alias
    // for `openPanel()` was removed. The throwing stub here points
    // hosts at the canonical name with one error message rather than
    // a vague "is not a function". The shim was retained for one
    // phase (Phase 3 CHANGELOG announced the deprecation); any host
    // still calling `.open()` after that window gets this message.
    open() {
      throw new Error(
        "[PhoenixReplay] window.PhoenixReplay.open() was removed in " +
          "ADR-0006 Phase 4. Use window.PhoenixReplay.openPanel() instead."
      );
    },
```

The `[data-phoenix-replay-trigger]` delegated listener routes through
`inst.routedOpen()` directly (not through this `open()` method) — see
the `installTriggerListener` definition earlier in the file. So
deleting the alias method does not break the auto-trigger surface.

- [ ] **Step 2: Drop the legacy `modes:` branch in `pathFilterMatches`**

Find `pathFilterMatches` (around lines 906-919):

```js
    // ADR-0006 Phase 3 path filter. Canonical: addon declares
    // `paths: ["report_now" | "record_and_report"]`. Legacy: `modes:
    // ["on_demand" | "continuous"]` is shimmed for one more phase
    // (audio addon migrates in the ash_feedback companion phase; this
    // shim drops in Phase 4).
    function pathFilterMatches(addon) {
      const allow = cfg.allowPaths || ["report_now", "record_and_report"];
      if (Array.isArray(addon.paths) && addon.paths.length > 0) {
        return addon.paths.some((p) => allow.includes(p));
      }
      if (Array.isArray(addon.modes) && addon.modes.length > 0) {
        return addon.modes.some((m) => {
          if (m === "on_demand") return allow.includes("record_and_report");
          if (m === "continuous") return allow.includes("report_now");
          return false;
        });
      }
      return true;
    }
```

Replace with:

```js
    // ADR-0006 Phase 3+4 path filter. Addons declare
    // `paths: ["report_now" | "record_and_report"]`; the filter
    // mounts an addon when at least one declared path is in the
    // host's `allow_paths`. Omitted `paths` means "mount on any
    // path." The legacy `modes:` filter was removed in Phase 4 —
    // see registerPanelAddon below for the rejection of stale
    // registrations.
    function pathFilterMatches(addon) {
      const allow = cfg.allowPaths || ["report_now", "record_and_report"];
      if (Array.isArray(addon.paths) && addon.paths.length > 0) {
        return addon.paths.some((p) => allow.includes(p));
      }
      return true;
    }
```

- [ ] **Step 3: Reject `modes:` in `registerPanelAddon`**

Find `registerPanelAddon` (around lines 1463-1485):

```js
    registerPanelAddon({ id, slot, mount, modes, paths }) {
      if (typeof id !== "string" || id.length === 0) {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a string id");
      }
      if (typeof mount !== "function") {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a mount function");
      }
      // `paths` (Phase 3) is the canonical filter — a list of
      // user-facing path symbols (`"report_now"`, `"record_and_report"`).
      // `modes` is the deprecated legacy filter from the 2026-04-25
      // mode-aware addons spec; both flow through pathFilterMatches.
      // New addons should use `paths`. The legacy `modes` shim drops
      // in Phase 4 once the audio addon migrates.
      const normalizedPaths = Array.isArray(paths) && paths.length > 0 ? paths : null;
      const normalizedModes = Array.isArray(modes) && modes.length > 0 ? modes : null;
      PANEL_ADDONS.set(id, {
        id,
        slot: slot || "form-top",
        mount,
        modes: normalizedModes,
        paths: normalizedPaths,
      });
    },
```

Replace with:

```js
    registerPanelAddon({ id, slot, mount, modes, paths }) {
      if (typeof id !== "string" || id.length === 0) {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a string id");
      }
      if (typeof mount !== "function") {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a mount function");
      }
      // ADR-0006 Phase 4: `modes:` was removed. Accepting it silently
      // would mount the addon on every path (the legacy gate is gone),
      // which is a worse failure than a loud rejection. The throw
      // names the canonical replacement so the migration is one line.
      if (modes !== undefined) {
        throw new Error(
          "[PhoenixReplay] registerPanelAddon: the `modes:` filter was " +
            "removed in ADR-0006 Phase 4. Use `paths: [\"report_now\" | " +
            "\"record_and_report\"]` instead. Addon id: " + id
        );
      }
      // `paths` is the canonical filter — a list of user-facing path
      // symbols (`"report_now"`, `"record_and_report"`). Omitted means
      // "mount on any path."
      const normalizedPaths = Array.isArray(paths) && paths.length > 0 ? paths : null;
      PANEL_ADDONS.set(id, {
        id,
        slot: slot || "form-top",
        mount,
        paths: normalizedPaths,
      });
    },
```

The `modes:` parameter stays in the destructuring signature on
purpose — that's how we detect it was passed (`modes !== undefined`).
Dropping it from the signature would silently accept and ignore
stale registrations.

- [ ] **Step 4: Drop the comment-block reference to `modes` in the addon registry header**

Find the addon registry comment near the top of the file (around lines
60-70):

```js
  // Panel addon registry. Each entry: { id, slot, mount, modes }. `mount(ctx)`
  // ...
  const PANEL_ADDONS = new Map();  // id -> { id, slot, mount, modes }
```

Replace with:

```js
  // Panel addon registry. Each entry: { id, slot, mount, paths }. `mount(ctx)`
  // ...
  const PANEL_ADDONS = new Map();  // id -> { id, slot, mount, paths }
```

(Read the surrounding context to confirm exact line numbers — search
for `Panel addon registry` if the header drifted.)

- [ ] **Step 5: Smoke-compile the JS by reading the diff**

This file is plain JS; there's no Elixir compile step that catches
syntax errors. Read the diff carefully:

```
cd ~/Dev/phoenix_replay
git diff priv/static/assets/phoenix_replay.js
```

Verify:
- the `open()` method is replaced (not duplicated)
- the legacy `modes:` branch in `pathFilterMatches` is gone
- `registerPanelAddon` now rejects `modes !== undefined` with a thrown error
- the `modes:` field is no longer set on PANEL_ADDONS entries
- no orphaned commas, missing braces, or duplicated keys

Eye-check the brace/comma counts at the boundaries of each change.

- [ ] **Step 6: Commit (do NOT push)**

```
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(addon): drop modes: shim and open() alias (ADR-0006 Phase 4)

Both symbols emit throwing stubs with helpful migration messages
rather than silent no-ops. The deprecation cycle was Phase 3 → Phase
4 (one cycle), per the Phase 3 CHANGELOG."
```

---

## Task 3 — Cross-repo deps refresh + smoke + CHANGELOG + plan-index

**Files:**
- Edit: `~/Dev/phoenix_replay/CHANGELOG.md` (add Phase 4 entry)
- Edit: `~/Dev/phoenix_replay/docs/plans/README.md` (mark Phase 4 shipped)

### Steps

- [ ] **Step 1: Cross-repo deps refresh**

The phoenix_replay JS shim drop only takes effect in the demo after
the file is copied into `deps/phoenix_replay/` and the dep is
force-recompiled (per CLAUDE.md memory: bare `restart_app_server`
uses cached beams).

```
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js

cp ~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/lib/phoenix_replay/ui/components.ex

cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force
```

Then restart the demo's app server via Tidewave (reason: `deps_changed`).

- [ ] **Step 2: Browser smoke matrix**

Verify the runtime stubs surface as designed and the migrated
on_demand_headless page still opens via the canonical API.

| # | Page | Action | Expected |
|---|---|---|---|
| 1 | `/demo/on-demand-headless` | Click the "Open" button (the migrated `openPanel()` caller) | Panel opens (CHOOSE screen). Console log says "openPanel() called". No errors. |
| 2 | `/demo/on-demand-headless` | In DevTools console: `window.PhoenixReplay.open()` | Throws: `[PhoenixReplay] window.PhoenixReplay.open() was removed in ADR-0006 Phase 4. Use window.PhoenixReplay.openPanel() instead.` |
| 3 | `/demo/on-demand-headless` | In DevTools console: `window.PhoenixReplay.openPanel()` | Panel opens cleanly. No errors. |
| 4 | `/demo/continuous` | Click Report → choose Record-and-report → confirm mic toggle appears on the recording pill | Audio addon's `pill-action` mount fires (it registers with `paths: ["record_and_report"]` which still works). |
| 5 | `/demo/continuous` | In DevTools console: `window.PhoenixReplay.registerPanelAddon({id: "test", mount: () => {}, modes: ["on_demand"]})` | Throws: `[PhoenixReplay] registerPanelAddon: the modes: filter was removed in ADR-0006 Phase 4. Use paths: ["report_now" | "record_and_report"] instead. Addon id: test` |
| 6 | `/demo/continuous` | In DevTools console: `window.PhoenixReplay.registerPanelAddon({id: "test2", mount: () => {}, paths: ["record_and_report"]})` | Returns undefined (registration succeeds silently). |
| 7 | `/demo/continuous` | Reload page → click Report → choose Report Now (Path A) | Path A submit form opens. No regressions. |
| 8 | `/demo/path-b-only` | Click trigger → recording pill appears with mic toggle | Audio addon mounts on Path B as before. |

If any row fails, STOP and report — don't proceed to commit. Likely
failure modes: Step 4 row failure means the audio addon's `paths:`
filter regressed (re-check Task 2 Step 2 diff); rows 2 + 5 means the
throwing stubs aren't wired (re-check Task 2 Step 1 + Step 3 diffs).

- [ ] **Step 3: Add CHANGELOG entry**

Edit `~/Dev/phoenix_replay/CHANGELOG.md`. Insert under `[Unreleased]`,
ABOVE the existing `### ADR-0006 Phase 2b — /report hardening
(2026-04-26)` block:

```markdown
### ADR-0006 Phase 4 — drop `modes:` shim + `open()` alias (2026-04-26)

Removes the two transitional symbols the unified-entry rollout left
behind. Both are replaced with throwing stubs that name the canonical
replacement, so any out-of-tree consumer hitting them gets a clear,
actionable error instead of silent semantic drift.

- **`window.PhoenixReplay.open()` removed.** The deprecated alias
  for `openPanel()` (introduced as backwards-compat in Phase 2,
  documented as deprecated in Phase 3) now throws:
  `window.PhoenixReplay.open() was removed in ADR-0006 Phase 4. Use
  window.PhoenixReplay.openPanel() instead.` Hosts that ran the
  Phase 3 migration are unaffected. The
  `[data-phoenix-replay-trigger]` delegated listener routes through
  the internal `routedOpen()` directly and continues to work
  unchanged.
- **`registerPanelAddon({modes: [...]})` removed.** The legacy
  recording-mode filter from the 2026-04-25 mode-aware-addons spec
  (mapped via a one-phase shim to `paths:` symbols) now throws:
  `the modes: filter was removed in ADR-0006 Phase 4. Use paths:
  ["report_now" | "record_and_report"] instead.` Throwing — rather
  than silently accepting and falling through to mount-on-every-path
  — was deliberate: the silent fallthrough would mount Path B addons
  on Path A widgets too, which is a worse failure than a loud
  rejection.

**Migration:**

```js
// Before (Phase 2/3)
window.PhoenixReplay.open();
PhoenixReplay.registerPanelAddon({
  id: "audio",
  modes: ["on_demand"],
  mount: (ctx) => { /* ... */ },
});

// After (Phase 4)
window.PhoenixReplay.openPanel();
PhoenixReplay.registerPanelAddon({
  id: "audio",
  paths: ["record_and_report"],
  mount: (ctx) => { /* ... */ },
});
```

The README and the headless-integration / on-demand-recording guides
were updated in this same release to use the canonical names. The
ash_feedback companion library's audio addon migrated to `paths:` in
its 2026-04-25 Phase 3 release, so no action is required for hosts
who use ash_feedback as their addon.

This closes ADR-0006. The unified feedback entry surface (Phases
1 + 2 + 2b + 3 + 4) is the new baseline.
```

- [ ] **Step 4: Commit CHANGELOG**

```
cd ~/Dev/phoenix_replay
git add CHANGELOG.md
git commit -m "docs(changelog): ADR-0006 Phase 4 — modes: shim + open() alias dropped"
```

- [ ] **Step 5: Update plan index**

Edit `~/Dev/phoenix_replay/docs/plans/README.md`. The ADR-0006 row
currently reads (after Phase 2b shipped):

```markdown
| —  | Unified Feedback Entry (ADR-0006) | Phases 1 + 2 + 2b + 3 shipped 2026-04-25..2026-04-26. **Next:** Phase 4 (drop legacy `modes:` shim now that ash_feedback audio migrated; drop `open()` alias) — plan not written yet. | [ADR](../decisions/0006-unified-feedback-entry.md) / [spec](../superpowers/specs/2026-04-25-unified-feedback-entry-design.md) / [Phase 1](../superpowers/plans/2026-04-25-unified-entry-phase-1.md) / [Phase 2](../superpowers/plans/2026-04-25-unified-entry-phase-2.md) / [Phase 2b](../superpowers/plans/2026-04-26-unified-entry-phase-2b-hardening.md) / [Phase 3](../superpowers/plans/2026-04-25-unified-entry-phase-3.md) |
```

Replace with:

```markdown
| —  | Unified Feedback Entry (ADR-0006) | Phases 1 + 2 + 2b + 3 + 4 shipped 2026-04-25..2026-04-26. ADR closed. | [ADR](../decisions/0006-unified-feedback-entry.md) / [spec](../superpowers/specs/2026-04-25-unified-feedback-entry-design.md) / [Phase 1](../superpowers/plans/2026-04-25-unified-entry-phase-1.md) / [Phase 2](../superpowers/plans/2026-04-25-unified-entry-phase-2.md) / [Phase 2b](../superpowers/plans/2026-04-26-unified-entry-phase-2b-hardening.md) / [Phase 3](../superpowers/plans/2026-04-25-unified-entry-phase-3.md) / [Phase 4](../superpowers/plans/2026-04-26-unified-entry-phase-4-shim-drop.md) |
```

- [ ] **Step 6: Commit the plan file + index update**

The Phase 4 plan file itself (this document) needs to land in git too
— the README link added in Step 5 needs a target. Mirror the Phase 2b
post-fix pattern: separate commits for index update + plan file.

```
cd ~/Dev/phoenix_replay
git add docs/superpowers/plans/2026-04-26-unified-entry-phase-4-shim-drop.md
git commit -m "docs(plans): ADR-0006 Phase 4 implementation plan"

git add docs/plans/README.md
git commit -m "docs(plans): mark ADR-0006 Phase 4 shipped; ADR closed"
```

- [ ] **Step 7: Verify all tests still pass**

```
cd ~/Dev/phoenix_replay && mix test 2>&1 | tail -5
```

Expected: 105 tests, 0 failures (Phase 4 is JS-only — no Elixir test
should change).

- [ ] **Step 8: Push when ready**

The plan defaults to NOT pushing — leave the local commits for the
user's review pass, matching the Phase 2b workflow. The user can push
all three repos manually when ready:

```
cd ~/Dev/phoenix_replay && git push origin main
cd ~/Dev/ash_feedback && git push origin main
cd ~/Dev/ash_feedback_demo  # nothing to push (demo is local-only per CLAUDE.md)
```

(The demo repo is a runtime sandbox; per `CLAUDE.md` "the demo
itself is intentionally untracked by git" — verify whether the demo's
heex commit needs pushing or stays local. If `cd ~/Dev/ash_feedback_demo
&& git status` shows the commit was made on a tracked branch with a
remote, push; otherwise leave.)

---

## Verification checklist (run after Task 3)

- 8 commits land across three repos (1 demo + 4 phoenix_replay + 1
  ash_feedback):
  - ash_feedback_demo: `demo: openPanel() replaces deprecated open() alias`
  - phoenix_replay: `docs: migrate open()/modes: to openPanel()/paths:`
  - phoenix_replay: `feat(addon): drop modes: shim and open() alias`
  - phoenix_replay: `docs(changelog): ADR-0006 Phase 4 — ...`
  - phoenix_replay: `docs(plans): ADR-0006 Phase 4 implementation plan`
  - phoenix_replay: `docs(plans): mark ADR-0006 Phase 4 shipped; ADR closed`
  - ash_feedback: `docs: audio addon describes paths:, not legacy modes:`
- Smoke matrix: 8 rows green
- `mix test` (phoenix_replay): 105 tests, 0 failures
- `grep PhoenixReplay\.open\(` across active code: 0 matches
- `grep 'modes:\s*\[' ` across active code: 0 matches

## Out of scope (deferred)

- README full-refresh: the Options section still describes
  `slot: "form-top"` as the only supported slot (Phase 3 added
  `pill-action` + `review-media`). Updating the full Options section
  is README-refresh work; Phase 4 only updates the parts that describe
  the symbols being dropped this phase. Recommend a separate
  doc-refresh pass.
- Historical references in `docs/decisions/`, `docs/superpowers/`,
  `docs/plans/completed/`, prior CHANGELOG entries, prior plan files.
  Time-stamped artifacts; not rewritten.
- Phoenix component compile-time flag for `modes:` on the Elixir
  side: there's no Elixir surface for `modes:` (it was always
  JS-side); nothing to validate at compile time.
- Hex publish: still deferred per the README index "Open follow-ups".
