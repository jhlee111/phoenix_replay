# ADR-0006 Phase 3 — Pill Slot + Review Step + Slot Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Path B's in-flight pill-action slot + the post-recording review step (mini rrweb-player + review-media slot + Re-record + Continue) + the describe step split, plus the slot mount/unmount lifecycle that Phase 4 (and the ash_feedback audio addon migration) builds on. Rename the `registerPanelAddon` filter from `modes:` to `paths:` so the legacy transitional shim Task 2 added in Phase 2 can be retired.

**Architecture:** The pill template gains a `<div data-slot="pill-action">` that addons mount into when the pill appears (transition to `:active`) and unmount from when the pill disappears (Stop, panel close, Re-record). A new `SCREENS.REVIEW` screen is inserted between Stop and the existing legacy `SCREENS.FORM` (now repurposed as the Path B "describe" step). The review screen embeds an rrweb-player instance fed from a new `client.takeReviewEvents()` source (events are accumulated client-side during `:active` flushes into a `reviewEvents` array — no new server endpoint needed). Slot lifecycle is implemented via mount/unmount tracking keyed on slot DOM presence: when a screen containing a slot becomes visible, mount runs; when it becomes hidden (or the panel closes), the cleanup function returned by mount (if any) runs. Existing addons that return the legacy `{beforeSubmit, onPanelClose}` object continue to work via type-check. The `paths:` filter replaces the `modes:` filter; Phase 2's transitional shim is removed.

**Tech Stack:** Vanilla ES2020 + Phoenix 1.8 + ExUnit. rrweb-player 2.0 UMD (already loaded by `phoenix_replay_admin_assets/1` for admin; Phase 3 widget consumers don't need to load it for Path B review — the widget itself emits the script tag for Path B-capable mounts). No new dependencies.

---

## Phase 2 baseline (do not re-implement)

Phase 2 shipped on `main` (`016e540..9763642`). Verify before starting:

- `priv/static/assets/phoenix_replay.js`:
  - `SCREENS = { CHOOSE, IDLE_START, ERROR, FORM, PATH_A_FORM }`.
  - `renderPanel` template includes CHOOSE / IDLE_START / ERROR / FORM (legacy) / PATH_A_FORM sections.
  - `cfg.allowPaths` parsing in `autoMount`; `routedOpen` branches on `allowPaths`.
  - `client.reportNow` + `buffer.snapshot()` + drain-on-success.
  - Public API: `openPanel`, `reportNow`, `recordAndReport` (+ legacy `open` alias).
  - Transitional `modeMatchesAllowPaths` shim mapping legacy `modes:["on_demand"|"continuous"]` to `allowPaths`.
- `lib/phoenix_replay/ui/components.ex`:
  - Widget attrs: `show_severity`, `allow_paths`, `buffer_window_seconds` (no `recording`).
  - `<.replay_player>` admin component (unchanged from earlier phases — Phase 3 reuses its underlying rrweb-player instantiation pattern but in pure JS, not via the Phoenix component).
- `test/js/ring_buffer_test.js` — 5 cases including `snapshot()`.

If `git log --oneline | grep "Phase 2"` shows `47b216d docs(changelog): ADR-0006 Phase 2`, you're set.

---

## File structure

Phase 3 touches the panel JS (primary), CSS (pill + review-step styling), test files, and documentation. No Elixir-side changes.

| Path | Responsibility | Why |
|---|---|---|
| `priv/static/assets/phoenix_replay.js` | `client.takeReviewEvents()` + `reviewEvents` accumulator, pill `data-slot="pill-action"`, new `SCREENS.REVIEW` screen with mini rrweb-player init + Re-record + Continue, `panel.openReview()` helper, `init` orchestrator wires Stop → review, slot mount/unmount lifecycle + `paths:` filter rename. | Single-file widget. |
| `priv/static/assets/phoenix_replay.css` | `.phx-replay-pill-action-slot` styling, `.phx-replay-screen--review` layout (rrweb-player container + media slot + actions), `.phx-replay-recording-meta` line for Path B describe step. | Library styling. |
| `lib/phoenix_replay/ui/components.ex` | Add a single `attr :rrweb_player_src` (default the existing CDN URL) + emit `<script :if={@allow_paths_includes_path_b}>` so Path B-capable widgets load rrweb-player. Path A-only widgets don't need it. | Widget surfaces the player URL via the same pattern as the existing `rrweb_src` etc. |
| `test/phoenix_replay/ui/components_test.exs` | Test for new `rrweb_player_src` attr + conditional emission based on allow_paths. | Existing test module. |
| `CHANGELOG.md` | Phase 3 entry under `[Unreleased]`. | Existing changelog. |
| `priv/static/assets/phoenix_replay.css` | (already listed above) | |

No new files. The widget JS file gains ~150-200 lines spread across slot-lifecycle helpers + REVIEW screen + pill template extension.

The ash_feedback audio-addon migration is a **separate plan** (`~/Dev/ash_feedback/docs/superpowers/plans/2026-04-25-audio-addon-pill-relocation.md` — not yet written; companion spec `~/Dev/ash_feedback/docs/superpowers/specs/2026-04-25-audio-addon-pill-relocation-design.md` is Draft and gates on this Phase 3 landing). Do NOT touch ash_feedback in this plan.

---

## Self-Review After Plan Authoring

Run the Self-Review at the end of this document before handing off.

---

## Task 1: Add `client.takeReviewEvents()` + reviewEvents accumulator

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — `createClient` (around line 234-558)
- Modify: `test/js/ring_buffer_test.js` — add a smoke for the accumulator pattern (the function lives in createClient, not the ring buffer, but the smoke harness is the only existing JS test substrate)

The Path B review step needs the events that were captured during the active session. Today they're flushed to the server and removed from the client. We need a parallel accumulator so the mini rrweb-player can consume them without a new server endpoint.

- [ ] **Step 1: Add `reviewEvents` array + accumulation in `flush()`**

In `priv/static/assets/phoenix_replay.js` `createClient`, find the existing `flush()` function (around line 309-336):

```javascript
    async function flush() {
      if (state !== "active") return;
      const events = buffer.drain();
      if (events.length === 0) return;

      const batches = chunk(events, cfg.maxEventsPerBatch);
      for (const batch of batches) {
        ...
      }
    }
```

Add a `reviewEvents` accumulator at the top of `createClient` (alongside other client state — near `let state = "passive";`):

```javascript
    // Accumulator for events seen during the current :active session.
    // Path B's review step (Phase 3) feeds these to a mini rrweb-player
    // so the user can preview the recording before Send. Cleared on
    // session start (transition into :active) and on takeReviewEvents().
    // Memory bound: a typical Path B session (30s–2min) is ~100KB–1MB.
    // Hosts that need bigger windows should expect proportionally more
    // memory; the buffer is naturally bounded by session length.
    let reviewEvents = [];
```

In `flush()`, after the successful POST per batch, push the events into `reviewEvents` so Stop time has them available. The change: split the local `events` variable into batches, post each, AND push into `reviewEvents` after success:

```javascript
    async function flush() {
      if (state !== "active") return;
      const events = buffer.drain();
      if (events.length === 0) return;

      const batches = chunk(events, cfg.maxEventsPerBatch);
      for (const batch of batches) {
        try {
          await postJson(`${basePath}${cfg.eventsPath}`, { seq, events: batch }, {
            csrfToken,
            csrfHeader: cfg.csrfHeader,
            sessionToken,
            tokenHeader: cfg.tokenHeader,
          });
          seq += 1;
          // Mirror to review accumulator only on flush success — failed
          // batches are dropped from the local accumulator the same way
          // they're dropped from the server stream (the next flush will
          // re-attempt with fresh events).
          for (const evt of batch) reviewEvents.push(evt);
        } catch (err) {
          if (err instanceof PhoenixReplayError && (err.status === 410 || err.status === 401)) {
            sessionToken = null;
            sessionStartedAtMs = null;
            await ensureSession().catch(() => {});
            return;
          }
          console.warn("[PhoenixReplay] flush failed:", err.message);
          return;
        }
      }
    }
```

In `startRecording()` (around line 370-385), clear `reviewEvents` at the top so each new active session starts fresh:

```javascript
    async function startRecording() {
      if (state === "active") return;
      sessionToken = null;
      sessionStartedAtMs = null;
      seq = 0;
      buffer.drain();
      reviewEvents = [];   // NEW: clear review accumulator
      await ensureSession();
      state = "active";
      storageWrite(STORAGE_KEYS.RECORDING, "active");
      scheduleFlush();
    }
```

In `resetRecording()` (around line 402-408), the `wasActive` branch already discards via `transitionToPassive()` then restarts. Clear `reviewEvents` on transition to passive (a fresh session deserves a fresh accumulator):

In `transitionToPassive()` (around line 360-368), add:

```javascript
    function transitionToPassive() {
      cancelFlushTimer();
      state = "passive";
      sessionToken = null;
      sessionStartedAtMs = null;
      seq = 0;
      reviewEvents = [];   // NEW: review accumulator only meaningful for active sessions
      storageClear(STORAGE_KEYS.TOKEN);
      storageClear(STORAGE_KEYS.RECORDING);
    }
```

(Note: `stopRecording` does NOT clear `reviewEvents` — Stop intentionally keeps the events alive for the review step that opens immediately after.)

- [ ] **Step 2: Add `client.takeReviewEvents()` accessor**

Below `flushOnUnload` (around line 495-499), add:

```javascript
    // Path B review step (Phase 3). Returns the events captured during
    // the just-stopped :active session and clears the internal
    // accumulator. Called once when the review screen opens; subsequent
    // calls return [] until a new active session starts. Re-record
    // (via resetRecording → startRecording) clears + restarts.
    function takeReviewEvents() {
      const out = reviewEvents.slice();
      reviewEvents = [];
      return out;
    }
```

Then add `takeReviewEvents` to the `createClient` return object (currently around line 540-558):

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
      takeReviewEvents,
      _internals: { ... },
    };
