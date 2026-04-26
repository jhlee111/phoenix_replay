# Unified Feedback Entry — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the recorder into a `:passive` (client-side ring buffer, no server flush) / `:active` (server-flushed session, current behavior) state machine, and add a single-shot `POST /report` endpoint that ingests Path A (Report Now) submissions inline.

**Architecture:** The existing flush pipeline (`flush()` + `scheduleFlush()` + `flushOnUnload()`) is gated on `state === "active"`. The ring buffer gains a time-window eviction mode (in addition to the existing event-count cap). A new `PhoenixReplay.Controllers.ReportController` accepts `{description, severity, events, metadata, jam_link}`, mints a synthetic session via `Storage.Dispatch.start_session/2` + `append_events/3` + `submit/3`, and returns `{ok, id}`. UX is unchanged in this phase — the existing panel still opens with the same screens; only the underlying flush behavior changes.

**Tech Stack:** Elixir + Phoenix (controllers, router macro), vanilla ES2020 (`phoenix_replay.js`), Node 18+ for the one-off ring-buffer JS smoke (no new test framework). Existing test conventions: ExUnit + `Phoenix.ConnTest`, `RecordingStorage` Agent for storage stubbing.

---

## Spec coverage map

| Spec sub-task | Tasks in this plan |
|---|---|
| 1.1 Recon | Task 1 |
| 1.2 `createRingBuffer(windowMs)` time-window eviction | Task 2 |
| 1.3 Passive/Active state machine | Task 3 |
| 1.4 `POST /api/feedback/report` endpoint | Task 4 |
| 1.5 Tests | embedded in Tasks 2, 3, 4 (TDD) + Task 5 integration smoke |
| 1.6 CHANGELOG + smoke verify | Task 6 |

## File structure

| File | Status | Responsibility |
|---|---|---|
| `priv/static/assets/phoenix_replay.js` | Modify | Recorder lifecycle; ring buffer factory; gate flush sites on `state === "active"` |
| `lib/phoenix_replay/controller/report_controller.ex` | **Create** | One-shot ingest: `{events, description, severity, …}` → mint session → append → submit → close |
| `lib/phoenix_replay/router.ex` | Modify | `feedback_routes/2` macro: add `post "/report", PhoenixReplay.ReportController, :create` |
| `test/phoenix_replay/controller/report_controller_test.exs` | **Create** | Controller unit: happy path, missing fields, body too large |
| `test/js/ring_buffer_test.js` | **Create** | Node-based pure-function test for ring-buffer time-window eviction (no test framework — single file with `assert`) |
| `CHANGELOG.md` | Modify | Unreleased → "Phase 1 — capture model" entry under ADR-0006 heading |

No new dependencies. No router signature change for hosts (the new `/report` route mounts inside the existing `feedback_routes/2` macro, so hosts already on `feedback_routes "/feedback"` get `/feedback/report` automatically).

---

## Task 1 — Recon: map all flush sites + state-shaped variables

**Files:** none modified. Output is a verification checklist used by Tasks 2 + 3.

- [ ] **Step 1: Inventory the flush sites in `phoenix_replay.js`.** Open `priv/static/assets/phoenix_replay.js`. Confirm these are the only sites that POST to `/events` or behave conditionally on a session being held:

  | Line | Symbol | What it does |
  |---|---|---|
  | ~234 | `ensureSession()` | POSTs `/session`, sets `sessionToken` |
  | ~267 | `flush()` | POSTs `/events` batches, requires `sessionToken` |
  | ~302 | `scheduleFlush()` | Starts the 5s flush timer |
  | ~309 | `cancelFlushTimer()` | Stops the 5s flush timer |
  | ~315 | `startRecording()` | `ensureSession` → `createRecorder` → `scheduleFlush` |
  | ~335 | `stopRecording()` | `recorder.stop` → `cancelFlushTimer` → final `flush()` |
  | ~348 | `resetRecording()` | tears down + `startRecording` |
  | ~380 | `report()` | `flush()` → POST `/submit` → close |
  | ~431 | `flushOnUnload()` | keepalive POST `/events` |
  | ~877 | `init` autostart | `if (!onDemand) await client.start()` |

- [ ] **Step 2: Confirm rrweb capture is independent of session state.** `createRecorder({buffer})` (~line 175) only writes to the in-memory buffer. The buffer is filled regardless of whether a session token exists. This is the key invariant that lets `:passive` work — capture happens, transport doesn't.

- [ ] **Step 3: Note the existing `:on_demand` idle invariant.** Read lines ~877–886. Today, `:on_demand` already starts in an idle state (no `client.start()` call at autoMount unless the storage flag says auto-resume). This is the closest existing analog to our new `:passive` state. The Phase 1 change effectively makes that idle behavior the default for **all** widgets, just with the additional twist that the recorder runs against the buffer continuously rather than waiting for `startRecording()`.

