# ADR-0006 Phase 2 — Two-Option Entry Panel + Path A UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore end-to-end feedback submission on top of Phase 1's `:passive` ring buffer + `POST /report` foundation by shipping the user-facing two-option entry panel and the Path A (Report Now) submit flow. Drop the now-vestigial `recording` widget attr (ADR-0006 Q-F) and add three new host-config attrs (`show_severity`, `allow_paths`, `buffer_window_seconds`).

**Architecture:** The widget panel grows two new screens — `choose` (two-option entry: Report now / Record and report) and `path_a_form` (Path A's single-step submit — banner + textarea + optional severity + Send). A new `client.reportNow({...})` method drains the ring buffer and POSTs to `/report` (the endpoint shipped in Phase 1) without the long-lived `:active` session machinery. The Phase 1 `:on_demand` Stop → form → Send bridge is preserved unchanged for Path B. `allow_paths` lets a host skip the two-option panel when only one path is offered. The legacy `recording` attr is removed; widgets now decide path per-report based on user click, not host compile-time config.

**Tech Stack:** Elixir 1.18 / Phoenix 1.8 (component layer), Phoenix.LiveViewTest (component tests), vanilla ES2020 (panel JS), Node 20+ for `test/js/ring_buffer_test.js` smoke harness. No new dependencies.

---

## Phase 1 baseline (do not re-implement)

The following landed in Phase 1 (`be25e73`..`596cfb9` on `main`) and is the substrate Phase 2 builds on. Verify it's intact before starting:

- `priv/static/assets/phoenix_replay.js`:
  - `createRingBuffer({ maxEvents, windowMs, nowFn })` factory (lines ~160-193).
  - `state` machine: `:passive` (default) ↔ `:active`. Transitions: `startRecording` (passive→active), `stopRecording` (active→passive, partial teardown — keeps token), `report` / `transitionToPassive` (full teardown).
  - `flushOnUnload` is a no-op in `:passive`.
  - `_testInternals.createRingBuffer` exposed for the Node smoke.
- `lib/phoenix_replay/controller/report_controller.ex` mounted at `POST /report` via `feedback_routes/2`. Accepts `{description, severity, events, metadata, jam_link, extras}` and finalizes through `Storage.Dispatch.{start_session,append_events,submit}`.
- `test/phoenix_replay/controller/report_controller_test.exs` covers happy path, missing description (422), default severity, extras passthrough, non-list events (400).
- CHANGELOG `[Unreleased]` block documents Phase 1 + the `:continuous`-widget Send-button regression that Phase 2 closes.

If `git log --oneline | grep "Phase 1"` shows the six Phase 1 commits, you're set.

---

## File structure

This phase touches three concerns. Keep edits within these files; new files are listed where introduced.

### phoenix_replay (library — primary work)

| Path | Responsibility | Why this file |
|---|---|---|
| `lib/phoenix_replay/ui/components.ex` | `<.phoenix_replay_widget>` attrs + data-attribute emission. Drop `recording`, add `show_severity` / `allow_paths` / `buffer_window_seconds`. | Single source of attr surface; existing test + doc lives here. |
| `priv/static/assets/phoenix_replay.js` | DEFAULTS additions, `data-*` parsing, `CHOOSE` + `PATH_A_FORM` screens, `client.reportNow()`, `routedOpen()` rewire, public `openPanel`/`reportNow`/`recordAndReport`. | Single-file ES2020 widget per project convention; no bundler. |
| `priv/static/assets/phoenix_replay.css` | Two-option card styles for the `CHOOSE` screen. Path A banner styles. | Library CSS is colocated with JS; mirrors existing pattern (`.phx-replay-screen--*`). |
| `test/phoenix_replay/ui/components_test.exs` | New attr tests (`show_severity`, `allow_paths`, `buffer_window_seconds`); remove `recording` tests. | Existing component test module; no new file needed. |
| `CHANGELOG.md` | Phase 2 entry under `[Unreleased]` documenting the new attrs, dropped attr, restored Path A submission, JS API surface. | Existing changelog; same section as the Phase 1 entry. |

### ash_feedback_demo (smoke host — minor edits)

| Path | Responsibility | Why this file |
|---|---|---|
| `lib/ash_feedback_demo_web/controllers/demo_html/continuous.html.heex` | Drop `recording={:continuous}` from the page-rendered widget. The unified UX is identical for both paths now. | Phase 1 left this attr; component-level removal will compile-error here without this update. |
| `lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex` | Same — drop `recording={:on_demand}`. | Same. |
| `lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex` | Same — drop `recording={:on_demand}`. | Same. |

The demo's `index.html.heex` references the dropped attr in copy ("`recording`" combinations table) — leave that intact unless smoke surfaces a confusion; the index is documentation not a live mount.

No new demo pages (per-attr demos like `/demo/path-a-only` are deferred to spec Phase 4 / spec § Component breakdown).

---

## Self-Review After Plan Authoring

Before handing the plan off, the author runs the Self-Review at the end of this document. Implementation begins from Task 1 only after Self-Review passes.

---

## Task 1: Add new widget attrs + drop `recording`

**Files:**
- Modify: `lib/phoenix_replay/ui/components.ex` (attr block at lines 47-115 + render at lines 162-180)
- Test: `test/phoenix_replay/ui/components_test.exs` (existing module — adjust + add cases)

This task is component-level and pure HEEx, so we TDD it. New attr surface:
- `show_severity` (boolean, default `false`)
- `allow_paths` (list of atoms, default `[:report_now, :record_and_report]`, allowed values `:report_now` / `:record_and_report`)
- `buffer_window_seconds` (integer, default `60`)
- DROP: `recording` (atom, was `:continuous` / `:on_demand`)

Data attributes emitted on the mount div:
- `data-show-severity` ("true" / "false")
- `data-allow-paths` (CSV: `"report_now,record_and_report"`)
- `data-buffer-window-seconds` (integer string)
- DROP: `data-recording`

- [ ] **Step 1: Write the failing tests for the new attrs**

Edit `test/phoenix_replay/ui/components_test.exs`. After the existing `"position preset flows to data-position attr"` test (line ~194), and **before** the existing `"recording defaults to continuous"` test (line ~217), insert:

```elixir
    test "show_severity defaults to false" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-show-severity="false")
    end

    test "show_severity={true} flows to data-show-severity attr" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          show_severity: true
        )

      assert html =~ ~s(data-show-severity="true")
    end

    test "allow_paths defaults to both paths CSV" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-allow-paths="report_now,record_and_report")
    end

    test "allow_paths can be restricted to a single path" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          allow_paths: [:report_now]
        )

      assert html =~ ~s(data-allow-paths="report_now")
    end

    test "buffer_window_seconds defaults to 60" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-buffer-window-seconds="60")
    end

    test "buffer_window_seconds is host-tunable" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          buffer_window_seconds: 120
        )

      assert html =~ ~s(data-buffer-window-seconds="120")
    end
```

Then DELETE the two existing `recording` tests at lines ~217-236:

```elixir
    test "recording defaults to continuous" do
      ...
    end

    test "recording={:on_demand} flows to data-recording attr" do
      ...
    end
```

- [ ] **Step 2: Run the test file — expect 6 failures + 2 deletions confirmed**

Run: `cd ~/Dev/phoenix_replay && mix test test/phoenix_replay/ui/components_test.exs`

Expected: `6 failures` (the new tests; `recording` tests are gone so the previous 2 don't fail — they don't exist).

- [ ] **Step 3: Drop the `recording` attr and add the new attrs in `components.ex`**

In `lib/phoenix_replay/ui/components.ex`, **delete** the `recording` attr block (lines 78-92):

```elixir
  attr :recording, :atom,
    default: :continuous,
    values: [:continuous, :on_demand],
    doc:
      "`:continuous` (default) starts rrweb capture at widget mount and " <>
      ...
        "[On-demand recording guide](guides/on-demand-recording.html)."
```

Then in the same `attr` block region (after the `mode` attr at line 76), **insert**:

```elixir
  attr :show_severity, :boolean,
    default: false,
    doc:
      "When `true`, the submit forms (Path A and Path B) render Low/Medium/" <>
        "High severity buttons. When `false` (default), severity is omitted " <>
        "and the submitted Feedback row carries `severity: nil`. End-user " <>
        "widgets should leave this off — severity is a triage decision the " <>
        "receiver makes. Set `true` for QA-internal portals where the " <>
        "reporter is also the triager."

  attr :allow_paths, :list,
    default: [:report_now, :record_and_report],
    doc:
      "Which Report Issue paths the panel offers. Defaults to both. Pass " <>
        "`[:report_now]` to hide the Record-and-report card; pass " <>
        "`[:record_and_report]` to hide Report-now. When only one is " <>
        "allowed, clicking the trigger goes straight to that path's UI " <>
        "(no two-option panel)."

  attr :buffer_window_seconds, :integer,
    default: 60,
    doc:
      "Sliding-window size of the client-side ring buffer (seconds) used " <>
        "by Path A. Older events are evicted as they fall out of the " <>
        "window. Tune lower for memory-sensitive hosts; tune higher when " <>
        "users typically take longer to recognize and report a bug."
```

In the render function (lines 162-180), **delete** `data-recording={@recording}` and **add** three new data attrs. The final render becomes:

```elixir
  def phoenix_replay_widget(assigns) do
    ~H"""
    <link :if={@asset_path} rel="stylesheet" href={"#{@asset_path}/phoenix_replay.css"} />
    <script :if={@rrweb_src} src={@rrweb_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_console_src} src={@rrweb_console_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_network_src} src={@rrweb_network_src} crossorigin="anonymous"></script>
    <script :if={@asset_path} src={"#{@asset_path}/phoenix_replay.js"} defer></script>
    <div
      data-phoenix-replay
      data-base-path={@base_path}
      data-csrf-token={@csrf_token}
      data-widget-text={@widget_text}
      data-position={@position}
      data-mode={@mode}
      data-show-severity={to_string(@show_severity)}
      data-allow-paths={Enum.map_join(@allow_paths, ",", &Atom.to_string/1)}
      data-buffer-window-seconds={@buffer_window_seconds}
      {@rest}
    />
    """
  end
```

Also delete the on-demand-recording references from the moduledoc / @doc that mention `:continuous` / `:on_demand` if they reference the removed attr — search the file for "recording" and update copy that's now inaccurate. Leave neutral references alone.

- [ ] **Step 4: Re-run the component tests — expect green**

Run: `cd ~/Dev/phoenix_replay && mix test test/phoenix_replay/ui/components_test.exs`

Expected: all tests pass (count depends on the prior baseline — it should match `mix test` count of the file pre-change, minus 2 deleted, plus 6 added).

- [ ] **Step 5: Run full mix test to confirm no other test referenced `recording`**

Run: `cd ~/Dev/phoenix_replay && mix test`

Expected: green. If a router or igniter test referenced `data-recording`, fix the reference (it should be removed, not migrated — the data attribute no longer exists).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/phoenix_replay && git add lib/phoenix_replay/ui/components.ex test/phoenix_replay/ui/components_test.exs && git commit -m "$(cat <<'EOF'
feat(component): drop recording attr; add show_severity/allow_paths/buffer_window_seconds

ADR-0006 Q-F: the recording attr no longer drives behavior — Phase 2's
two-option entry panel decides path per-report based on user click.
Replace with three host-config knobs:

- show_severity (default false): conditionally render the severity
  field on the submit form.
- allow_paths (default both): which paths the entry panel offers;
  single-path widgets skip the two-option screen.
- buffer_window_seconds (default 60): sliding ring buffer window.

Hosts that previously passed recording={:continuous|:on_demand} get
a clear compiler error (unknown attr) — louder is better than silent
semantic shift. CHANGELOG and README migration notes follow in
later tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Parse new data attrs in `phoenix_replay.js`

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (DEFAULTS at lines 15-35; `autoMount` at lines 981-995)

JS-side: read the new data attrs into the cfg object so `createClient` and panel code can branch on them. This is a small mechanical change — no test can run against it directly (no JS test framework yet), but Task 3 onward exercises it.

- [ ] **Step 1: Add new DEFAULTS entries**

In `priv/static/assets/phoenix_replay.js`, in the `DEFAULTS` block (lines 15-35), make these changes:

```javascript
  const DEFAULTS = {
    // Endpoints relative to `basePath` (set at init time from the
    // mount element's data-base-path attribute).
    sessionPath: "/session",
    eventsPath: "/events",
    submitPath: "/submit",
    reportPath: "/report",                  // NEW — Path A endpoint
    // Batching.
    maxEventsPerBatch: 50,
    flushIntervalMs: 5000,
    maxBufferedEvents: 10_000, // ring-buffer cap
    bufferWindowMs: 60_000,    // ring-buffer time window (ADR-0006 Phase 1)
    // Network.
    tokenHeader: "x-phoenix-replay-session",
    csrfHeader: "x-csrf-token",
    // Widget UX.
    widgetText: "Report issue",
    position: "bottom_right",
    showSeverity: false,                    // NEW — gate severity field
    allowPaths: ["report_now", "record_and_report"],  // NEW — entry panel options
    severities: ["info", "low", "medium", "high", "critical"],
    defaultSeverity: "medium",
  };
```

**Delete** the `recording: "continuous"` line — it's gone with the attr.

- [ ] **Step 2: Update `autoMount` to read new data attrs**

In `priv/static/assets/phoenix_replay.js`, replace the `autoMount` body (lines 981-995):

```javascript
    autoMount() {
      document.querySelectorAll("[data-phoenix-replay]").forEach((el) => {
        if (el.dataset.phoenixReplayMounted) return;
        el.dataset.phoenixReplayMounted = "1";

        // Parse data-* into init opts. Booleans/numbers/lists need explicit
        // coercion; strings flow through as-is.
        const showSeverity = el.dataset.showSeverity === "true";
        const allowPaths = (el.dataset.allowPaths || "report_now,record_and_report")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        const bufferWindowSeconds = Number(el.dataset.bufferWindowSeconds);
        const bufferWindowMs = Number.isFinite(bufferWindowSeconds) && bufferWindowSeconds > 0
          ? bufferWindowSeconds * 1000
          : DEFAULTS.bufferWindowMs;

        PhoenixReplay.init({
          mount: el,
          basePath: el.dataset.basePath,
          csrfToken: el.dataset.csrfToken,
          widgetText: el.dataset.widgetText,
          position: el.dataset.position,
          mode: el.dataset.mode,
          showSeverity,
          allowPaths,
          bufferWindowMs,
        }).catch((err) => console.warn("[PhoenixReplay] auto-mount failed:", err));
      });
    },
```

- [ ] **Step 3: Remove `recording` references from `createClient` + `renderPanel`**

The Phase 1 `:passive`/`:active` state machine doesn't use `cfg.recording` anymore EXCEPT in two places:

1. `ensureSession`'s session-interrupted branch (`if (interrupted && cfg.recording === "on_demand") {...}`, lines ~293-301).
2. `renderPanel`'s addon-mode filter (`addon.modes && !addon.modes.includes(currentRecordingMode())`, lines ~625-631).

For (1) — the interrupted-session branch — drop the `cfg.recording === "on_demand"` gate. Since Phase 2 makes `:active` only entered via explicit user click (Path B), every interrupted-session resume should surface the error rather than silently overwrite. Replace lines ~293-307:

```javascript
      if (interrupted) {
        // ADR-0006: every active session is the result of an explicit
        // user click (Path B "Record and report"). A stale-token resume
        // means that consent chain is broken — surface the error and
        // wait for Retry rather than silently adopting a fresh server
        // token.
        storageClear(STORAGE_KEYS.TOKEN);
        storageClear(STORAGE_KEYS.RECORDING);
        throw new PhoenixReplaySessionInterruptedError();
      }

      sessionToken = freshToken;
      sessionStartedAtMs = Date.now();
      storageWrite(STORAGE_KEYS.TOKEN, freshToken);
      seq = resumed ? (Number(res.seq_watermark) || 0) + 1 : 0;
```

For (2) — the addon mode filter — preserve the filter but read it from `cfg.allowPaths` instead. The previous semantic was "this addon only mounts when the widget is `:on_demand`." The new equivalent is "this addon only mounts when path X is reachable." Since Phase 2's panel can offer either or both paths, and Path B is when audio addons need to mount, the filter check becomes: addon's `modes` contains `"on_demand"` if-and-only-if the widget's `allowPaths` includes `"record_and_report"`.

Replace lines ~620-651's `currentRecordingMode` + `PANEL_ADDONS.forEach` block with:

```javascript
    // The addon `modes` filter is a transitional symbol from the
    // mode-aware addons spec (2026-04-25). It maps:
    //   modes: ["on_demand"] → mount when allowPaths includes record_and_report
    //   modes: ["continuous"] → mount when allowPaths includes report_now
    // ADR-0006 Phase 4 will rename this to `paths: [:report_now,
    // :record_and_report]` directly. Until then, this shim preserves the
    // shipped audio addon's registration without breaking it mid-rollout.
    function modeMatchesAllowPaths(modes) {
      if (!modes) return true;
      const allow = cfg.allowPaths || ["report_now", "record_and_report"];
      return modes.some((m) => {
        if (m === "on_demand") return allow.includes("record_and_report");
        if (m === "continuous") return allow.includes("report_now");
        return false;
      });
    }

    PANEL_ADDONS.forEach((addon) => {
      if (!modeMatchesAllowPaths(addon.modes)) return;

      const slotEl = slotEls.get(addon.slot);
      if (!slotEl) {
        console.warn(`[PhoenixReplay] addon "${addon.id}" requested unknown slot "${addon.slot}"`);
        return;
      }
      try {
        const ctx = {
          slotEl,
          sessionId: () => client._internals?.sessionId?.() ?? null,
          sessionStartedAtMs: () => client._internals?.sessionStartedAtMs?.() ?? null,
          onPanelClose: (cb) => addonCloseCbs.push(cb),
          reportError: (msg) => { errorMessage.textContent = msg; setScreen(SCREENS.ERROR); showModal(); },
        };
        const hooks = addon.mount(ctx) || {};
        addonHooks.push({ id: addon.id, ...hooks });
      } catch (err) {
        console.warn(`[PhoenixReplay] addon "${addon.id}" failed to mount: ${err.message}`);
      }
    });
```

Also in `init` (line ~818), **delete** the `const onDemand = cfg.recording === "on_demand";` line. The `onDemand` flag is no longer used — Phase 2 routes via `allow_paths` (Task 4).

- [ ] **Step 4: Run the JS smoke**

Run: `cd ~/Dev/phoenix_replay && node test/js/ring_buffer_test.js`

Expected: `OK ring_buffer_test (4 cases)` (Phase 1's test still passes — we haven't touched the ring buffer).

- [ ] **Step 5: Run mix test (Elixir suite still green)**

Run: `cd ~/Dev/phoenix_replay && mix test`

Expected: green. The component test in Task 1 is the only Elixir reference to the new attrs.

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(js): parse show_severity/allow_paths/buffer_window_seconds; drop recording

Threads the three new component attrs through autoMount → init → cfg.
buffer_window_seconds is converted to bufferWindowMs to match the
existing ring buffer config. allowPaths flows through as the
authoritative source for "which paths does this widget offer" — the
Phase 1 mode-aware addon filter (modes: ['on_demand']) is bridged to
the new model via a transitional shim that maps :on_demand to
:record_and_report and :continuous to :report_now until ADR-0006
Phase 4 renames the addon API directly.

The :passive/:active state machine no longer branches on cfg.recording.
Stale-token resume now always surfaces PhoenixReplaySessionInterruptedError
because every :active session in the new model is the result of an
explicit user click — there's no "silent recovery" path to preserve.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `CHOOSE` screen template + CSS

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (`SCREENS` constant at line 49; `renderPanel` HTML at lines 526-580)
- Modify: `priv/static/assets/phoenix_replay.css` (append two-option card styles)

Add the new entry screen and its DOM. No behavior wiring yet — that's Task 4.

- [ ] **Step 1: Extend the `SCREENS` constant**

In `priv/static/assets/phoenix_replay.js` at line 49, replace:

```javascript
  const SCREENS = { IDLE_START: "idle_start", ERROR: "error", FORM: "form" };
```

with:

```javascript
  const SCREENS = {
    CHOOSE: "choose",
    IDLE_START: "idle_start",
    ERROR: "error",
    FORM: "form",                  // Path B describe step (legacy name preserved)
    PATH_A_FORM: "path_a_form",    // Path A single-step submit
  };
```

- [ ] **Step 2: Add the `CHOOSE` `<section>` HTML to `renderPanel`**

In `renderPanel` (line ~526), inside the `<div class="phx-replay-modal-panel">` block, insert the new section as the FIRST screen (before `IDLE_START`):

```html
          <section class="phx-replay-screen phx-replay-screen--choose" data-screen="${SCREENS.CHOOSE}" hidden>
            <h2>Report an issue</h2>
            <p class="phx-replay-screen-lede">How would you like to send feedback?</p>
            <div class="phx-replay-choose-cards">
              <button type="button" class="phx-replay-choose-card phx-replay-choose-report-now" data-path="report_now">
                <span class="phx-replay-choose-card-icon" aria-hidden="true">📨</span>
                <span class="phx-replay-choose-card-title">Report now</span>
                <span class="phx-replay-choose-card-desc">Includes the recent activity from this page.</span>
              </button>
              <button type="button" class="phx-replay-choose-card phx-replay-choose-record" data-path="record_and_report">
                <span class="phx-replay-choose-card-icon" aria-hidden="true">🔴</span>
                <span class="phx-replay-choose-card-title">Record and report</span>
                <span class="phx-replay-choose-card-desc">Start a fresh recording, then describe the issue.</span>
              </button>
            </div>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
            </div>
          </section>
```

The full updated template block (the section list inside `<div class="phx-replay-modal-panel">`) becomes: `CHOOSE` → `IDLE_START` → `ERROR` → `FORM` (existing) → `PATH_A_FORM` (Task 5 will add).

- [ ] **Step 3: Append CSS for the cards**

Append to `priv/static/assets/phoenix_replay.css` (after the existing pill styles at line ~282):

```css
/* Two-option entry panel — vertical-stacked equal-weight cards.
 * The cards are full-width buttons; clicking a card transitions the
 * panel to that path's flow. Hover/focus mirror the existing primary
 * button (`.phx-replay-submit`) treatment for consistency.
 */
.phx-replay-choose-cards {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.phx-replay-choose-card {
  display: grid;
  grid-template-columns: 2rem 1fr;
  grid-template-rows: auto auto;
  column-gap: 0.625rem;
  row-gap: 0.125rem;
  align-items: start;
  padding: 0.875rem 1rem;
  background: var(--phx-replay-surface);
  border: 1px solid var(--phx-replay-border);
  border-radius: 0.625rem;
  cursor: pointer;
  text-align: left;
  font: inherit;
  color: inherit;
}

.phx-replay-choose-card:hover {
  background: var(--phx-replay-surface-muted);
  border-color: var(--phx-replay-primary);
}

.phx-replay-choose-card:focus-visible {
  outline: 2px solid var(--phx-replay-primary);
  outline-offset: 1px;
}

.phx-replay-choose-card-icon {
  grid-row: 1 / span 2;
  grid-column: 1;
  font-size: 1.25rem;
  line-height: 1;
}

.phx-replay-choose-card-title {
  grid-row: 1;
  grid-column: 2;
  font-weight: 600;
  font-size: 0.9375rem;
  color: var(--phx-replay-text);
}

.phx-replay-choose-card-desc {
  grid-row: 2;
  grid-column: 2;
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted);
  line-height: 1.4;
}
```

- [ ] **Step 4: Verify it parses (no JS test framework yet — load in browser is in Task 9 smoke)**

Run: `cd ~/Dev/phoenix_replay && node -e "require('fs').readFileSync('priv/static/assets/phoenix_replay.js', 'utf8'); console.log('JS file loads')"`

Expected: `JS file loads` (Node parses the file as text — no SyntaxError on this CommonJS read).

A more direct syntax check:

```bash
cd ~/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
```

Expected: no output, exit 0. (`--check` parses without executing.)

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(panel): add CHOOSE screen template + two-option card CSS

ADR-0006 Phase 2.1: the entry panel grows a new top-level "Report an
issue" screen with two equal-weight cards — Report now / Record and
report. Wiring is added in Task 4; this commit just lands the markup
and styles so card layout can be reviewed independently of behavior.

PATH_A_FORM is reserved in the SCREENS enum but its <section> markup
lands in Task 5 alongside the client.reportNow() submit handler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewire `routedOpen()` for `CHOOSE` + single-path skip

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (`renderPanel`'s `openX` helpers + return; `init`'s `routedOpen`)

The Phase 1 `routedOpen()` branched on `cfg.recording === "on_demand"`. Phase 2 branches on `cfg.allowPaths`:
- `allowPaths` length 2 → open `CHOOSE` screen.
- `allowPaths` is `["report_now"]` → skip panel, open Path A form (added in Task 5; placeholder for now).
- `allowPaths` is `["record_and_report"]` → skip panel, kick off Path B (call `handleStartFromPanel()`).

Card click handlers (`.phx-replay-choose-report-now`, `.phx-replay-choose-record`) wire to the same path-specific handlers.

- [ ] **Step 1: Add `openChoose` to `renderPanel`'s panel API**

In `priv/static/assets/phoenix_replay.js`, in `renderPanel` after `openError` (line ~602), add:

```javascript
    function openChoose() { setScreen(SCREENS.CHOOSE); showModal(); }
```

Then export it from the return at line ~709:

```javascript
    return {
      root,
      openForm,
      openStart,
      openError,
      openChoose,
      // openPathAForm added in Task 5
      close,
      onStart: (fn) => { onStartClick = fn; },
      onRetry: (fn) => { onRetryClick = fn; },
      onChooseReportNow: (fn) => { onChooseReportNowClick = fn; },
      onChooseRecord: (fn) => { onChooseRecordClick = fn; },
    };
```

- [ ] **Step 2: Wire card click handlers inside `renderPanel`**

After the existing `panel.onStart`/`panel.onRetry` declarations (look for `let onStartClick = () => {}; let onRetryClick = () => {};` around line ~590), add:

```javascript
    let onChooseReportNowClick = () => {};
    let onChooseRecordClick = () => {};
```

After the existing `.phx-replay-cancel` listeners (around line ~666-669), add:

```javascript
    root.querySelector(".phx-replay-choose-report-now").addEventListener("click", () => onChooseReportNowClick());
    root.querySelector(".phx-replay-choose-record").addEventListener("click", () => onChooseRecordClick());
```

- [ ] **Step 3: Rewrite `routedOpen` in `init`**

In `init` (around line ~824), replace:

```javascript
      function routedOpen() {
        if (onDemand && !client.isRecording()) panel.openStart();
        else panel.openForm();
      }
```

with:

```javascript
      // ADR-0006 Phase 2: route based on allow_paths.
      //   both     → two-option CHOOSE screen
      //   only A   → straight to Path A form (no panel-choice friction)
      //   only B   → straight to Path B start (recording immediately)
      function routedOpen() {
        const paths = cfg.allowPaths || ["report_now", "record_and_report"];
        const aOnly = paths.length === 1 && paths[0] === "report_now";
        const bOnly = paths.length === 1 && paths[0] === "record_and_report";
        if (aOnly) return panel.openPathAForm();   // wired in Task 5
        if (bOnly) return handleStartFromPanel();
        panel.openChoose();
      }
```

Note: `panel.openPathAForm` doesn't exist yet — it's added in Task 5. Until then, `aOnly` widgets will throw on click. That's acceptable in this commit because no demo or test currently passes `allow_paths: [:report_now]`.

- [ ] **Step 4: Wire the card click handlers to path actions**

In `init`, after the existing `panel.onStart(handleStartFromPanel); panel.onRetry(handleStartFromPanel);` lines (around line ~885), add:

```javascript
      panel.onChooseReportNow(() => panel.openPathAForm());  // Task 5 will define
      panel.onChooseRecord(() => handleStartFromPanel());
```

- [ ] **Step 5: Syntax check**

Run: `cd ~/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js`

Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(panel): wire CHOOSE screen routing and card click handlers

ADR-0006 Phase 2.2 (partial): routedOpen now branches on cfg.allowPaths
instead of the dropped recording attr. Two paths means CHOOSE screen;
single-path widgets skip directly to that path's UI. Card clicks call
through panel.onChooseReportNow / .onChooseRecord into the init
orchestrator, which routes to Path A's openPathAForm (added in Task 5)
or Path B's handleStartFromPanel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `PATH_A_FORM` screen + `client.reportNow()` method

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (`createClient` → add `reportNow`; `renderPanel` → add screen + form handler)
- Modify: `priv/static/assets/phoenix_replay.css` (banner style)

The Path A form is a single screen: banner ("recent activity will be attached") + textarea + (optional) severity + Send. Severity field is rendered conditionally from Task 6; Task 5 lays the markup with both fields visible and Task 6 adds the gate.

- [ ] **Step 1: Add `reportNow` to `createClient`**

In `priv/static/assets/phoenix_replay.js`, after the existing `report` function in `createClient` (around line ~445), add:

```javascript
    // Path A submit (ADR-0006). Drains the ring buffer client-side and
    // POSTs everything in one shot to /report. No /session handshake;
    // no /events flush; no state transition (we stay :passive).
    // The recorder keeps running so the buffer immediately starts
    // refilling for any subsequent Report Now.
    async function reportNow({ description, severity, metadata = {}, jamLink = null, extras = {} }) {
      const events = buffer.drain();

      const result = await postJson(`${basePath}${cfg.reportPath}`, {
        description,
        severity: severity || cfg.defaultSeverity,
        events,
        metadata,
        jam_link: jamLink,
        extras,
      }, {
        csrfToken,
        csrfHeader: cfg.csrfHeader,
        // No sessionToken on /report — endpoint mints its own session.
      });

      return result;
    }
```

Then export it from the `createClient` return (around line ~497):

```javascript
    return {
      start,
      report,
      reportNow,
      flush,
      flushOnUnload,
      startRecording,
      stopRecording,
      resetRecording,
      isRecording,
      _internals: {
        buffer,
        sessionId: () => null,
        sessionStartedAtMs: () => sessionStartedAtMs,
      },
    };
```

- [ ] **Step 2: Add the `PATH_A_FORM` `<section>`**

In `renderPanel`'s template HTML, append a new section AFTER the existing `.phx-replay-screen--form` `<form>` (after line ~576):

```html
          <form class="phx-replay-screen phx-replay-screen--path-a-form" data-screen="${SCREENS.PATH_A_FORM}" hidden>
            <h2>Report now</h2>
            <p class="phx-replay-path-a-banner">
              <span class="phx-replay-path-a-banner-icon" aria-hidden="true">📨</span>
              The most recent activity from this page will be attached to your report.
            </p>
            <label>
              <span>What happened?</span>
              <textarea name="description" rows="4" required placeholder="Steps to reproduce, what you expected, what actually happened"></textarea>
            </label>
            <label class="phx-replay-severity-field" hidden>
              <span>Severity</span>
              <select name="severity">
                ${cfg.severities.map(s => `<option value="${s}"${s === cfg.defaultSeverity ? " selected" : ""}>${s}</option>`).join("")}
              </select>
            </label>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="submit" class="phx-replay-submit">Send</button>
            </div>
            <div class="phx-replay-status" aria-live="polite"></div>
          </form>
```

The `phx-replay-severity-field` `<label>` is rendered with `hidden` by default. Task 6 will conditionally clear it when `cfg.showSeverity === true`.

- [ ] **Step 3: Add `openPathAForm` and Path A submit handler in `renderPanel`**

After the existing `openForm` / `openStart` / `openError` / `openChoose` helpers (Task 3 + Task 4), add:

```javascript
    function openPathAForm() { setScreen(SCREENS.PATH_A_FORM); showModal(); }
```

Then export it from the panel return (the same return touched in Task 4):

```javascript
    return {
      root,
      openForm,
      openStart,
      openError,
      openChoose,
      openPathAForm,
      close,
      onStart: (fn) => { onStartClick = fn; },
      onRetry: (fn) => { onRetryClick = fn; },
      onChooseReportNow: (fn) => { onChooseReportNowClick = fn; },
      onChooseRecord: (fn) => { onChooseRecordClick = fn; },
      onPathASubmit: (fn) => { onPathASubmitHandler = fn; },
    };
```

Add the handler placeholder (alongside the other `let on...` declarations near line ~590):

```javascript
    let onPathASubmitHandler = async (data) => { throw new Error("Path A submit handler not wired"); };
```

Locate the existing `phx-replay-screen--form` form's submit handler (`form.addEventListener("submit", ...`) at line ~671. **Just below it**, add a parallel handler for the Path A form:

```javascript
    const pathAForm = root.querySelector(".phx-replay-screen--path-a-form");
    const pathAStatus = pathAForm.querySelector(".phx-replay-status");

    pathAForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const data = new FormData(pathAForm);
      pathAStatus.textContent = "Sending…";
      try {
        await onPathASubmitHandler(data);
        pathAStatus.textContent = "Thanks! Your report was submitted.";
        setTimeout(close, 1200);
      } catch (err) {
        pathAStatus.textContent = `Submit failed: ${err.message}`;
      }
    });
```

The `.phx-replay-cancel` button inside the Path A form is already covered by the existing delegated cancel listener at line ~666 (it queries `.phx-replay-cancel` across the whole `root`).

- [ ] **Step 4: Wire the Path A submit handler in `init`**

In `init` after the panel-listener wiring from Task 4 (`panel.onChooseRecord(() => handleStartFromPanel());`), add:

```javascript
      panel.onPathASubmit(async (formData) => {
        await client.reportNow({
          description: formData.get("description"),
          severity: formData.get("severity") || undefined,
          jamLink: formData.get("jam_link") || null,
        });
      });
```

(No addon `beforeSubmit` hooks for Path A in Phase 2 — the only existing addon is audio, scoped to `:on_demand`/Path B. Phase 3 adds the `pill-action` and `review-media` slots; until then, Path A submits with no addon extras.)

- [ ] **Step 5: Append banner CSS**

Append to `priv/static/assets/phoenix_replay.css`:

```css
/* Path A submit form banner — informs the user that recent activity
 * will be attached. Visual weight is intentionally muted: the banner
 * is context, not a CTA.
 */
.phx-replay-path-a-banner {
  margin: 0;
  padding: 0.625rem 0.75rem;
  background: var(--phx-replay-surface-muted);
  border: 1px solid var(--phx-replay-border);
  border-radius: 0.5rem;
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted);
  line-height: 1.4;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.phx-replay-path-a-banner-icon {
  flex: 0 0 auto;
}
```

- [ ] **Step 6: Syntax check**

Run: `cd ~/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js`

Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(panel): Path A submit form + client.reportNow → /report

ADR-0006 Phase 2.2: PATH_A_FORM screen renders banner + textarea +
severity + Send. On submit, the init orchestrator calls
client.reportNow which drains the ring buffer client-side and POSTs
{description, severity, events, metadata, jam_link, extras} to the
Phase 1 /report endpoint in one shot. No /session handshake; no
state transition; the recorder stays running so the buffer refills
for the next Report Now.

Severity field is rendered with hidden by default; Task 6 wires the
show_severity gate. addon beforeSubmit is intentionally not invoked
on Path A in Phase 2 — the only addon today is the audio recorder,
which is scoped to Path B and uses the pill-action slot landing in
Phase 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `show_severity` conditional rendering

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (`renderPanel` — un-hide the severity label when `cfg.showSeverity` is true on both forms)

Both forms (the existing Path B `<form>` at `data-screen="form"` and the new Path A form at `data-screen="path_a_form"`) carry a `.phx-replay-severity-field` label. Default is hidden. When `cfg.showSeverity` is true, un-hide.

- [ ] **Step 1: Mark the legacy form's severity label with the toggle class**

In `renderPanel`'s existing legacy form HTML (around line ~561-566), wrap the severity `<label>`:

```html
            <label class="phx-replay-severity-field" hidden>
              <span>Severity</span>
              <select name="severity">
                ${cfg.severities.map(s => `<option value="${s}"${s === cfg.defaultSeverity ? " selected" : ""}>${s}</option>`).join("")}
              </select>
            </label>
```

(was previously a bare `<label>` without the class or `hidden`).

- [ ] **Step 2: Un-hide the severity label(s) when `cfg.showSeverity` is true**

After `mountEl.appendChild(root);` (around line ~580) and the existing query selectors (`const modal = root.querySelector(...)` etc.), add:

```javascript
    if (cfg.showSeverity) {
      root.querySelectorAll(".phx-replay-severity-field").forEach((el) => {
        el.removeAttribute("hidden");
      });
    }
```

This runs once at panel mount and toggles BOTH forms' severity labels in lock-step.

- [ ] **Step 3: Syntax check**

Run: `cd ~/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js`

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(panel): show_severity gates the severity field on both forms

ADR-0006 D5: severity is a triage decision the receiver makes; end-user
widgets shouldn't expose it by default. Severity labels on Path A
(PATH_A_FORM) and Path B (FORM) are now both wrapped in the
.phx-replay-severity-field class and rendered with hidden. When
cfg.showSeverity is true (host opt-in), both labels lose hidden in
lock-step so the field appears on whichever form the user reaches.

When show_severity is false the form's submit FormData has no severity
key, so client.reportNow / client.report fall through to
cfg.defaultSeverity. The Feedback resource accepts that value already.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Public JS API — `openPanel`, `reportNow`, `recordAndReport`

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` (`PhoenixReplay` global object at line ~811)

Spec D4 names three new public methods. `openPanel()` is the canonical name for what `open()` does today (open the panel, route per allow_paths). `reportNow()` and `recordAndReport()` skip the panel entirely.

- [ ] **Step 1: Add `openPanel`, `reportNow`, `recordAndReport` to the public API**

In the `PhoenixReplay` global at line ~811-996, add three new methods. Locate the existing `open()` method (line ~918-921) and insert AFTER it:

```javascript
    // Open the panel and route per the widget's allow_paths.
    //   both → CHOOSE screen
    //   single-path → that path's UI directly (no two-option panel)
    // Equivalent to a `[data-phoenix-replay-trigger]` click; provided as
    // a function so hosts can wire keyboard shortcuts, dropdown items,
    // or programmatic flows.
    openPanel() {
      const inst = firstInstance();
      if (inst) inst.routedOpen();
    },

    // Skip the entry panel and open Path A's submit form directly.
    // Useful for hosts that want to label a header link "Report a bug"
    // and bypass the two-option choice.
    reportNow() {
      const inst = firstInstance();
      if (inst) inst.panel.openPathAForm();
    },

    // Skip the entry panel and start Path B (Record and report)
    // immediately — opens the session, starts rrweb, swaps to the pill.
    // Useful for header-button entry points that always mean "I want
    // to record".
    recordAndReport() {
      const inst = firstInstance();
      return inst ? inst.startAndSync() : Promise.resolve();
    },
```

Leave `open()` unchanged — it stays as an alias for backwards compatibility with hosts (and the existing `[data-phoenix-replay-trigger]` delegated listener already routes through `inst.routedOpen()`).

- [ ] **Step 2: Syntax check**

Run: `cd ~/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js`

Expected: no output, exit 0.

- [ ] **Step 3: Run mix test (Elixir suite still green — JS changes don't affect it)**

Run: `cd ~/Dev/phoenix_replay && mix test`

Expected: green.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(api): public openPanel/reportNow/recordAndReport JS methods

ADR-0006 D4: hosts can wire entry points beyond the floating toggle.
openPanel routes through the same logic as a data-phoenix-replay-trigger
click (CHOOSE screen, or single-path skip per allow_paths). reportNow
and recordAndReport bypass the panel entirely — useful for "Report a
bug" header links or "Record this" CTAs that should commit a path
without the two-option screen.

The legacy open() alias is retained for backwards compatibility — the
delegated [data-phoenix-replay-trigger] listener already routes through
inst.routedOpen(), so existing hosts pick up the new behavior without
code changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Demo updates — drop `recording={...}` from the three demo pages

**Files:**
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/continuous.html.heex`
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex`
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex`

The `recording` attr no longer exists. Phoenix's component compiler raises on unknown attrs — these three pages will fail to render until the attr is removed.

- [ ] **Step 1: Drop `recording={:continuous}` from `continuous.html.heex`**

In `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/continuous.html.heex` at line 29, delete the line:

```heex
    recording={:continuous}
```

Leave surrounding attrs intact.

- [ ] **Step 2: Drop `recording={:on_demand}` from `on_demand_float.html.heex`**

In `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex` at line 25, delete the line:

```heex
    recording={:on_demand}
```

- [ ] **Step 3: Drop `recording={:on_demand}` from `on_demand_headless.html.heex`**

In `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/controllers/demo_html/on_demand_headless.html.heex` at line 53, delete the line:

```heex
    recording={:on_demand}
```

- [ ] **Step 4: Commit (in the demo repo)**

The demo isn't tracked by git in this CWD per the project memory ("This directory is a runtime sandbox — a throwaway Phoenix + Tidewave host where we exercise two companion libraries during development. The demo itself is intentionally untracked by git.") — verify before attempting `git commit`:

```bash
cd ~/Dev/ash_feedback_demo && git status
```

If the demo IS a git repo, commit:

```bash
cd ~/Dev/ash_feedback_demo && git add lib/ash_feedback_demo_web/controllers/demo_html/ && git commit -m "demo: drop recording={...} attr (ADR-0006 Phase 2)"
```

If the demo is NOT a git repo (untracked sandbox per CLAUDE.md), skip the commit and mention the change in the Phase 2 plan completion note.

---

## Task 9: Cross-repo deps refresh + browser smoke matrix

**Files:**
- Touch: `~/Dev/ash_feedback_demo/deps/phoenix_replay/...` (cp from canonical)
- Touch: `~/Dev/ash_feedback_demo/_build/dev/lib/phoenix_replay/ebin/...` (force recompile)

The demo runs against `deps/phoenix_replay` not the canonical repo. Per CLAUDE.md: copy → `mix deps.compile phoenix_replay --force` → restart. Skipping the `--force` is the stale-beam trap (memory `feedback_deps_force_recompile.md`).

- [ ] **Step 1: Sync canonical edits into demo's deps**

```bash
cp ~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/lib/phoenix_replay/ui/components.ex
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.css \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.css
```

- [ ] **Step 2: Force recompile and restart**

```bash
cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force
```

Then restart via Tidewave (call `mcp__Tidewave-Web__restart_app_server` with `reason: "deps_changed"`). If running this plan via subagent that doesn't have Tidewave access, ask the user to restart the demo server manually before proceeding.

- [ ] **Step 3: Smoke matrix — browser at http://localhost:4006**

Open Chrome DevTools (Network + Console). Walk through this 8-row matrix; check off each as PASS or note the failure. None of these should require code changes — failures indicate a Task 1-7 bug.

| # | Page | Action | Expected |
|---|---|---|---|
| 1 | `/demo/continuous` | Mount page | No `/session`, `/events` POSTs in Network. `data-phoenix-replay` attrs include `data-show-severity="false"`, `data-allow-paths="report_now,record_and_report"`, `data-buffer-window-seconds="60"`. No `data-recording`. |
| 2 | Same | Click toggle | CHOOSE screen renders with two cards: "Report now" and "Record and report". |
| 3 | Same | Click "Report now" | PATH_A_FORM renders: banner ("recent activity will be attached"), textarea, NO severity field (`hidden`), Send button. |
| 4 | Same | Type description, click Send | Single `POST /report` fires with `{description, severity:"medium", events:[...rrweb events...], ...}`. Status text becomes "Thanks! Your report was submitted." Modal closes after ~1.2s. |
| 5 | Same | Verify in admin | At `/admin/feedback`, the new feedback row appears with the description; admin replay panel renders the captured events. |
| 6 | `/demo/on-demand-float` | Click toggle → "Record and report" | Existing Path B flow: pill appears, `/session` fires, `/events` flushes every 5s. Stop → existing form (`SCREENS.FORM`) opens. Send → existing `/submit` succeeds. |
| 7 | `/demo/continuous` | Open DevTools console; run `window.PhoenixReplay.recordAndReport()` | Path B starts; pill appears (toggle hides). `Network` shows `/session` POST. |
| 8 | Same | Run `window.PhoenixReplay.reportNow()` then click Send | PATH_A_FORM opens directly (CHOOSE skipped). Submit → `/report` POST. |

If row 4 fails with a 422 inspecting a changeset — that's F1 leaking. Phase 2 plan deliberately doesn't fix F1; mark it for the Phase 2b hardening commit.

If any row 1-3 fails (data attrs missing or panel doesn't render), inspect with `document.querySelector("[data-phoenix-replay]").dataset` and the `phoenix_replay.js` line that should have set the corresponding screen.

- [ ] **Step 4: If smoke is green, proceed to Task 10. If smoke fails, fix and re-run before committing further.**

---

## Task 10: CHANGELOG + finishing-a-development-branch

**Files:**
- Modify: `CHANGELOG.md` (append a Phase 2 block under `[Unreleased]`)

- [ ] **Step 1: Add a Phase 2 entry to `CHANGELOG.md`**

In `~/Dev/phoenix_replay/CHANGELOG.md` under `## [Unreleased]`, immediately AFTER the existing `### ADR-0006 Phase 1` block, insert:

```markdown
### ADR-0006 Phase 2 — Two-option entry panel + Path A UX (2026-04-25)

The `<.phoenix_replay_widget>` `recording` attr is **removed** (ADR-0006
Q-F). Hosts that previously passed `recording={:continuous}` or
`recording={:on_demand}` will see Phoenix's compile-time error for an
unknown attr — drop the attr; the new model decides path per-report
based on user click rather than host compile-time config.

Three new attrs replace it:

- `show_severity` (boolean, default `false`) — gate the Low/Medium/High
  severity field on both submit forms. Default off because end users
  aren't equipped to triage their own reports; flip on for QA-internal
  portals.
- `allow_paths` (list of atoms, default `[:report_now,
  :record_and_report]`) — restrict which paths the entry panel offers.
  Single-path widgets skip the two-option panel and go straight to
  that path's UI.
- `buffer_window_seconds` (integer, default `60`) — sliding ring buffer
  window in seconds; tune for memory or capture-window needs.

Panel behavior:

- Clicking the toggle (or any `[data-phoenix-replay-trigger]`, or
  calling `window.PhoenixReplay.openPanel()`) opens a new CHOOSE screen
  with two equal-weight cards: "Report now" (Path A — drains the ring
  buffer to `/report` in one POST) and "Record and report" (Path B —
  starts an `:active` session and shows the pill, identical to the old
  `:on_demand` flow).
- `allow_paths: [:report_now]` skips CHOOSE and opens the Path A form
  directly. `allow_paths: [:record_and_report]` skips CHOOSE and starts
  recording immediately.

New JS API surface on `window.PhoenixReplay`:

- `openPanel()` — opens the panel and routes per `allow_paths` (CHOOSE
  or single-path skip). Equivalent to a trigger click.
- `reportNow()` — opens the Path A form directly.
- `recordAndReport()` — kicks off Path B (session + pill) directly.
- `client.reportNow({description, severity, metadata, jamLink, extras})`
  — internal client method that drains the ring buffer and POSTs to
  `/report` in a single request. Public surface is the wrapper above.

The `open()` global is preserved as a backwards-compat alias for
`openPanel()` so existing `[data-phoenix-replay-trigger]` wiring keeps
working unchanged.

The `:continuous`-widget Send button is **restored** end-to-end via
this Phase 2: trigger click → CHOOSE → Report now → POST `/report`
succeeds and a Feedback row lands in admin. The Phase 1 interim
regression is closed.

The mode-aware addon `modes:["on_demand"]` filter shipped in
2026-04-25 is preserved via a transitional shim that maps it to
`allow_paths`-based mounting (`"on_demand"` mounts when
`allow_paths` includes `:record_and_report`). ADR-0006 Phase 4
will rename `modes` to `paths` directly.

Smoke verified in Chrome on the ash_feedback_demo continuous +
on-demand-float + on-demand-headless pages — see Task 9 smoke matrix
in `docs/superpowers/plans/2026-04-25-unified-entry-phase-2.md`.

**Out of scope, deferred to Phase 2b**: F1 (changeset leak in /report
500/422 responses), F3 (body-size cap on /report), F4 (rate limit on
/report), F9 (metadata merge order audit). All are pre-existing issues
in the Phase 1 controller that real hosts will hit before pre-prod
shake-out.

**Out of scope, deferred to Phase 3**: pill `pill-action` slot,
review step (`review-media` slot, mini rrweb-player, Re-record),
addon `paths: [...]` rename. Audio addon migration from `form-top`
to the new slots happens alongside Phase 3.
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/phoenix_replay && git add CHANGELOG.md && git commit -m "$(cat <<'EOF'
docs(changelog): ADR-0006 Phase 2 — two-option entry panel + Path A UX

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Run finishing-a-development-branch (manual)**

Per the user's standing workflow, after a phase ships invoke the
`superpowers:finishing-a-development-branch` skill on this branch.
This is a hand-off step — do not pre-emptively merge; let the skill
walk through review/merge/cleanup.

```
/superpowers:finishing-a-development-branch
```

(Or invoke `Skill` with `superpowers:finishing-a-development-branch`.)

---

## Risks (from the spec, surfaced for the implementer)

- **Severity-field default-off may surprise hosts who relied on it always being present.** The CHANGELOG explicitly calls this out. The Feedback resource accepts `severity: nil` so submitted rows don't break; admin can backfill via triage actions.
- **`allow_paths: [:report_now]` widgets that hit a body-size limit on `/report`.** F3 is deliberately out of scope; surfaces as a Phoenix `Plug.Parsers` 413 with no client-side error UI yet. Manual smoke at 60s buffer should stay well under the 8 MB default. If a host reports failures here, prioritize F3 in Phase 2b.
- **The transitional `modes` → `allow_paths` shim is a temporary symbol.** Phase 3+ will introduce the canonical `paths` filter. Any addon registered today with `modes: ["on_demand"]` should be migrated alongside Phase 3, not in this phase.
- **The legacy `<form data-screen="form">` (Path B describe step) is unchanged.** Phase 3 will replace it with a Review-step + Describe-step pair. Tests that reference `data-screen="form"` will need updating then; Phase 2 doesn't touch them.

## Definition of Done

- [ ] All 10 task commits land on `main`.
- [ ] `mix test` green (full suite, not just the components test).
- [ ] `node test/js/ring_buffer_test.js` prints `OK ring_buffer_test (4 cases)`.
- [ ] `node --check priv/static/assets/phoenix_replay.js` exits 0.
- [ ] Task 9 smoke matrix rows 1-8 all PASS in browser on `localhost:4006`.
- [ ] CHANGELOG entry merged.
- [ ] Demo's three pages updated; if demo is a git repo, that change committed too.

Phase 2b (F1 + F3 + F4 + F9 server hardening on `/report`) and Phase 3
(pill `pill-action` slot + review step + addon `paths` rename) start
from this Definition of Done.

---

## Self-Review

After completing all 10 tasks above, run this checklist:

**1. Spec coverage** — map each spec § Phasing item to a task:

| Spec item | Task |
|---|---|
| 2.1 Panel template (two-option + card click handlers) | Task 3 + Task 4 |
| 2.2 Path A handler (banner + textarea + Send → /report) | Task 5 |
| 2.3 `show_severity` + `allow_paths` + `buffer_window_seconds` attrs | Task 1 (+ Task 6 for show_severity wiring) |
| 2.4 JS API: openPanel, reportNow, recordAndReport | Task 7 |
| 2.5 Tests: component test for new attrs | Task 1 |
| 2.6 CHANGELOG, README guide update, smoke | Task 9 + Task 10 |

README guide update is intentionally folded into the CHANGELOG entry
in Task 10; if the maintainer wants a standalone migration guide
(e.g., `guides/migrating-from-recording-attr.md`), that's an optional
follow-on commit — not blocking.

**2. Placeholder scan** — search for forbidden patterns:
- "TBD" / "TODO" / "implement later" — none.
- "Add appropriate error handling" — none. Where errors are gated, the gate is explicit (e.g., "the test will fail with NoFunctionClause" rather than "handle errors").
- "Similar to Task N" — none. Each task repeats the relevant code.
- Steps that describe *what* without *how* — code blocks are present in every code-changing step.

**3. Type / name consistency**:
- `client.reportNow` — defined in Task 5 step 1, called in Task 5 step 4 (`init` wiring). Same name.
- `panel.openPathAForm` — defined in Task 5 step 3, called in Task 4 step 3 + Task 4 step 4 (`onChooseReportNow` handler). Same name.
- `cfg.allowPaths` — populated by Task 2 step 2 from `data-allow-paths`; read by Task 4 step 3's `routedOpen` and by Task 2 step 3's `modeMatchesAllowPaths` shim. Same name throughout.
- `cfg.showSeverity` — populated by Task 2 step 2; read by Task 6 step 2's un-hide loop. Same name.
- `cfg.reportPath` — added to DEFAULTS in Task 2 step 1; used by Task 5 step 1's `client.reportNow` POST. Same name.
- SCREENS.PATH_A_FORM — defined in Task 3 step 1; referenced by markup in Task 5 step 2 (`data-screen="${SCREENS.PATH_A_FORM}"`). Same name.

If implementation surfaces a real divergence (e.g., a method name was already taken in JS internals), fix in-line and update this checklist before re-running smoke.