```

(Insert `takeReviewEvents` between `isRecording` and `_internals`. Keep `_internals` last.)

- [ ] **Step 3: Verify suite still passes**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && node test/js/ring_buffer_test.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 4: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(js): client.takeReviewEvents() + reviewEvents accumulator

ADR-0006 Phase 3 prep: Path B's review step (landing in Task 4) needs
the events captured during the just-stopped :active session so the
mini rrweb-player can preview them. Accumulate flushed events into a
client-side reviewEvents array; expose via client.takeReviewEvents()
which returns + clears.

The accumulator clears on every transition into :active (startRecording)
and on every transition to :passive teardown (transitionToPassive).
stopRecording is the one path that intentionally keeps the accumulator
alive — Stop transitions to :passive without clearing, so the review
step opening immediately after has access to the events.

Memory: bounded by session length. Typical Path B (30s-2min) is
~100KB-1MB. Path A widgets never accumulate (passive flow doesn't
flush) so the cost is zero for Path A-only hosts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Caveat:** the description above says `transitionToPassive` clears the accumulator, but `stopRecording` does NOT call `transitionToPassive` (it does partial teardown). Re-read both functions to confirm the intent: `stopRecording` should keep `reviewEvents` populated; `transitionToPassive` (called by `report` and `resetRecording`) should clear them. Audit during commit.

---

## Task 2: Pill template — add `pill-action` slot + record-time display

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — `renderPill` (around line 897-914)
- Modify: `priv/static/assets/phoenix_replay.css` — append slot styling

The pill currently shows a dot, "Recording…" label, and Stop button. Phase 3 adds a `pill-action` slot for addons (audio mic toggle being the first consumer) and a recording time display.

- [ ] **Step 1: Extend pill markup**

In `priv/static/assets/phoenix_replay.js` `renderPill` (around line 897-914), replace the function body:

```javascript
  function renderPill(widgetRoot, cfg, onStop) {
    const pill = document.createElement("div");
    pill.className = `phx-replay-pill ${positionClass("pill", cfg)}`;
    pill.setAttribute("role", "status");
    pill.setAttribute("aria-live", "polite");
    pill.hidden = true;
    pill.innerHTML = `
      <span class="phx-replay-pill-dot" aria-hidden="true"></span>
      <span class="phx-replay-pill-label">Recording</span>
      <span class="phx-replay-pill-time" aria-live="off">0:00</span>
      <div class="phx-replay-pill-action-slot" data-slot="pill-action"></div>
      <button type="button" class="phx-replay-pill-stop">Stop</button>
    `;
    widgetRoot.appendChild(pill);
    pill.querySelector(".phx-replay-pill-stop").addEventListener("click", onStop);

    let tickHandle = null;
    let startedAtMs = null;
    const timeEl = pill.querySelector(".phx-replay-pill-time");

    function tick() {
      if (!startedAtMs) return;
      const elapsed = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
      const m = Math.floor(elapsed / 60);
      const s = elapsed % 60;
      timeEl.textContent = `${m}:${s.toString().padStart(2, "0")}`;
    }

    return {
      show: (atMs) => {
        pill.hidden = false;
        startedAtMs = atMs || Date.now();
        tick();
        if (tickHandle) clearInterval(tickHandle);
        tickHandle = setInterval(tick, 1000);
      },
      hide: () => {
        pill.hidden = true;
        if (tickHandle) { clearInterval(tickHandle); tickHandle = null; }
        startedAtMs = null;
        timeEl.textContent = "0:00";
      },
      // Slot DOM exposed so the orchestrator can mount/unmount addons
      // tied to the pill's lifecycle.
      slotEl: pill.querySelector(".phx-replay-pill-action-slot"),
      // Read-only: when the active session started, used by addons that
      // need a stable reference (e.g., audio_start_offset_ms calc).
      startedAtMs: () => startedAtMs,
    };
  }
```

The `tick`/`tickHandle` machinery is the new recording-time display. The `slotEl` + `startedAtMs` accessors are how the slot-lifecycle code (Task 5) introspects the pill.

- [ ] **Step 2: Append CSS for the slot + time display**

In `priv/static/assets/phoenix_replay.css`, append at the end of the file:

```css
/* Pill recording-time display + addon action slot. The slot is a
 * thin horizontal container between the time display and the Stop
 * button; addons mount their controls (e.g., audio mic toggle) here.
 */
.phx-replay-pill-time {
  font-variant-numeric: tabular-nums;
  font-size: 0.75rem;
  color: var(--phx-replay-text-muted);
  min-width: 2.5rem;
}

.phx-replay-pill-action-slot {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  /* Pill grows horizontally as needed; no fixed width.
   * Empty slot is invisible (no padding/border) so the pill keeps
   * its compact size when no addon mounts. */
}