No commit — Task 1 is read-only.

---

## Task 2 — Ring buffer with time-window eviction

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js:152-167`
- Create: `test/js/ring_buffer_test.js`

The existing `createRingBuffer(max)` evicts by event count. We add an optional `windowMs` and an injectable `nowFn` so the same factory can be tested deterministically and used in production (where `nowFn` defaults to `Date.now`).

- [ ] **Step 1: Write the failing test.** Create `test/js/ring_buffer_test.js`:

  ```js
  // Pure-function test for createRingBuffer time-window eviction.
  // Run with: node test/js/ring_buffer_test.js
  // No test framework — exits 1 on first failure.

  const fs = require("fs");
  const path = require("path");
  const vm = require("vm");

  const src = fs.readFileSync(
    path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_replay.js"),
    "utf8"
  );

  // Build a fake browser global so the IIFE wires onto it.
  const sandbox = { window: {}, document: undefined, console };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);

  // Reach the internal factory via the test hook we add in Task 2 step 3.
  const { createRingBuffer } = sandbox.window.PhoenixReplay._testInternals;

  function assert(cond, msg) {
    if (!cond) {
      console.error("FAIL:", msg);
      process.exit(1);
    }
  }

  // --- count-based cap (existing behavior preserved) ---
  {
    let now = 0;
    const buf = createRingBuffer({ maxEvents: 3, windowMs: null, nowFn: () => now });
    buf.push({ k: "a" });
    buf.push({ k: "b" });
    buf.push({ k: "c" });
    buf.push({ k: "d" }); // evicts "a" by count cap
    const drained = buf.drain();
    assert(drained.length === 3, "count cap keeps 3");
    assert(drained[0].k === "b", "head 'a' evicted by count cap");
  }

  // --- time-window eviction ---
  {
    let now = 1000;
    const buf = createRingBuffer({ maxEvents: 100, windowMs: 60000, nowFn: () => now });
    buf.push({ k: "old" });          // t=1000
    now = 30000;
    buf.push({ k: "mid" });          // t=30000
    now = 90000;                     // 90s elapsed; "old" is 89s old → evicted on next push
    buf.push({ k: "fresh" });        // t=90000
    const drained = buf.drain();
    assert(drained.length === 2, `time-window keeps 2, got ${drained.length}`);
    assert(drained[0].k === "mid", "head 'old' evicted by time window");
    assert(drained[1].k === "fresh", "fresh retained");
  }

  // --- drain returns events without their wrapper timestamps ---
  {
    let now = 0;
    const buf = createRingBuffer({ maxEvents: 10, windowMs: null, nowFn: () => now });
    buf.push({ type: 2, data: { x: 1 } });
    const out = buf.drain();
    assert(out.length === 1, "drain count");
    assert(out[0].type === 2, "drain returns the original event shape");
    assert(out[0].data.x === 1, "drain preserves nested fields");
  }

  // --- size() reflects current contents ---
  {
    let now = 0;
    const buf = createRingBuffer({ maxEvents: 10, windowMs: null, nowFn: () => now });
    buf.push({ k: 1 });
    buf.push({ k: 2 });
    assert(buf.size() === 2, "size after pushes");
    buf.drain();
    assert(buf.size() === 0, "size after drain");
  }

  console.log("OK ring_buffer_test (4 cases)");
  ```

- [ ] **Step 2: Run the test, verify it fails with "createRingBuffer is undefined" (or undefined `_testInternals`).**

  Run: `node test/js/ring_buffer_test.js`
  Expected: process exits non-zero with an error referring to `_testInternals` or `createRingBuffer`.

- [ ] **Step 3: Refactor `createRingBuffer` and expose it via `_testInternals`.** Edit `priv/static/assets/phoenix_replay.js`:

  Replace the existing `function createRingBuffer(max) { ... }` block (~lines 152-167) with:

  ```js
  // Bounded buffer with two independent eviction policies, applied on push:
  //   * count cap (`maxEvents`) — drops oldest when length exceeds the cap
  //   * time window (`windowMs`) — drops head while head's timestamp is
  //     older than `now - windowMs`
  // Either or both may be active. `nowFn` is injectable for tests; defaults
  // to `Date.now`. Each pushed event is wrapped as `{ event, ts }` internally
  // and unwrapped on `drain()` so callers see the original event shape.
  function createRingBuffer({ maxEvents, windowMs, nowFn } = {}) {
    const now = typeof nowFn === "function" ? nowFn : () => Date.now();
    const cap = typeof maxEvents === "number" && maxEvents > 0 ? maxEvents : null;
    const window = typeof windowMs === "number" && windowMs > 0 ? windowMs : null;
    const arr = [];

    function evictByTime() {
      if (!window) return;
      const cutoff = now() - window;
      while (arr.length > 0 && arr[0].ts < cutoff) arr.shift();
    }

    function evictByCount() {
      if (!cap) return;
      if (arr.length > cap) arr.splice(0, arr.length - cap);
    }

    return {
      push(evt) {
        arr.push({ event: evt, ts: now() });
        evictByTime();
        evictByCount();
      },
      drain() {
        evictByTime();
        const out = arr.splice(0, arr.length).map((entry) => entry.event);
        return out;
      },
      size() {
        evictByTime();
        return arr.length;
      },
    };
  }
  ```

- [ ] **Step 4: Update existing call sites + add `_testInternals` exposure.**

  In the same file, find the existing call at `~line 213`:

  ```js
  const buffer = createRingBuffer(cfg.maxBufferedEvents);
  ```

  Replace with the new options-object form, preserving today's count-cap behavior **and** adding the new window:

  ```js
  const buffer = createRingBuffer({
    maxEvents: cfg.maxBufferedEvents,
    windowMs: cfg.bufferWindowMs,
  });
  ```

  Add the matching default in the `DEFAULTS` map (~line 15) — insert after `maxBufferedEvents`:

  ```js
    maxBufferedEvents: 10_000, // ring-buffer cap
    bufferWindowMs: 60_000,    // ring-buffer time window (ADR-0006 Phase 1)
  ```

  Expose the factory for tests. Add at the very end of the IIFE, just before `if (typeof global !== "undefined") global.PhoenixReplay = PhoenixReplay;` (~line 972):

  ```js
    // Internal factory exposed only for tests. Do not use from host code —
    // the surface may change without a CHANGELOG entry.
    PhoenixReplay._testInternals = { createRingBuffer };
  ```

- [ ] **Step 5: Run the test to verify it passes.**

  Run: `node test/js/ring_buffer_test.js`
  Expected: prints `OK ring_buffer_test (4 cases)` and exits 0.

- [ ] **Step 6: Commit.**

  ```bash
  git add priv/static/assets/phoenix_replay.js test/js/ring_buffer_test.js
  git commit -m "feat(js): ring buffer time-window eviction + Node test harness

  createRingBuffer now accepts { maxEvents, windowMs, nowFn }. Time
  window evicts head whose ts is older than now() - windowMs; the
  existing count cap is preserved. Default windowMs of 60s landed in
  DEFAULTS. Pure-function test runs via plain node (no framework).

  Phase 1 of ADR-0006 — recorder still flushes today; the windowed
  buffer is the substrate the next task switches the lifecycle onto.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 3 — `:passive` / `:active` state machine; remove auto-flush from passive

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js:206-487` (`createClient` body)

The recorder already starts capturing into the buffer on init (rrweb is wired immediately via `createRecorder`). The change is to **never run `ensureSession` or `scheduleFlush` until the user transitions to `:active`** — and to make `flushOnUnload` a no-op in `:passive` (no session token, nothing to send).

- [ ] **Step 1: Add the `state` variable + tag the existing flow.** Find the `let recording = false;` line (~line 219) and the variables right above it. Insert a `state` variable + helpers next to them:

  ```js
      let sessionToken = null;
      let sessionStartedAtMs = null;
      let seq = 0;
      let flushTimer = null;
      let recorder = null;
      let recording = false;

      // ADR-0006 lifecycle states. `:passive` — ring buffer fills locally,
      // no /session, no /events. `:active` — server-flushed session
      // (today's :continuous behavior, now reached only via startRecording
      // or report-now drain). Default :passive at mount; transitions:
      //   :passive -> :active   on startRecording()
      //   :active  -> :passive  on stopRecording() / report() teardown
      let state = "passive";
  ```

- [ ] **Step 2: Move rrweb capture initialization out of `startRecording` into `createClient` body.** rrweb runs continuously now — even before any `startRecording` call — so events accumulate in the ring buffer during `:passive`.

  Find `startRecording()` (~line 315). Note that `recorder = createRecorder({ buffer });` lives inside it. We move that to right after the state declaration in step 1 so capture begins at client init:

  ```js
      let state = "passive";

      // Begin rrweb capture immediately into the ring buffer. The buffer
      // is bounded by time + count, so this is safe to leave running for
      // the lifetime of the page mount. `:passive` means the buffer is
      // never drained to the server until the user reports.
      recorder = createRecorder({ buffer });
  ```

  Then inside `startRecording()` (~line 315), remove the `recorder = createRecorder({ buffer });` line — capture is already running. The function becomes:

  ```js
      async function startRecording() {
        if (state === "active") return;
        // A prior `stopRecording` left the old token alive so a
        // subsequent `report()` could submit the drained tail. Starting
        // a *new* reproduction abandons that tail and mints fresh.
        sessionToken = null;
        sessionStartedAtMs = null;
        seq = 0;
        // Drop any buffered passive-state events — the user wants a
        // clean reproduction starting now (ADR-0006 D1).
        buffer.drain();
        await ensureSession();
        state = "active";
        recording = true;
        storageWrite(STORAGE_KEYS.RECORDING, "active");
        scheduleFlush();
      }
  ```

  Note the `buffer.drain()` call: the existing buffer (filled passively) is discarded so the active-recording session begins with an empty buffer. This matches ADR-0006 Q-A — Record-and-Report starts fresh.

- [ ] **Step 3: Update `stopRecording`, `resetRecording`, and `report` to set `state = "passive"` on teardown.**

  `stopRecording()` (~line 335): after `cancelFlushTimer()` + final `flush()`, set state. Keep `recorder` running (we never tear down rrweb capture in :passive):

  ```js
      async function stopRecording() {
        if (state !== "active") return;
        // Note: we do NOT call recorder.stop() — rrweb stays running so
        // the ring buffer keeps filling for any subsequent Report Now.
        recording = false;
        state = "passive";
        storageClear(STORAGE_KEYS.RECORDING);
        cancelFlushTimer();
        await flush();
        // Drop the session token now that we've drained — the next
        // startRecording will mint fresh.
        sessionToken = null;
        sessionStartedAtMs = null;
        seq = 0;
        storageClear(STORAGE_KEYS.TOKEN);
      }
  ```

  `resetRecording()` (~line 348): conceptually the same as stop+start. Update to use the state machine:

  ```js
      async function resetRecording() {
        if (state !== "active") return;
        recording = false;
        state = "passive";
        buffer.drain();
        sessionToken = null;
        sessionStartedAtMs = null;
        seq = 0;
        storageClear(STORAGE_KEYS.TOKEN);
        storageClear(STORAGE_KEYS.RECORDING);
        await startRecording();
      }
  ```

  `report()` (~line 380): after the existing teardown block, set state. The existing branch that auto-restarts in `:continuous` no longer fires — `:passive` is the post-report state:

  ```js
      async function report({ description, severity, metadata = {}, jamLink = null, extras = {} }) {
        // Flush any buffered events first so the submit record captures the
        // full tail of the session.
        await flush();

        await postJson(`${basePath}${cfg.submitPath}`, {
          description,
          severity: severity || cfg.defaultSeverity,
          metadata,
          jam_link: jamLink,
          extras,
        }, {
          csrfToken,
          csrfHeader: cfg.csrfHeader,
          sessionToken,
          tokenHeader: cfg.tokenHeader,
        });

        // Tear down to :passive. The ring buffer keeps filling for any
        // subsequent Report Now (ADR-0006 — no auto-restart of active).
        recording = false;
        state = "passive";
        cancelFlushTimer();
        sessionToken = null;
        sessionStartedAtMs = null;
        seq = 0;
        storageClear(STORAGE_KEYS.TOKEN);
        storageClear(STORAGE_KEYS.RECORDING);
      }
  ```

- [ ] **Step 4: Gate `flushOnUnload` on `state === "active"`.** Find `flushOnUnload()` (~line 431). Add the state guard at the top:

  ```js
      function flushOnUnload() {
        if (state !== "active") return;  // :passive has nothing to ship
        if (unloadFired) return;
        unloadFired = true;
        if (!sessionToken) return;
        // ... rest unchanged
      }
  ```

- [ ] **Step 5: Remove `client.start()` from autoMount.** Find the init orchestrator (~lines 877–886):

  ```js
        installTriggerListener();
        installUnloadListener();
        if (!onDemand) {
          await client.start();
        } else if (storageRead(STORAGE_KEYS.RECORDING) === "active") {
          handleStartFromPanel();
        }
  ```

  Replace with:

  ```js
        installTriggerListener();
        installUnloadListener();
        // ADR-0006: no auto-start of :active on mount. The widget begins
        // in :passive — rrweb is running, ring buffer is filling, but
        // nothing reaches the server until the user reports. The
        // session-continuity auto-resume (ADR-0003) only re-engages when
        // a prior :active session was in flight before navigation.
        if (storageRead(STORAGE_KEYS.RECORDING) === "active") {
          handleStartFromPanel();
        }
  ```

- [ ] **Step 6: Verify by running existing Elixir tests + a manual smoke.**

  ```bash
  cd ~/Dev/phoenix_replay && mix test
  ```
  Expected: all green. Existing tests don't cover JS lifecycle but they exercise the controller layer that this task does not touch.

  Then a quick manual sanity check (no commit yet — bigger smoke is Task 6):

  ```bash
  cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
     ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js
  cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force
  ```

  Restart the demo's app server via Tidewave (reason: `deps_changed`). Then in a browser at `http://localhost:4006/demo/continuous`, open DevTools Network tab + reload. **Expected**: NO `/session`, NO `/events` POSTs at page load. Click around; still no POSTs. (We're not yet wiring the new entry UX, so the existing widget behavior of "click button → submit form → send" still works through the legacy `report()` flow which now goes through `:passive` → `:active` would require startRecording first — at this Phase the legacy path **is broken** for `:continuous` widgets because they no longer auto-`start()`. That's expected for one phase; Task 4's `/report` endpoint plus the Phase 2 entry UX restore submission. Document that in CHANGELOG step.)

- [ ] **Step 7: Commit.**

  ```bash
  git add priv/static/assets/phoenix_replay.js
  git commit -m "feat(js): :passive/:active state machine; remove auto-flush at mount

  rrweb begins capturing into the ring buffer at client init regardless
  of state. :passive is the new default — no /session POST, no /events
  POST, no flushOnUnload. startRecording() transitions to :active and
  preserves today's server-flushed behavior (handshake + 5s flush
  timer). Teardown (stopRecording / resetRecording / report) returns
  to :passive without tearing down rrweb so the buffer keeps filling.

  Known interim breakage: the existing widget panel's submit form
  routes through report() which now requires :active. With autoMount
  no longer calling client.start(), :continuous widgets need the new
  entry UX (Phase 2) or an explicit startRecording() to submit. The
  /report endpoint added in the next task gives Path A its own ingest
  route that doesn't depend on the legacy report() path.

  Phase 1 of ADR-0006.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 4 — `POST /report` endpoint + router macro

**Files:**
- Create: `lib/phoenix_replay/controller/report_controller.ex`
- Modify: `lib/phoenix_replay/router.ex`
- Create: `test/phoenix_replay/controller/report_controller_test.exs`

The endpoint accepts `{description, severity, events, metadata, jam_link}` in a single POST. It mints a synthetic session via the existing storage adapter, persists the events as a single `append_events/3` call (`seq: 0`), and finalizes via `submit/3` — all in the controller. No `Session` GenServer is started (the session is born and closed in the same request, so there's nothing for the supervisor to manage).

- [ ] **Step 1: Write the failing controller test.** Create `test/phoenix_replay/controller/report_controller_test.exs`:

  ```elixir
  defmodule PhoenixReplay.ReportControllerTest do
    use ExUnit.Case, async: false

    import Plug.Conn
    import Phoenix.ConnTest

    alias PhoenixReplay.Test.RecordingStorage

    @identity %{kind: :user, id: "u-test", attrs: %{}}

    setup do
      start_supervised!(RecordingStorage)

      prior_storage = Application.get_env(:phoenix_replay, :storage)
      Application.put_env(:phoenix_replay, :storage, {RecordingStorage, []})

      on_exit(fn ->
        case prior_storage do
          nil -> Application.delete_env(:phoenix_replay, :storage)
          v -> Application.put_env(:phoenix_replay, :storage, v)
        end
      end)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:phoenix_replay_identity, @identity)
        |> Phoenix.Controller.accepts(["json"])

      %{conn: conn}
    end

    describe "POST /report" do
      test "happy path: events + description in one POST → submit recorded", %{conn: conn} do
        events = [
          %{"type" => 2, "timestamp" => 1, "data" => %{"x" => 1}},
          %{"type" => 3, "timestamp" => 2, "data" => %{"x" => 2}}
        ]

        params = %{
          "description" => "buffer-attached report",
          "severity" => "medium",
          "events" => events,
          "metadata" => %{"page" => "/demo"},
          "jam_link" => nil
        }

        conn = PhoenixReplay.ReportController.create(conn, params)

        assert conn.status == 201
        body = json_response(conn, 201)
        assert body["ok"] == true
        assert is_binary(body["id"])

        assert {session_id, submit_params, identity} = RecordingStorage.last_submit()
        assert is_binary(session_id)
        assert submit_params["description"] == "buffer-attached report"
        assert submit_params["severity"] == "medium"
        assert submit_params["metadata"]["page"] == "/demo"
        assert identity == @identity
      end

      test "missing description → 422", %{conn: conn} do
        params = %{"events" => []}

        conn = PhoenixReplay.ReportController.create(conn, params)

        assert conn.status == 422
        assert %{"error" => "missing_description"} = json_response(conn, 422)
      end

      test "events defaults to [] when omitted (text-only)", %{conn: conn} do
        conn =
          PhoenixReplay.ReportController.create(conn, %{"description" => "no events"})

        assert conn.status == 201
        assert {_session_id, _params, _identity} = RecordingStorage.last_submit()
      end

      test "severity defaults to medium when omitted", %{conn: conn} do
        conn =
          PhoenixReplay.ReportController.create(conn, %{"description" => "no sev"})

        assert conn.status == 201
        assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()
        assert submit_params["severity"] == "medium"
      end

      test "extras and jam_link forwarded to submit_params", %{conn: conn} do
        params = %{
          "description" => "with extras",
          "extras" => %{"audio_url" => "s3://bucket/clip"},
          "jam_link" => "https://jam.dev/c/abc"
        }

        conn = PhoenixReplay.ReportController.create(conn, params)

        assert conn.status == 201
        assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()
        assert submit_params["extras"]["audio_url"] == "s3://bucket/clip"
        assert submit_params["jam_link"] == "https://jam.dev/c/abc"
      end
    end
  end
  ```

- [ ] **Step 2: Run the test, verify all cases fail with `module not loaded`.**

  Run: `mix test test/phoenix_replay/controller/report_controller_test.exs`
  Expected: 5 failures, each citing `PhoenixReplay.ReportController.create/2 is undefined`.

- [ ] **Step 3: Implement the controller.** Create `lib/phoenix_replay/controller/report_controller.ex`:

  ```elixir
  defmodule PhoenixReplay.ReportController do
    @moduledoc false
    # POST /report — single-shot ingest for ADR-0006 Path A (Report Now).
    #
    # The widget sits in :passive state with a ring buffer. When the user
    # clicks Report Now, the client uploads {description, severity,
    # events, metadata, jam_link, extras} in one request. The controller
    # mints a synthetic session, persists the events as a single batch
    # (seq=0), and finalizes via submit/3 — all without the long-lived
    # Session GenServer machinery used by the multi-batch :active flow.

    use Phoenix.Controller, formats: [:json]

    alias PhoenixReplay.{Hook, Scrub, Storage}
    alias PhoenixReplay.Plug.Identify

    @default_severity "medium"

    def create(conn, params) do
      identity = Identify.fetch(conn) || %{kind: :anonymous}

      with {:ok, description} <- fetch_description(params),
           events when is_list(events) <- Map.get(params, "events", []),
           {:ok, session_id} <- Storage.Dispatch.start_session(identity, DateTime.utc_now()),
           :ok <- maybe_append(session_id, events) do
        host_metadata = Hook.invoke(:metadata, conn) || %{}
        client_metadata = Map.get(params, "metadata", %{})

        merged_metadata =
          client_metadata
          |> stringify_keys()
          |> Map.merge(stringify_keys(host_metadata))

        submit_params = %{
          "description" => description,
          "severity" => Map.get(params, "severity") || @default_severity,
          "metadata" => merged_metadata,
          "jam_link" => Map.get(params, "jam_link"),
          "extras" => stringify_keys(Map.get(params, "extras") || %{})
        }

        case Storage.Dispatch.submit(session_id, submit_params, identity) do
          {:ok, feedback} ->
            conn
            |> put_status(:created)
            |> json(%{ok: true, id: fetch_id(feedback)})

          {:error, changeset} ->
            send_error(conn, 422, "submit_failed", inspect(changeset))
        end
      else
        {:error, :missing_description} ->
          send_error(conn, 422, "missing_description")

        {:error, :events_not_list} ->
          send_error(conn, 400, "events_must_be_list")

        {:error, reason} ->
          send_error(conn, 500, "report_failed", inspect(reason))
      end
    end

    defp fetch_description(params) do
      case Map.get(params, "description") do
        d when is_binary(d) and byte_size(d) > 0 -> {:ok, d}
        _ -> {:error, :missing_description}
      end
    end

    # Empty events list is valid — text-only Report Now is supported.
    # Non-empty list is scrubbed and persisted as a single batch.
    defp maybe_append(_session_id, []), do: :ok

    defp maybe_append(session_id, events) when is_list(events) do
      scrubbed = Scrub.scrub_batch(events)

      case Storage.Dispatch.append_events(session_id, 0, scrubbed) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end

    defp maybe_append(_session_id, _other), do: {:error, :events_not_list}

    defp fetch_id(%{id: id}), do: id
    defp fetch_id(%{"id" => id}), do: id
    defp fetch_id(_), do: nil

    defp stringify_keys(map) when is_map(map) do
      Map.new(map, fn {k, v} -> {to_string(k), v} end)
    end

    defp stringify_keys(other), do: other

    defp send_error(conn, status, code, detail \\ nil) do
      body = if detail, do: %{error: code, detail: detail}, else: %{error: code}

      conn
      |> put_status(status)
      |> json(body)
      |> halt()
    end
  end
  ```

- [ ] **Step 4: Run the test, verify all 5 cases pass.**

  Run: `mix test test/phoenix_replay/controller/report_controller_test.exs`
  Expected: `5 tests, 0 failures`.

- [ ] **Step 5: Wire the route into the macro.** Edit `lib/phoenix_replay/router.ex`. In the `feedback_routes/2` macro body (after the existing three `post`s), add:

  ```elixir
        post "/report", PhoenixReplay.ReportController, :create
  ```

  The full block after the change:

  ```elixir
        scope path, alias: false do
          pipe_through [PhoenixReplay.Plug.Identify]

          post "/session", PhoenixReplay.SessionController, :create
          post "/events", PhoenixReplay.EventsController, :append
          post "/submit", PhoenixReplay.SubmitController, :create
          post "/report", PhoenixReplay.ReportController, :create
        end
  ```

  Also update the `@moduledoc` block (the "Mounts three POST endpoints…" line ~line 18) to read "Mounts four POST endpoints" and add a fourth bullet:

  ```
      * `POST /report`  — Path A single-shot ingest (events + description
        in one body); no prior session required.
  ```

- [ ] **Step 6: Run the full test suite.**

  Run: `mix test`
  Expected: green. The new route is mounted via the macro; no existing test exercises it directly, but compile must succeed and the new controller test still passes.

- [ ] **Step 7: Commit.**

  ```bash
  git add lib/phoenix_replay/controller/report_controller.ex \
          lib/phoenix_replay/router.ex \
          test/phoenix_replay/controller/report_controller_test.exs
  git commit -m "feat(controller): POST /report — single-shot Path A ingest

  ReportController mints a synthetic session via Storage.Dispatch,
  appends events as one batch (seq=0), and finalizes via submit/3 —
  all in one HTTP request, no Session GenServer involvement. Empty
  events list is valid (text-only). Description is required;
  severity defaults to medium.

  feedback_routes/2 macro mounts the new POST under the same prefix
  as /session, /events, /submit. Hosts on feedback_routes \"/feedback\"
  get /feedback/report automatically.

  Phase 1 of ADR-0006.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 5 — Cross-repo deps refresh + manual smoke