.phx-replay-pill-action-slot:empty {
  display: none;
}
```

- [ ] **Step 3: Update `init`'s `syncRecordingUI` + Stop handler to plumb start time**

In `init` (around line 1004-1008), the `syncRecordingUI` currently calls `pill.show()`/`pill.hide()` without args. Update it to pass the session start time:

```javascript
      function syncRecordingUI() {
        const recording = client.isRecording();
        if (pill) {
          if (recording) {
            pill.show(client._internals.sessionStartedAtMs?.() ?? Date.now());
          } else {
            pill.hide();
          }
        }
        if (toggle && pill) recording ? toggle.hide() : toggle.show();
      }
```

- [ ] **Step 4: Verify**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 5: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(pill): add pill-action slot + recording-time display

ADR-0006 Phase 3 Task 2: the pill grows a data-slot="pill-action" div
between the time display and the Stop button. Addons (audio mic
toggle in the ash_feedback companion spec) mount their controls
here. Empty-slot CSS keeps the pill compact when no addon mounts.

Recording-time display ticks once per second from a host-injected
sessionStartedAtMs. The pill exposes slotEl and startedAtMs accessors
for the orchestrator's slot-lifecycle (Task 5) and for addons that
need the active session's start moment (e.g., audio_start_offset_ms).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: REVIEW screen template + CSS

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — `SCREENS` const, `renderPanel` template, screen-helper cluster
- Modify: `priv/static/assets/phoenix_replay.css` — append review-screen styling

Add the new REVIEW screen markup. NO behavior wiring yet — Tasks 4 + 5 wire the rrweb-player init and the Re-record / Continue handlers.

- [ ] **Step 1: Add REVIEW to SCREENS**

In `priv/static/assets/phoenix_replay.js`, find the SCREENS const (around line 49):

```javascript
  const SCREENS = {
    CHOOSE: "choose",
    IDLE_START: "idle_start",
    ERROR: "error",
    FORM: "form",
    PATH_A_FORM: "path_a_form",
  };
```

Replace with:

```javascript
  const SCREENS = {
    CHOOSE: "choose",
    IDLE_START: "idle_start",
    ERROR: "error",
    FORM: "form",                 // Path B describe step (post-review)
    PATH_A_FORM: "path_a_form",   // Path A single-step submit
    REVIEW: "review",             // Path B post-recording review (mini-player + Re-record + Continue)
  };
```

- [ ] **Step 2: Add REVIEW `<section>` to renderPanel template**

Inside `renderPanel`'s template literal, BEFORE the existing `<form data-screen="${SCREENS.FORM}">` (the legacy form, around line 619), insert the new REVIEW section:

```html
          <section class="phx-replay-screen phx-replay-screen--review" data-screen="${SCREENS.REVIEW}" hidden>
            <h2>Review your recording</h2>
            <p class="phx-replay-screen-lede">Preview the playback below; Continue to add a description, or Re-record to start over.</p>
            <div class="phx-replay-review-player" data-phx-replay-mini-player></div>
            <div class="phx-replay-panel-addons" data-slot="review-media"></div>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="button" class="phx-replay-rerecord">Re-record</button>
              <button type="button" class="phx-replay-continue">Continue</button>
            </div>
          </section>
```

The `data-phx-replay-mini-player` div is where Task 4 instantiates rrweb-player. The `data-slot="review-media"` div is where addons (audio playback) mount per the spec D6.

- [ ] **Step 3: Append CSS for the review screen**

In `priv/static/assets/phoenix_replay.css`, append:

```css
/* Path B review step — post-recording preview before the user types
 * a description. Mini rrweb-player + a media slot for addons (e.g.,
 * audio playback). Re-record discards the events and starts fresh;
 * Continue advances to the describe step (legacy FORM screen).
 */
.phx-replay-review-player {
  width: 100%;
  height: 16rem;
  border: 1px solid var(--phx-replay-border);
  border-radius: 0.5rem;
  overflow: hidden;
  background: var(--phx-replay-surface-muted);
}

.phx-replay-review-player:empty::before {
  content: "Loading playback…";
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted);
}

.phx-replay-rerecord {
  background: var(--phx-replay-surface-muted);
  color: var(--phx-replay-text);
  border-color: var(--phx-replay-border);
  padding: 0.5rem 0.875rem;
  border-radius: 0.5rem;
  border: 1px solid;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
}

.phx-replay-rerecord:hover {
  background: var(--phx-replay-surface);
  border-color: var(--phx-replay-primary);
}

.phx-replay-continue {
  background: var(--phx-replay-primary);
  color: #fff;
  border-color: var(--phx-replay-primary);
  padding: 0.5rem 0.875rem;
  border-radius: 0.5rem;
  border: 1px solid;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
}

.phx-replay-continue:hover {
  background: var(--phx-replay-primary-hover);
}

/* Mini-player rrweb-player sizing override — rrweb-player's UMD bundle
 * applies its own width/height; force the wrapper to constrain inside
 * the modal (max-height clamp prevents oversized recordings from
 * blowing the panel out). */
.phx-replay-review-player .replayer-wrapper {
  width: 100% !important;
  height: 100% !important;
  max-height: 16rem;
}
```

- [ ] **Step 4: Add `openReview` helper in renderPanel**

In `renderPanel` (around the existing helper cluster `openForm` / `openStart` / `openError` / `openChoose` / `openPathAForm` at lines 701-709), add:

```javascript
    function openReview() { setScreen(SCREENS.REVIEW); showModal(); }
```

Then add to the `renderPanel` return object (around line 859-872) BEFORE `close`:

```javascript
    return {
      root,
      openForm,
      openStart,
      openError,
      openChoose,
      openPathAForm,
      openReview,
      close,
      onStart: (fn) => { onStartClick = fn; },
      onRetry: (fn) => { onRetryClick = fn; },
      onChooseReportNow: (fn) => { onChooseReportNowClick = fn; },
      onChooseRecord: (fn) => { onChooseRecordClick = fn; },
      onPathASubmit: (fn) => { onPathASubmitHandler = fn; },
      onReRecord: (fn) => { onReRecordClick = fn; },
      onContinue: (fn) => { onContinueClick = fn; },
    };
```

(Add the two new setter callbacks AFTER `onPathASubmit`. Wire the corresponding click listeners + `let on...Click` placeholders in Task 4 — this Task 3 step just exports the API.)

Add the placeholder lets near the existing handler-let cluster (around line 688-692):

```javascript
    let onReRecordClick = () => {};
    let onContinueClick = () => {};
```

Add the click listeners alongside the existing button listeners (around line 776-781):

```javascript
    root.querySelector(".phx-replay-rerecord").addEventListener("click", () => onReRecordClick());
    root.querySelector(".phx-replay-continue").addEventListener("click", () => onContinueClick());