**Files:** none modified in phoenix_replay. Smoke uses the demo host.

- [ ] **Step 1: Copy the modified JS into the demo's deps/.**

  ```bash
  cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js \
     ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js
  ```

- [ ] **Step 2: Force-recompile and copy compiled controller + router beam.**

  ```bash
  cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force
  ```

  Expected: clean compile with the new controller.

- [ ] **Step 3: Restart the demo app server.** Use Tidewave's `restart_app_server` tool with reason `deps_changed`.

- [ ] **Step 4: Smoke test in browser — confirm no passive-state network calls.**

  Open `http://localhost:4006/demo/continuous` in a browser with DevTools Network tab open. Reload.

  **Expected (PASS):**
  - Page loads.
  - DevTools Network tab shows asset requests (CSS/JS) but **no** POST to `/api/feedback/session` and **no** POST to `/api/feedback/events`.
  - Click around the page for ~10s. Still no POSTs.
  - `window.PhoenixReplay.isRecording()` in the DevTools console returns `false`.
  - `window.PhoenixReplay._testInternals.createRingBuffer` is defined (sanity).

- [ ] **Step 5: Smoke test the new `/report` endpoint manually from DevTools.**

  In the same DevTools console, run:

  ```js
  fetch("/api/feedback/report", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": document.querySelector('meta[name="csrf-token"]').content
    },
    body: JSON.stringify({
      description: "phase 1 smoke — text only",
      severity: "low",
      events: [],
      metadata: { page: location.pathname }
    })
  }).then(r => r.json()).then(console.log);
  ```

  **Expected**: response logs `{ ok: true, id: "<some-id>" }`. The host's storage backend records the feedback row. Then run again with a non-empty events array (any plausible rrweb-shaped objects):

  ```js
  fetch("/api/feedback/report", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": document.querySelector('meta[name="csrf-token"]').content
    },
    body: JSON.stringify({
      description: "phase 1 smoke — with fake events",
      severity: "low",
      events: [
        { type: 2, timestamp: Date.now(), data: { x: 1 } },
        { type: 3, timestamp: Date.now() + 1, data: { x: 2 } }
      ]
    })
  }).then(r => r.json()).then(console.log);
  ```

  **Expected**: same `{ ok: true, id: ... }` response. Inspect the demo admin (e.g., the AdminLive route if mounted) — the feedback row should exist with both events attached.

- [ ] **Step 6: Smoke test the on-demand-float page (regression check).**

  Open `http://localhost:4006/demo/on-demand-float`.
  - Click the floating "Report issue" button → confirm the existing panel opens.
  - Click "Record and report" → DevTools Network shows a `/session` POST then a `/events` POST every 5s. `window.PhoenixReplay.isRecording()` returns `true`.
  - Click Stop in the pill → `/events` POSTs stop. `isRecording()` returns `false`.
  - The panel opens to the form. Fill description, click Send → `/submit` POST fires → `{ok: true}`.

  **Expected**: behavior matches today's `:on_demand` flow. (The Phase 2 work will replace this UX; for Phase 1 we only need it to keep working at the JS-lifecycle level.)

- [ ] **Step 7: Document any deviations from expected output.** If any smoke step fails or shows unexpected behavior, do NOT proceed to Task 6. Append a `## Smoke deviations` section to this plan describing what happened, then triage. The bar for Task 6 is "all 6 smoke steps PASS as written".

---

## Task 6 — CHANGELOG + commit smoke result

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read the current `CHANGELOG.md` `## [Unreleased]` section.** Append the Phase 1 block immediately after the existing "Mode-aware panel addons (2026-04-25)" section so the chronological ordering reads "Mode-aware → ADR-0006 Phase 1".