```

- [ ] **Step 5: Verify**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 6: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(panel): add REVIEW screen markup + Re-record/Continue button wiring

ADR-0006 Phase 3 Task 3: insert SCREENS.REVIEW between Stop and the
legacy FORM screen (which becomes the Path B describe step). The
review section carries a mini rrweb-player container and a
data-slot="review-media" div for addons (audio playback addon being
the first consumer in the ash_feedback companion spec).

CSS styles the player container with a fixed height + max-height
clamp so the mini-player doesn't blow out the modal. Re-record and
Continue buttons are wired to onReRecord/onContinue setters but the
init orchestrator's handlers land in Task 4. The mini rrweb-player
instantiation lands in Task 4 (uses client.takeReviewEvents()).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Mini rrweb-player init + Re-record / Continue handlers

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — `renderPanel` (mini-player init), `init` orchestrator (Re-record / Continue / Stop wiring)
- Modify: `lib/phoenix_replay/ui/components.ex` — add `rrweb_player_src` attr + conditional script tag emission

The widget script can't depend on rrweb-player being already loaded (the existing `phoenix_replay_widget` only loads rrweb-record, not rrweb-player). Add a host-config attr that emits the player script tag, then in JS lazily reference `window.rrwebPlayer` when the review screen opens.

- [ ] **Step 1: Add `rrweb_player_src` widget attr**

In `lib/phoenix_replay/ui/components.ex`, near the existing `rrweb_src` / `rrweb_console_src` / `rrweb_network_src` attrs (around lines 94-104), add a new attr:

```elixir
  attr :rrweb_player_src, :string,
    default: "https://unpkg.com/rrweb-player@2.0.0-alpha.18/dist/rrweb-player.umd.cjs",
    doc:
      "Script URL for rrweb-player UMD. Used by Path B's review step " <>
        "to render the mini playback before the user submits. Pass " <>
        "`nil` to disable — the review step degrades to a 'Continue " <>
        "without preview' UI in that case. Path A-only widgets " <>
        "(`allow_paths: [:report_now]`) don't need it; the script tag " <>
        "is suppressed when the player can't be reached."

  attr :rrweb_player_style_src, :string,
    default: "https://unpkg.com/rrweb-player@2.0.0-alpha.18/dist/style.css",
    doc:
      "Stylesheet URL for rrweb-player. Pass `nil` to disable. Loaded " <>
        "alongside the player script for Path B-capable widgets."