- [ ] **Step 2: Add the entry.** Insert the following block in `CHANGELOG.md` directly after the "Mode-aware panel addons (2026-04-25)" section:

  ```markdown
  ### ADR-0006 Phase 1 — capture model + Path A ingest (2026-04-25)

  Recorder restructured around a `:passive` / `:active` state machine.
  In `:passive` (the new default at widget mount) rrweb continues to
  capture into a sliding ring buffer (default 60s window via the new
  `bufferWindowMs` option), but **no** `/session` or `/events` POST
  is issued. The 5-second flush timer never starts, and
  `flushOnUnload` is a no-op. The server is unaware of the user's
  page activity until they explicitly report.

  `:active` is reached via `startRecording()` and behaves as the old
  `:continuous` mode did: handshake `/session`, periodic `/events`
  flushes, finalize via `/submit`. Teardown (`stopRecording` /
  `report`) returns the recorder to `:passive` without tearing down
  rrweb, so the buffer immediately starts filling again for any
  subsequent Report Now.

  New `POST /report` endpoint mounted by `feedback_routes/2`
  (alongside `/session` `/events` `/submit`) accepts the full Path A
  payload — `{description, severity, events, metadata, jam_link,
  extras}` — in a single request. The controller mints a synthetic
  session via `Storage.Dispatch.start_session/2`, persists events as
  one batch, and finalizes immediately. No long-lived `Session`
  GenServer is involved.

  **Interim regression**: with autoMount no longer calling
  `client.start()`, the existing widget panel's "Send" button (which
  routes through the legacy `report()` flow) is broken for widgets
  that previously relied on `:continuous` auto-start. The new
  `/report` endpoint is the substrate for the Phase 2 entry UX which
  restores submission. The old `/submit` endpoint is unchanged and
  still works for `:active` sessions reached via `startRecording()`.

  Internal: `_testInternals.createRingBuffer` exposed for the
  `node test/js/ring_buffer_test.js` smoke. `bufferWindowMs` joins
  `maxBufferedEvents` in `DEFAULTS`.
  ```

- [ ] **Step 3: Run the full test suite one more time.**

  ```bash
  cd ~/Dev/phoenix_replay && mix test && node test/js/ring_buffer_test.js
  ```
  Expected: Elixir green, JS prints `OK ring_buffer_test (4 cases)`.

- [ ] **Step 4: Commit.**

  ```bash
  git add CHANGELOG.md
  git commit -m "docs(changelog): ADR-0006 Phase 1 — capture model + /report

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step 5: Update the demo's mix.lock if you push the library.** The demo's mix.lock pins phoenix_replay to a SHA. If the user wants to see Phase 1 in the demo across restarts (rather than via the local cp + force-recompile path), they need to push library commits and run `mix deps.update phoenix_replay` in the demo. Do NOT push or update from this plan — leave it for the user to decide.

---

## Risks (from the spec, surfaced for the implementer)

- **The legacy widget panel "Send" button is interim-broken** for `:continuous`-style widgets after Task 3. This is documented in the CHANGELOG and is the expected one-phase gap. Phase 2 (entry UX) restores submission via the new `/report` endpoint.
- **`bufferWindowMs` is now a defaulted option** but no JS test framework exists. The single Node-based smoke for the pure ring-buffer factory is the only automated coverage; the rest of the lifecycle relies on the manual smoke matrix in Task 5.
- **`flushOnUnload` was a critical tail-recovery path for `:active`.** The state guard at the top is a single-line change but worth reviewing carefully — a regression here loses the last 5s of `:active` events on unload.

## Definition of Done

- [ ] All Task 6 commits land cleanly on `main`.
- [ ] `mix test` green; `node test/js/ring_buffer_test.js` green.
- [ ] Smoke matrix Task 5 steps 4–6 all PASS in browser on `localhost:4006`.
- [ ] CHANGELOG entry merged.
- [ ] No blocked items in this plan's task list.

Phase 2 (two-option entry UX + Path A wiring through the new endpoint) starts from this Definition of Done.