```

In the render (around line 162-180), conditionally emit the script + stylesheet only when `:record_and_report` is in `@allow_paths`:

```elixir
  def phoenix_replay_widget(assigns) do
    assigns = assign(assigns, :path_b_enabled, :record_and_report in (assigns[:allow_paths] || []))

    ~H"""
    <link :if={@asset_path} rel="stylesheet" href={"#{@asset_path}/phoenix_replay.css"} />
    <script :if={@rrweb_src} src={@rrweb_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_console_src} src={@rrweb_console_src} crossorigin="anonymous"></script>
    <script :if={@rrweb_network_src} src={@rrweb_network_src} crossorigin="anonymous"></script>
    <link :if={@path_b_enabled and @rrweb_player_style_src} rel="stylesheet" href={@rrweb_player_style_src} crossorigin="anonymous" />
    <script :if={@path_b_enabled and @rrweb_player_src} src={@rrweb_player_src} crossorigin="anonymous"></script>
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

- [ ] **Step 2: Add component test for the new attr**

In `test/phoenix_replay/ui/components_test.exs`, after the `buffer_window_seconds` tests (around the end of the `phoenix_replay_widget/1` describe block), add:

```elixir
    test "rrweb_player_src + style emitted when allow_paths includes :record_and_report" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ "rrweb-player@2.0.0-alpha.18"
      assert html =~ "style.css"
    end

    test "rrweb_player_src suppressed when allow_paths is report_now-only" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          allow_paths: [:report_now]
        )

      refute html =~ "rrweb-player@2.0.0-alpha.18"
    end

    test "rrweb_player_src custom URL is honored" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          rrweb_player_src: "/assets/my-player.js",
          rrweb_player_style_src: "/assets/my-player.css"
        )

      assert html =~ ~s(src="/assets/my-player.js")
      assert html =~ ~s(href="/assets/my-player.css")
    end
```

Run them now (expect 3 failures since the attr isn't added yet — actually, Step 1's component change should make them pass; if they fail, fix the component change first):

```
cd /Users/johndev/Dev/phoenix_replay && mix test test/phoenix_replay/ui/components_test.exs
```

Expected: green (the component change in Step 1 implements the behavior).

- [ ] **Step 3: Add mini rrweb-player init in `renderPanel`**

In `priv/static/assets/phoenix_replay.js` `renderPanel`, after the existing `setScreen` / `showModal` / `hideModal` definitions (around line 694-699), add a helper for instantiating the mini-player:

```javascript
    // Mini rrweb-player instance for the REVIEW screen. Lazily created
    // when openReview() is called with events. Replaced on Re-record
    // (the second call destroys the previous instance and creates a
    // fresh one against the new events).
    let miniPlayer = null;
    let miniPlayerEvents = null;

    function destroyMiniPlayer() {
      if (!miniPlayer) return;
      try {
        // rrweb-player exposes a `.$destroy()` method (Svelte component).
        if (typeof miniPlayer.$destroy === "function") miniPlayer.$destroy();
      } catch (err) {
        console.warn("[PhoenixReplay] mini-player destroy failed:", err.message);
      }
      miniPlayer = null;
      miniPlayerEvents = null;
      const container = root.querySelector("[data-phx-replay-mini-player]");
      if (container) container.innerHTML = "";
    }

    function initMiniPlayer(events) {
      destroyMiniPlayer();
      const container = root.querySelector("[data-phx-replay-mini-player]");
      if (!container) return;
      if (!global.rrwebPlayer) {
        // The widget component emits the player script tag; if it
        // didn't load (network failure, host disabled it), surface a
        // Continue-without-preview UX.
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Playback unavailable. Continue to describe.</div>`;
        miniPlayerEvents = events;
        return;
      }
      // rrweb-player needs at least 2 events to construct a timeline.
      // Single-event recordings (rare — basically a Stop without any
      // captured action) bypass the player and show a stub.
      if (!Array.isArray(events) || events.length < 2) {
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Recording too short to preview. Continue to describe.</div>`;
        miniPlayerEvents = events || [];
        return;
      }
      try {
        miniPlayer = new global.rrwebPlayer({
          target: container,
          props: {
            events,
            width: container.clientWidth,
            height: 256,
            autoPlay: false,
            showController: true,
          },
        });
        miniPlayerEvents = events;
      } catch (err) {
        console.warn("[PhoenixReplay] mini-player init failed:", err.message);
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Playback failed. Continue to describe.</div>`;
        miniPlayerEvents = events;
      }
    }
```

Then update the `close()` function (around line 763-774) to destroy the player on panel close:

```javascript
    function close() {
      hideModal();
      form.reset();
      status.textContent = "";
      destroyMiniPlayer();
      setScreen(SCREENS.FORM);
      addonCloseCbs.forEach((cb) => {
        try { cb(); } catch (err) { console.warn(`[PhoenixReplay] addon close hook failed: ${err.message}`); }
      });
    }
```

Update `openReview()` to take events and init the player:

```javascript
    function openReview(events) {
      initMiniPlayer(events);
      setScreen(SCREENS.REVIEW);
      showModal();
    }
```

(Removes the no-arg version added in Task 3 — the orchestrator passes events in.)

- [ ] **Step 4: Wire Re-record + Continue + Stop in `init`**

In `init` (around line 1032-1050), the existing `handleStop` opens the legacy form directly. Replace it with the review-step flow:

```javascript
      async function handleStop() {
        const wasRecording = client.isRecording();
        await client.stopRecording();
        if (!wasRecording) return;
        syncRecordingUI();
        // Phase 3: Stop opens REVIEW (mini-player + addons). Continue
        // advances to the describe step (legacy FORM); Re-record
        // discards events and starts a fresh active session.
        const events = client.takeReviewEvents();
        panel.openReview(events);
      }

      async function handleReRecord() {
        // resetRecording is a no-op when not recording, but Stop has
        // already transitioned to :passive. Re-record from review =
        // discard the just-captured events and start a fresh active
        // session. The pill swaps back in via syncRecordingUI.
        try {
          await client.startRecording();
          syncRecordingUI();
          panel.close();
        } catch (err) {
          panel.openError(`Couldn't restart recording: ${err.message}`);
        }
      }

      function handleContinue() {
        // Advance to the describe step (legacy FORM). Mini-player is
        // destroyed by openForm via setScreen → close() chain when the
        // panel eventually closes; for the in-modal transition we just
        // swap screens without destroying.
        panel.openForm();
      }
```

Then wire the new handlers (around the existing `panel.onStart` cluster at line 1040-1050):

```javascript
      panel.onStart(handleStartFromPanel);
      panel.onRetry(handleStartFromPanel);
      panel.onChooseReportNow(() => panel.openPathAForm());
      panel.onChooseRecord(() => handleStartFromPanel());
      panel.onReRecord(handleReRecord);
      panel.onContinue(handleContinue);
      panel.onPathASubmit(async (formData) => {
        await client.reportNow({
          description: formData.get("description"),
          severity: formData.get("severity") || undefined,
          jamLink: formData.get("jam_link") || null,
        });
      });
```

- [ ] **Step 5: Add fallback CSS**

Append to `priv/static/assets/phoenix_replay.css`:

```css
.phx-replay-review-player-fallback {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  padding: 1rem;
  text-align: center;
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted);
}
```

- [ ] **Step 6: Verify**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 7: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add lib/phoenix_replay/ui/components.ex test/phoenix_replay/ui/components_test.exs priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(review): mini rrweb-player + Re-record/Continue handlers

ADR-0006 Phase 3 Task 4: Stop now opens the REVIEW screen with a
client-side mini rrweb-player (instantiated against
client.takeReviewEvents() — no new server endpoint). Re-record
discards events and starts a fresh :active session; Continue
advances to the legacy FORM screen, which is now repurposed as the
Path B describe step.

The widget component gains rrweb_player_src + rrweb_player_style_src
attrs whose script/stylesheet tags emit only when allow_paths
includes :record_and_report (Path A-only widgets don't need the
player). Path B widgets that disable the player gracefully degrade
to a "Continue without preview" stub.

Mini-player destroy is wired to panel close + Re-record so resources
release between sessions. Single-event or zero-event recordings
bypass instantiation and show a "too short to preview" stub.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Slot lifecycle — mount on slot-appear, unmount on slot-disappear

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — `renderPanel` (replace one-shot addon mount with lifecycle-tracked mount/unmount)

The current addon API mounts every registered addon once at panel construction. The new contract: an addon's `mount(ctx)` runs when its slot's DOM becomes "live" (the screen containing the slot becomes visible, OR the pill's slot DOM exists when the pill shows), and the cleanup function the addon returns (or `addonCloseCbs` callback) runs when the slot becomes "dead" (screen hidden, pill hidden, panel closed).

Key insight: each slot has a known parent (the screen or the pill). Mount/unmount fires when the parent transitions visible/hidden.

- [ ] **Step 1: Read current addon mount block**

The current block in `renderPanel` (around line 711-761) mounts every addon at panel construction. Replace it with a lifecycle-aware version.

- [ ] **Step 2: Replace addon mount block with lifecycle tracker**

In `priv/static/assets/phoenix_replay.js`, find the block from `// Mount panel addons against their slots.` (line 711) through the closing `});` of `PANEL_ADDONS.forEach` (around line 761). Replace with:

```javascript
    // ADR-0006 Phase 3 slot lifecycle.
    //
    // Each addon mounts when its slot's "host" DOM becomes live and
    // unmounts when the host goes dead. Hosts:
    //   - "form-top": legacy FORM screen → live when SCREENS.FORM is
    //                 visible OR PATH_A_FORM (form-top is duplicated
    //                 across both forms in Phase 2; addons see the
    //                 first one). For now we treat form-top as
    //                 "live whenever the panel is open" (existing
    //                 semantics — preserved by addon shape).
    //   - "pill-action": new in Phase 3, hosted by the pill DOM.
    //                    Live when pill is visible.
    //   - "review-media": new in Phase 3, hosted by REVIEW screen.
    //                     Live when SCREENS.REVIEW is visible.
    //
    // Mount returns:
    //   - undefined → no cleanup (legacy form-top addons that returned
    //                 nothing).
    //   - function → called when slot goes dead (slot-lifecycle).
    //   - object {beforeSubmit, onPanelClose} → legacy shape; the
    //     orchestrator collects these for the form-submit path and
    //     panel-close cleanup. Used by Phase 2's audio addon (which
    //     returns this object today and migrates in the ash_feedback
    //     companion phase).

    const addonHooks = [];   // [{ id, beforeSubmit?, onPanelClose? }]
    const addonCloseCbs = [];

    // Track per-slot lifecycle state. Map<slotName, { addons: [...], mountedIds: Set<string> }>.
    // mountedIds tracks which addon ids are currently mounted on the slot,
    // so we can call cleanup on transition.
    const slotState = new Map();

    function ensureSlotState(slotName) {
      if (!slotState.has(slotName)) slotState.set(slotName, { mountedIds: new Map() });
      return slotState.get(slotName);
    }

    function buildAddonCtx(slotEl) {
      return {
        slotEl,
        sessionId: () => client._internals?.sessionId?.() ?? null,
        sessionStartedAtMs: () => client._internals?.sessionStartedAtMs?.() ?? null,
        onPanelClose: (cb) => addonCloseCbs.push(cb),
        reportError: (msg) => { errorMessage.textContent = msg; setScreen(SCREENS.ERROR); showModal(); },
      };
    }

    function pathFilterMatches(addon) {
      // Phase 3: addons may declare paths: ["report_now" | "record_and_report"]
      // OR (transitional, deprecated) modes: ["on_demand" | "continuous"].
      // Both filters drop the addon when the widget's allowPaths excludes
      // the relevant user-path. New addons should use paths:.
      const allow = cfg.allowPaths || ["report_now", "record_and_report"];
      if (Array.isArray(addon.paths) && addon.paths.length > 0) {
        return addon.paths.some((p) => allow.includes(p));
      }
      if (Array.isArray(addon.modes) && addon.modes.length > 0) {
        // Legacy modes filter — same shim Phase 2 added, kept here for
        // unmigrated addons. Drop in Phase 4 once ash_feedback is
        // migrated.
        return addon.modes.some((m) => {
          if (m === "on_demand") return allow.includes("record_and_report");
          if (m === "continuous") return allow.includes("report_now");
          return false;
        });
      }
      return true;  // No filter → mount on any allowed path.
    }

    function mountAddonsForSlot(slotName, slotEl) {
      if (!slotEl) return;
      const state = ensureSlotState(slotName);
      PANEL_ADDONS.forEach((addon) => {
        if (addon.slot !== slotName) return;
        if (state.mountedIds.has(addon.id)) return;  // already mounted
        if (!pathFilterMatches(addon)) return;
        try {
          const ctx = buildAddonCtx(slotEl);
          const result = addon.mount(ctx);
          let cleanup = null;
          if (typeof result === "function") {
            // New shape: result IS the cleanup function.
            cleanup = result;
          } else if (result && typeof result === "object") {
            // Legacy shape: { beforeSubmit, onPanelClose } — collect for
            // the orchestrator. cleanup stays null (panel-close cb
            // handles release).
            addonHooks.push({ id: addon.id, ...result });
            if (typeof result.onPanelClose === "function") {
              cleanup = result.onPanelClose;
            }
          }
          state.mountedIds.set(addon.id, cleanup);
        } catch (err) {
          console.warn(`[PhoenixReplay] addon "${addon.id}" failed to mount on slot "${slotName}": ${err.message}`);
        }
      });
    }

    function unmountAddonsForSlot(slotName) {
      const state = slotState.get(slotName);
      if (!state) return;
      state.mountedIds.forEach((cleanup, id) => {
        if (typeof cleanup === "function") {
          try { cleanup(); } catch (err) {
            console.warn(`[PhoenixReplay] addon "${id}" cleanup failed for slot "${slotName}": ${err.message}`);
          }
        }
      });
      state.mountedIds.clear();
    }

    // form-top is panel-scoped (lives in the legacy + Path A forms,
    // both rendered at panel construction). Mount once at construction
    // for legacy compatibility; cleanup happens in `close()`.
    const formTopSlots = root.querySelectorAll('[data-slot="form-top"]');
    formTopSlots.forEach((slotEl) => mountAddonsForSlot("form-top", slotEl));
```

That handles `form-top` immediately (legacy semantics). The `pill-action` and `review-media` slots are mounted/unmounted lifecycle-driven by the orchestrator (Task 5 Step 3).

- [ ] **Step 3: Hook lifecycle into setScreen + pill show/hide**

In `renderPanel`, the existing `setScreen` (around line 694-696) doesn't know about slot lifecycle. Wrap it so screen transitions trigger mount/unmount for the screen-hosted slots:

```javascript
    function setScreen(name) {
      // Find which screen will go from hidden to visible and vice versa.
      let entering = null;
      let leaving = [];
      screens.forEach((s) => {
        const willHide = s.dataset.screen !== name;
        const wasHidden = s.hasAttribute("hidden");
        s.hidden = willHide;
        if (!willHide && wasHidden) entering = s;
        if (willHide && !wasHidden) leaving.push(s);
      });

      // Slot-lifecycle: when a screen with a known slot becomes visible,
      // mount its addons; when a screen with a known slot becomes hidden,
      // unmount.
      leaving.forEach((s) => {
        const slotEl = s.querySelector("[data-slot]");
        if (slotEl) unmountAddonsForSlot(slotEl.dataset.slot);
      });
      if (entering) {
        const slotEl = entering.querySelector("[data-slot]");
        if (slotEl && slotEl.dataset.slot !== "form-top") {
          // form-top already mounted at construction; only lifecycle-
          // managed slots (review-media) re-mount.
          mountAddonsForSlot(slotEl.dataset.slot, slotEl);
        }
      }
    }
```

For the pill-action slot, the lifecycle is tied to pill visibility, not screen. In `init`, update `syncRecordingUI` to mount/unmount the pill-action slot when the pill shows/hides. The pill exposes `slotEl` (Task 2). But `init` doesn't have direct access to `mountAddonsForSlot` — that's local to `renderPanel`. Expose it via the panel return:

In `renderPanel`'s return (Task 3 + 4 already added entries), add two more:

```javascript
    return {
      ...
      mountSlot: (slotName, slotEl) => mountAddonsForSlot(slotName, slotEl),
      unmountSlot: (slotName) => unmountAddonsForSlot(slotName),
    };
```

Then in `init`'s `syncRecordingUI`:

```javascript
      function syncRecordingUI() {
        const recording = client.isRecording();
        if (pill) {
          if (recording) {
            pill.show(client._internals.sessionStartedAtMs?.() ?? Date.now());
            panel.mountSlot("pill-action", pill.slotEl);
          } else {
            panel.unmountSlot("pill-action");
            pill.hide();
          }
        }
        if (toggle && pill) recording ? toggle.hide() : toggle.show();
      }
```

- [ ] **Step 4: Update close() to fire all lifecycle unmounts**

The `close()` function in `renderPanel` should unmount everything when the panel closes. Update it:

```javascript
    function close() {
      hideModal();
      form.reset();
      status.textContent = "";
      destroyMiniPlayer();
      setScreen(SCREENS.FORM);
      // Unmount any lifecycle-managed slots that were live. form-top
      // legacy addons run via addonCloseCbs (back-compat path).
      slotState.forEach((_state, slotName) => {
        if (slotName !== "form-top") unmountAddonsForSlot(slotName);
      });
      addonCloseCbs.forEach((cb) => {
        try { cb(); } catch (err) { console.warn(`[PhoenixReplay] addon close hook failed: ${err.message}`); }
      });
    }
```

- [ ] **Step 5: Update `registerPanelAddon` public method to accept `paths`**

In the `PhoenixReplay` global (around line 963-975), the existing `registerPanelAddon` accepts `{id, slot, mount, modes}`. Extend it to accept `paths`:

```javascript
    registerPanelAddon({ id, slot, mount, modes, paths }) {
      if (typeof id !== "string" || id.length === 0) {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a string id");
      }
      if (typeof mount !== "function") {
        throw new Error("[PhoenixReplay] registerPanelAddon requires a mount function");
      }
      // `paths` (Phase 3) is the new canonical filter — a list of
      // user-facing path symbols (`"report_now"`, `"record_and_report"`).
      // `modes` is the deprecated legacy filter from the 2026-04-25
      // mode-aware addons spec; it's mapped to `paths` via the
      // pathFilterMatches shim. New addons should use `paths`.
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

- [ ] **Step 6: Verify**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && node test/js/ring_buffer_test.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 7: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js && git commit -m "$(cat <<'EOF'
feat(addon): slot mount/unmount lifecycle + paths filter

ADR-0006 Phase 3 Task 5: replace the one-shot addon-mount-at-construction
pattern with a per-slot lifecycle. form-top mounts at construction
(legacy semantics); pill-action mounts when the pill becomes visible
and unmounts on Stop / panel close; review-media mounts when the
REVIEW screen becomes visible and unmounts on Continue / Re-record /
panel close.

Mount return shape:
- function → cleanup, called when slot goes dead.
- object {beforeSubmit, onPanelClose} → legacy shape, collected for
  submit / panel-close cleanup. Used by Phase 2's audio addon.
- nothing → no cleanup (legacy form-top addons that returned
  undefined).

`registerPanelAddon` accepts the new `paths:` filter alongside the
deprecated `modes:`. Both flow through `pathFilterMatches` which
applies the same legacy-symbol shim Phase 2 added (modes:["on_demand"]
→ allow_paths includes record_and_report). The shim stays for one
more phase to give the ash_feedback audio addon time to migrate;
Phase 4 drops it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Path B describe step — repurpose legacy FORM screen

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — replace the legacy form's banner-less heading with a "Recording 0:24" line, ensure it routes from REVIEW Continue.

The legacy `<form data-screen="${SCREENS.FORM}">` already serves Path B's submit step, but its `<h2>Report an issue</h2>` heading reads ambiguously now that REVIEW exists. Replace with a recording-meta line that shows the elapsed recording time, matching the spec's "Recording 0:24" framing.

- [ ] **Step 1: Update the FORM heading to describe Path B context**

In `renderPanel`'s template (around line 619-641), the legacy form opens with:

```html
          <form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
            <h2 id="phx-replay-title">Report an issue</h2>
            <label>
              <span>What happened?</span>
              ...
```

Replace with:

```html
          <form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
            <h2 id="phx-replay-title">Describe what happened</h2>
            <p class="phx-replay-recording-meta" data-phx-replay-recording-meta>
              <span class="phx-replay-recording-meta-icon" aria-hidden="true">🔴</span>
              <span class="phx-replay-recording-meta-text">Recording attached</span>
            </p>
            <label>
              <span>What happened?</span>
              ...
```

The `data-phx-replay-recording-meta` attribute lets the orchestrator update the text dynamically (next step adds duration display).

- [ ] **Step 2: Wire duration display in init's openForm transition**

The duration is a function of `client._internals.sessionStartedAtMs()`. In `init`, refine `handleContinue`:

```javascript
      function handleContinue() {
        const startedAtMs = client._internals.sessionStartedAtMs?.();
        const metaText = document.querySelector(".phx-replay-recording-meta-text");
        if (metaText && startedAtMs) {
          const elapsed = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
          const m = Math.floor(elapsed / 60);
          const s = elapsed % 60;
          metaText.textContent = `Recording attached (${m}:${s.toString().padStart(2, "0")})`;
        }
        panel.openForm();
      }
```

For Path B widgets, `_internals.sessionStartedAtMs()` returns the active session's start time. Note: by Continue time the recorder is already in `:passive` (Stop transitioned it). Since Phase 2's `stopRecording` does partial teardown that keeps `sessionStartedAtMs`, this still works — but verify by inspecting `stopRecording`:

In `priv/static/assets/phoenix_replay.js` `stopRecording` (around line 387-400), confirm it does NOT clear `sessionStartedAtMs`. If it does, the meta text will fall back to the static "Recording attached" — acceptable graceful degradation.

(Looking at the file: `stopRecording` does NOT clear `sessionStartedAtMs` — it's only cleared in `transitionToPassive`. So `Continue` at the post-Stop moment has access to the start time.)

- [ ] **Step 3: Append CSS for the recording-meta line**

In `priv/static/assets/phoenix_replay.css`:

```css
/* Path B describe step — context line that replaces the Path A
 * banner. Indicates the user has a recording attached and shows its
 * duration (when available) so they have a sense of what's being
 * sent.
 */
.phx-replay-recording-meta {
  margin: 0;
  padding: 0.5rem 0.625rem;
  background: var(--phx-replay-surface-muted);
  border: 1px solid var(--phx-replay-border);
  border-radius: 0.5rem;
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted);
  display: flex;
  align-items: center;
  gap: 0.375rem;
}

.phx-replay-recording-meta-icon {
  font-size: 0.625rem;
}
```

- [ ] **Step 4: Verify**

```
cd /Users/johndev/Dev/phoenix_replay && node --check priv/static/assets/phoenix_replay.js
cd /Users/johndev/Dev/phoenix_replay && mix test
```

All green.

- [ ] **Step 5: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add priv/static/assets/phoenix_replay.js priv/static/assets/phoenix_replay.css && git commit -m "$(cat <<'EOF'
feat(panel): Path B describe step — recording-meta line replaces ambiguous header

ADR-0006 Phase 3 Task 6: the legacy FORM screen is now Path B's
describe step (post-review). Replace the ambiguous "Report an issue"
heading with "Describe what happened" + a recording-meta line that
surfaces the captured duration so the user knows what's attached.

Continue from REVIEW computes elapsed seconds from
client._internals.sessionStartedAtMs() (preserved across stopRecording's
partial teardown) and updates the meta text. Falls back to the static
"Recording attached" if the start time isn't available.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cross-repo deps refresh + browser smoke matrix

**Files:**
- Touch: `~/Dev/ash_feedback_demo/deps/phoenix_replay/...` (cp from canonical)

After Tasks 1-6 land in canonical, sync into demo for browser smoke.

- [ ] **Step 1: cp + force recompile + restart**

```bash
cp ~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/lib/phoenix_replay/ui/components.ex
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.css \
   ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.css
cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force
```

Then restart via Tidewave with `reason: "deps_changed"`.

- [ ] **Step 2: Smoke matrix**

8 rows. Mark PASS or note the failure inline.

| # | Page | Action | Expected |
|---|---|---|---|
| 1 | `/demo/continuous` | Mount page | rrweb-player script tag present in `<head>` (Path B-capable widget). `data-allow-paths="report_now,record_and_report"`. |
| 2 | Same | Click toggle → "Record and report" | Pill appears with `0:00` time display + a `data-slot="pill-action"` div + Stop button. |
| 3 | Same | Wait 5s, observe pill | Time display ticks: `0:01`, `0:02`, … |
| 4 | Same | Click Stop | REVIEW screen opens with rrweb-player playing back the captured session. `data-slot="review-media"` div is empty (no addon registered yet). |
| 5 | Same | Click Re-record | Modal closes; pill reappears with fresh `0:00`; `/session` POST in Network. |
| 6 | Same | Stop → Continue | FORM (describe step) opens. Heading: "Describe what happened". Recording-meta line shows duration. |
| 7 | Same | Send | `/submit` POST 201; modal closes; admin shows new feedback row with the captured events. |
| 8 | Same | DevTools console: register a test addon `window.PhoenixReplay.registerPanelAddon({id: "test-pill", slot: "pill-action", paths: ["record_and_report"], mount: (ctx) => { const el = document.createElement("span"); el.textContent = "MIC"; ctx.slotEl.appendChild(el); console.log("mounted"); return () => console.log("unmounted"); }})`. Click toggle → Record and report. | Console: "mounted". Pill shows `MIC` text. Click Stop. Console: "unmounted". |

If row 4 falls back to "Playback unavailable" or "Recording too short to preview", the events aren't reaching `client.takeReviewEvents()`. Inspect: `window.__lastEvents = client._internals.buffer; client.takeReviewEvents().length` — should be > 1.

If row 8 doesn't fire "mounted"/"unmounted", the lifecycle wiring missed. Inspect via `console.log` injection.

- [ ] **Step 3: If smoke is green, proceed. If not, fix in canonical, re-sync, re-smoke.**

---

## Task 8: CHANGELOG + commit

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append Phase 3 block**

In `~/Dev/phoenix_replay/CHANGELOG.md` under `## [Unreleased]`, immediately AFTER the Phase 2 block, insert:

```markdown
### ADR-0006 Phase 3 — Pill slot + Review step + Slot lifecycle (2026-04-25)

The recording pill grows a `data-slot="pill-action"` div between the
time display and the Stop button. Addons that target Path B's
in-flight UX (audio mic toggle being the first consumer in the
ash_feedback companion spec) mount here when the pill appears and
unmount when it disappears.

A new `SCREENS.REVIEW` screen sits between Stop and the legacy
describe form. It embeds a client-side mini rrweb-player fed from
`client.takeReviewEvents()` (events accumulated during `:active`
flushes — no new server endpoint) and a `data-slot="review-media"`
div for media-playback addons. Re-record discards the events and
starts a fresh session; Continue advances to the describe step.

The legacy `SCREENS.FORM` is now Path B's describe step. Heading
shifts from "Report an issue" to "Describe what happened" with a
recording-meta line ("Recording attached (0:24)") replacing the
Path A banner.

`registerPanelAddon` accepts a new `paths:` filter — a list of
user-facing path symbols (`"report_now"`, `"record_and_report"`).
The legacy `modes:` filter is retained for one more phase via the
shim from Phase 2 to give the ash_feedback audio addon time to
migrate; Phase 4 drops it.

Slot lifecycle: an addon's `mount(ctx)` may return:
- a function — called when the slot's host DOM goes dead (slot
  hidden, panel closed). New canonical contract.
- `{beforeSubmit, onPanelClose}` — legacy shape, still works for
  Phase 2 addons until they migrate.
- nothing — legacy "fire-and-forget" mount.

Widget component gains `rrweb_player_src` + `rrweb_player_style_src`
attrs whose script/stylesheet tags emit only when `allow_paths`
includes `:record_and_report`. Path A-only widgets save a network
roundtrip.

Pill exposes `slotEl` for the lifecycle wiring and a 1Hz recording
time display computed from the active session's `sessionStartedAtMs`.

Smoke verified in Chrome on the ash_feedback_demo continuous page —
all 8 rows of the smoke matrix in
`docs/superpowers/plans/2026-04-25-unified-entry-phase-3.md` Task 7
green: pill-action slot mounts/unmounts on pill appear/disappear,
review screen renders the mini-player from local events, Re-record
restarts the session, Continue advances to describe with recording
duration, programmatic addon registration via `paths:` filter mounts
on Path B and not Path A.

**Out of scope, deferred to ash_feedback companion phase**: audio
addon migration from `slot: "form-top"` + `modes: ["on_demand"]` to
`slot: "pill-action"` + `slot: "review-media"` + `paths:
[:record_and_report]`. Tracked in
`~/Dev/ash_feedback/docs/superpowers/specs/2026-04-25-audio-addon-pill-relocation-design.md`.

**Out of scope, deferred to Phase 4**: drop the `modes:` legacy
shim once the ash_feedback audio addon has migrated. Drop the
`open()` global alias for `openPanel()` (retained one more phase
for back-compat).
```

- [ ] **Step 2: Commit**

```bash
cd /Users/johndev/Dev/phoenix_replay && git add CHANGELOG.md && git commit -m "$(cat <<'EOF'
docs(changelog): ADR-0006 Phase 3 — pill slot + review step + slot lifecycle

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Risks (from the spec, surfaced for the implementer)

- **`reviewEvents` accumulator memory.** A long Path B session (10+ minutes) accumulates ~10 MB in client memory. Acceptable for typical bug reproduction (30s-2min); document in Phase 3 release notes that hosts who expect very long Path B sessions should warn users.
- **rrweb-player UMD load failure** (CDN flaky, ad-block list) leaves the review with a "Playback unavailable" stub. Continue still works; user just doesn't preview. The fallback CSS + copy makes the failure self-explanatory.
- **Legacy `{beforeSubmit, onPanelClose}` addons mounted on the new lifecycle slots.** The orchestrator detects shape via `typeof` — function = cleanup, object = legacy. The audio addon currently returns the legacy shape; until it migrates, it stays on `form-top` (its current slot) and the lifecycle changes don't affect it.
- **Re-record race.** User clicks Re-record while the mini-player is initializing (rrweb-player Svelte $destroy not synchronous). The `destroyMiniPlayer` is wrapped in try/catch; worst case is a console warning + the new player initializing successfully alongside the destroyed one. Acceptable for Phase 3.
- **`paths:` filter on the `pill-action` slot** for an addon that should mount only on Path B is straightforward. But the slot only exists when the pill is visible, and the pill only shows for `:active` sessions, which only happen via Path B's `startRecording()`. So even an unfiltered addon registered with `slot: "pill-action"` would only mount during Path B in practice. The filter is belt-and-suspenders.

## Definition of Done

- [ ] All 8 task commits land cleanly on `main`.
- [ ] `mix test` green (full suite).
- [ ] `node test/js/ring_buffer_test.js` prints `OK ring_buffer_test (5 cases)`.
- [ ] `node --check priv/static/assets/phoenix_replay.js` exits 0.
- [ ] Task 7 smoke matrix rows 1-8 all PASS in browser on `localhost:4006`.
- [ ] CHANGELOG entry merged.
- [ ] Phase 3 commits pushed to `origin/main` (manual via user — same workflow as Phase 2 finish).

The ash_feedback audio addon migration begins once Phase 3 ships. Phase 4 (drop legacy shims, finalize symbol surface) follows after that migration lands.

---

## Self-Review

After completing all 8 tasks, run this checklist:

**1. Spec coverage** — map each spec § Phasing item to a task:

| Spec item (§ Phasing) | Task |
|---|---|
| 3.1 Pill template extension: pill-action slot | Task 2 |
| 3.2 Review step panel: rrweb mini-player + review-media slot + Re-record + Continue | Task 3 + Task 4 |
| 3.3 Describe step (Path B): "Recording 0:24" line, FORM repurposed | Task 6 |
| 3.4 registerPanelAddon accepts new slot strings + paths filter; slot mount lifecycle | Task 5 |
| 3.5 Tests: addon mount lifecycle | Task 5 (lifecycle); Task 7 row 8 (programmatic addon smoke) |
| 3.6 CHANGELOG, README addon-API guide update, smoke | Task 8 (CHANGELOG); Task 7 (smoke). README addon-API guide is intentionally deferred to a follow-on commit — the public API hasn't fully settled until Phase 4 drops the legacy shims, so a permanent doc page is premature. |

**2. Placeholder scan** — search for forbidden patterns:
- "TBD" / "TODO" / "implement later" — none.
- "Add appropriate error handling" — none. Where errors are caught, the catch is explicit (`console.warn` with the addon id).
- "Similar to Task N" — none.
- Steps that describe *what* without *how* — code blocks in every code-changing step.

**3. Type / name consistency**:
- `client.takeReviewEvents()` — defined in Task 1 step 2, called in Task 4 step 4 (`handleStop`). Same name.
- `panel.openReview(events)` — defined in Task 4 step 3 (replaces Task 3 step 4's no-arg version), called in Task 4 step 4 (`handleStop`). Signature change documented in Task 4.
- `panel.mountSlot` / `panel.unmountSlot` — defined in Task 5 step 3, called in Task 5's `init` `syncRecordingUI` update. Same name.
- `pill.slotEl` / `pill.startedAtMs` — exposed in Task 2 step 1, consumed in Task 5 step 3 (`syncRecordingUI`). Same names.
- `mountAddonsForSlot` / `unmountAddonsForSlot` / `pathFilterMatches` / `slotState` — all defined in Task 5 step 2, internal to `renderPanel`. No external dependencies.
- `panel.onReRecord` — defined in Task 3 step 4 (the export setter), called in Task 4 step 4 (`init` wiring). Same name.
- `SCREENS.REVIEW` — added in Task 3 step 1, used in Task 3 step 2 markup, Task 4 step 3 `openReview`. Consistent.

If implementation surfaces any divergence (e.g., rrweb-player API changed, mini-player can't be embedded inside the modal), append an addendum here rather than silently revising.
