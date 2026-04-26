// PhoenixReplay — in-app feedback widget client.
//
// Entry point: `PhoenixReplay.init(opts)`.
//
// Captures rrweb events into a bounded ring buffer, handshakes a server-
// signed session token, flushes batches to /events, and finalizes via
// /submit on user report. Designed to degrade gracefully when rrweb is
// not loaded (metadata-only reports still work).
//
// The widget is pure ES2020; no bundler required.

(function (global) {
  "use strict";

  const DEFAULTS = {
    // Endpoints relative to `basePath` (set at init time from the
    // mount element's data-base-path attribute).
    sessionPath: "/session",
    eventsPath: "/events",
    submitPath: "/submit",
    reportPath: "/report",
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
    showSeverity: false,
    allowPaths: ["report_now", "record_and_report"],
    severities: ["info", "low", "medium", "high", "critical"],
    defaultSeverity: "medium",
  };

  const VALID_POSITIONS = new Set(["bottom_right", "bottom_left", "top_right", "top_left"]);

  // Shared by renderToggle + renderPill — both elements use the same
  // four-corner preset family. If VALID_POSITIONS ever grows, the CSS
  // `.phx-replay-{toggle,pill}--*` preset rules must grow in lock-step.
  function positionClass(kind, cfg) {
    const p = VALID_POSITIONS.has(cfg.position) ? cfg.position : "bottom_right";
    return `phx-replay-${kind}--${p.replace(/_/g, "-")}`;
  }

  // Panel screens. Kept as named constants so typos become
  // ReferenceErrors rather than silent "nothing shows" bugs.
  const SCREENS = {
    CHOOSE: "choose",
    IDLE_START: "idle_start",
    ERROR: "error",
    FORM: "form",                 // Path B describe step (post-review)
    PATH_A_FORM: "path_a_form",   // Path A single-step submit
    REVIEW: "review",             // Path B post-recording review (mini-player + Re-record + Continue)
  };

  // Panel addon registry. Each entry: { id, slot, mount, modes }. `mount(ctx)`
  // is invoked once per panel-mount; it returns optional { beforeSubmit,
  // onPanelClose } hooks. The orchestrator collects beforeSubmit return
  // values and merges all `extras` into the report() body.
  //
  // TODO(js-test-infra): the registration → mount → beforeSubmit → extras
  // pipeline has no JS unit test in this repo. The contract is exercised
  // end-to-end by the audio narration smoke flow in ash_feedback's Phase 2d
  // checklist. Add Vitest/JSDOM coverage when the recurring JS-test-infra
  // debt is paid (separate ADR).
  const PANEL_ADDONS = new Map();  // id -> { id, slot, mount, modes }

  // ---- transport ---------------------------------------------------------

  async function postJson(url, body, { csrfToken, sessionToken, tokenHeader, csrfHeader, gzip = false }) {
    // gzip default is off: Phoenix's default JSON body parser does not
    // handle `content-encoding: gzip`. Hosts that install a gzip-aware
    // body reader can pass `gzip: true` at init time. Revisit in Phase 3+.
    const headers = { "content-type": "application/json" };
    if (csrfToken) headers[csrfHeader] = csrfToken;
    if (sessionToken) headers[tokenHeader] = sessionToken;

    let bodyToSend = JSON.stringify(body);

    if (gzip && typeof CompressionStream !== "undefined") {
      const stream = new Blob([bodyToSend]).stream().pipeThrough(new CompressionStream("gzip"));
      bodyToSend = await new Response(stream).blob();
      headers["content-encoding"] = "gzip";
    }

    const res = await fetch(url, { method: "POST", headers, body: bodyToSend, credentials: "same-origin" });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new PhoenixReplayError(res.status, text || res.statusText);
    }
    return res.headers.get("content-type")?.includes("application/json")
      ? res.json()
      : null;
  }

  class PhoenixReplayError extends Error {
    constructor(status, msg) {
      super(`[${status}] ${msg}`);
      this.status = status;
    }
  }

  // Raised when the client tries to resume a session (via the
  // sessionStorage-cached token) but the server responds
  // `resumed: false` — the previous session is stale. In `:passive`
  // state the client recovers silently; for Path B (`:active` session
  // already in progress) this surfaces as the panel error screen
  // because losing the chain violates explicit consent.
  class PhoenixReplaySessionInterruptedError extends Error {
    constructor() {
      super("Previous recording was interrupted");
      this.name = "PhoenixReplaySessionInterruptedError";
    }
  }

  // `sessionStorage` is tab-local, survives reloads + same-tab
  // navigations, gone on tab close. Matches ADR-0002 OQ4's tab-local
  // session scope — the right lifetime for a recording session that
  // should never bleed between tabs.
  const STORAGE_KEYS = {
    TOKEN: "phx_replay_token",
    RECORDING: "phx_replay_recording",
  };

  function hasStorage() {
    try {
      return typeof window !== "undefined" && !!window.sessionStorage;
    } catch {
      return false;
    }
  }

  function storageRead(key) {
    if (!hasStorage()) return null;
    try { return window.sessionStorage.getItem(key); } catch { return null; }
  }

  function storageWrite(key, value) {
    if (!hasStorage()) return;
    try { window.sessionStorage.setItem(key, value); } catch {
      // QuotaExceededError, Safari private mode, etc. — continuity
      // silently degrades to per-page behavior. One-time warn so it
      // doesn't spam the console on every flush.
      if (!storageWrite._warned) {
        storageWrite._warned = true;
        console.warn("[PhoenixReplay] sessionStorage write failed; session continuity disabled for this tab");
      }
    }
  }

  function storageClear(key) {
    if (!hasStorage()) return;
    try { window.sessionStorage.removeItem(key); } catch {}
  }

  // ---- ring buffer -------------------------------------------------------

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
      // Non-destructive read for "snapshot, POST, only drain on success"
      // patterns — used by client.reportNow so a failed POST doesn't
      // silently lose captured context (a retry sends events: [] otherwise).
      snapshot() {
        evictByTime();
        return arr.map((entry) => entry.event);
      },
      size() {
        evictByTime();
        return arr.length;
      },
    };
  }

  // ---- recorder lifecycle ------------------------------------------------

  // Internal helper. The public `client.startRecording()` is a method on
  // the object returned by `createClient` below — it handles session
  // handshake, state flagging, and the flush timer. This helper just
  // wires rrweb into the provided buffer.
  function createRecorder({ buffer }) {
    if (!global.rrweb || !global.rrweb.record) {
      console.warn("[PhoenixReplay] rrweb not loaded; recording disabled. Metadata-only reports still work.");
      return { stop: () => {} };
    }

    // rrweb@2.0 UMD plugins expose themselves under camel-cased package
    // names (rrwebPluginConsoleRecord, rrwebPluginNetworkRecord). Keep the
    // older rrwebConsoleRecord / rrwebNetworkRecord names as fallbacks in
    // case a host ships them under different bundling.
    const consolePlugin = global.rrwebPluginConsoleRecord || global.rrwebConsoleRecord;
    const networkPlugin = global.rrwebPluginNetworkRecord || global.rrwebNetworkRecord;

    const plugins = [];
    if (consolePlugin?.getRecordConsolePlugin) {
      plugins.push(consolePlugin.getRecordConsolePlugin({ lengthThreshold: 100, level: ["error", "warn", "log", "info"] }));
    }
    if (networkPlugin?.getRecordNetworkPlugin) {
      plugins.push(networkPlugin.getRecordNetworkPlugin({ initiatorTypes: ["fetch", "xmlhttprequest"] }));
    }

    const stop = global.rrweb.record({
      emit(event) {
        buffer.push(event);
      },
      plugins,
    });

    return { stop: typeof stop === "function" ? stop : () => {} };
  }

  // ---- main controller ---------------------------------------------------

  function createClient(opts) {
    const cfg = Object.assign({}, DEFAULTS, opts);
    const { basePath, csrfToken } = cfg;
    if (!basePath) throw new Error("PhoenixReplay.init: basePath is required");

    const buffer = createRingBuffer({
      maxEvents: cfg.maxBufferedEvents,
      windowMs: cfg.bufferWindowMs,
    });
    let sessionToken = null;
    let sessionStartedAtMs = null;
    let seq = 0;
    let flushTimer = null;
    let recorder = null;
    // ADR-0006 lifecycle states. `:passive` — ring buffer fills locally,
    // no /session, no /events. `:active` — server-flushed session
    // (reached via startRecording, i.e. Path B entry). Default :passive
    // at mount; transitions:
    //   :passive -> :active   on startRecording()
    //   :active  -> :passive  on stopRecording() / report() teardown
    let state = "passive";
    // Accumulator for events seen during the current :active session.
    // Path B's review step (Phase 3) feeds these to a mini rrweb-player
    // so the user can preview the recording before Send. Cleared on
    // session start (transition into :active) and on transitionToPassive
    // teardown. stopRecording does NOT clear — Stop intentionally keeps
    // the accumulator alive for the review step that opens immediately
    // after. Memory bound: a typical Path B session (30s-2min) is
    // ~100KB-1MB.
    let reviewEvents = [];

    // Begin rrweb capture immediately into the ring buffer. The buffer
    // is bounded by time + count, so this is safe to leave running for
    // the lifetime of the page mount. `:passive` means the buffer is
    // never drained to the server until the user reports.
    recorder = createRecorder({ buffer });

    // Idempotent: a no-op when a session token is already held.
    // On-demand mode leans on this — the session handshake waits
    // until the user clicks Start (via startRecording), not widget
    // mount.
    //
    // If a prior token is cached in `sessionStorage`, sends it in
    // the resume header. Server response includes `resumed` +
    // `seq_watermark`:
    //   - resumed true  → adopt, continue numbering from watermark
    //   - resumed false AND we sent a stored token → stale path
    //     (ADR-0003 OQ1): `:passive` state recovers silently; Path B
    //     (`:active` session) throws `PhoenixReplaySessionInterruptedError`
    //     so the panel can render the error screen and force re-consent.
    async function ensureSession() {
      if (sessionToken) return;
      const stored = storageRead(STORAGE_KEYS.TOKEN);
      const res = await postJson(`${basePath}${cfg.sessionPath}`, {}, {
        csrfToken,
        csrfHeader: cfg.csrfHeader,
        sessionToken: stored,
        tokenHeader: cfg.tokenHeader,
        gzip: false,
      });
      const freshToken = res?.token;
      if (!freshToken) throw new Error("PhoenixReplay: server did not return a session token");

      const sentResumeAttempt = !!stored;
      const resumed = sentResumeAttempt && res.resumed === true;
      const interrupted = sentResumeAttempt && res.resumed !== true;

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
    }

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
            // Session expired / unauthorized → mint a fresh token; drop these events.
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

    function chunk(arr, size) {
      const out = [];
      for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
      return out;
    }

    function scheduleFlush() {
      if (flushTimer) return;
      flushTimer = setInterval(() => {
        flush();
      }, cfg.flushIntervalMs);
    }

    function cancelFlushTimer() {
      if (!flushTimer) return;
      clearInterval(flushTimer);
      flushTimer = null;
    }

    // Centralize the :passive teardown so future audits ("does every
    // teardown null the token?") are trivial — all three call sites
    // share this helper.
    function transitionToPassive() {
      cancelFlushTimer();
      state = "passive";
      sessionToken = null;
      sessionStartedAtMs = null;
      seq = 0;
      reviewEvents = [];
      storageClear(STORAGE_KEYS.TOKEN);
      storageClear(STORAGE_KEYS.RECORDING);
    }

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
      reviewEvents = [];
      await ensureSession();
      state = "active";
      storageWrite(STORAGE_KEYS.RECORDING, "active");
      scheduleFlush();
    }

    async function stopRecording() {
      if (state !== "active") return;
      // Note: we do NOT call recorder.stop() — rrweb stays running so
      // the ring buffer keeps filling for any subsequent Report Now.
      cancelFlushTimer();
      await flush();
      // Flip to :passive but KEEP the session token alive so a
      // follow-up report() can submit using the still-open session.
      // report() itself clears the token after the submit POST. If
      // the user starts a fresh recording instead, startRecording()
      // already nulls token + clears storage at the top.
      state = "passive";
      storageClear(STORAGE_KEYS.RECORDING);
    }

    async function resetRecording() {
      const wasActive = state === "active";
      // Discard any captured context regardless of state.
      buffer.drain();
      transitionToPassive();
      if (wasActive) await startRecording();
    }

    function isRecording() {
      return state === "active";
    }

    // Legacy public: unchanged shape. `start()` used to combine session
    // handshake + recorder + flush timer. All three now live inside
    // `startRecording`; keeping `start` as an alias avoids a breaking
    // change for any host that calls it directly.
    async function start() {
      await startRecording();
    }

    async function report({ description, severity, metadata = {}, jamLink = null, extras = {} }) {
      // Flush any buffered events first so the submit record captures
      // the full tail of the session. Must be :active for flush() to do
      // anything; if a passive widget calls report(), it's a host bug —
      // the new POST /report path (Task 4) is for passive ingest.
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
      transitionToPassive();
    }

    // Path A submit (ADR-0006). Snapshots the ring buffer and POSTs
    // everything in one shot to /report. Only drains the buffer on
    // success — a failed POST leaves the captured events in the buffer
    // so a retry click on Send doesn't ship events: []. No /session
    // handshake; no state transition; the recorder keeps running so
    // the buffer also picks up new activity in the meantime.
    async function reportNow({ description, severity, metadata = {}, jamLink = null, extras = {} }) {
      const events = buffer.snapshot();

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

      // Only reached on success; drain so a follow-up Report Now
      // doesn't double-ship the same events.
      buffer.drain();
      return result;
    }

    // Tail flush on page teardown (ADR-0003 Phase 1). `fetch` with
    // `keepalive: true` is the one transport that survives navigation
    // — `fetch(..., { keepalive: false })` is cancelled by the browser
    // the moment unload starts. A double-flush guard prevents
    // `pagehide` + `beforeunload` from sending the same tail twice.
    //
    // OQ3 cap: at most `3 × maxEventsPerBatch` events; overflow
    // dropped with one `console.warn`. The 64KB keepalive body limit
    // is well clear of that.
    let unloadFired = false;
    function flushOnUnload() {
      if (state !== "active") return;  // :passive has nothing to ship
      if (unloadFired) return;
      unloadFired = true;
      if (!sessionToken) return;

      const events = buffer.drain();
      if (events.length === 0) return;

      const cap = cfg.maxEventsPerBatch * 3;
      const toSend = events.slice(0, cap);
      const dropped = events.length - toSend.length;
      if (dropped > 0) {
        console.warn(
          `[PhoenixReplay] unload buffer overflow — ${dropped} events dropped`
        );
      }

      const headers = { "content-type": "application/json" };
      if (csrfToken) headers[cfg.csrfHeader] = csrfToken;
      if (sessionToken) headers[cfg.tokenHeader] = sessionToken;

      for (const batch of chunk(toSend, cfg.maxEventsPerBatch)) {
        const body = JSON.stringify({ seq, events: batch });
        seq += 1;
        try {
          fetch(`${basePath}${cfg.eventsPath}`, {
            method: "POST",
            headers,
            body,
            credentials: "same-origin",
            keepalive: true,
          });
        } catch {
          // We're unloading — nowhere sensible to surface a
          // fire-and-forget failure.
        }
      }
    }

    // Path B review step (Phase 3). Returns the events captured during
    // the just-stopped :active session and clears the internal
    // accumulator. Called once when the review screen opens; subsequent
    // calls return [] until a new active session starts. Re-record
    // (via startRecording) clears + restarts.
    function takeReviewEvents() {
      const out = reviewEvents.slice();
      reviewEvents = [];
      return out;
    }

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
      _internals: {
        buffer,
        // No client-side session id is tracked (only the opaque token);
        // exposed as null so addon ctx.sessionId() degrades gracefully.
        sessionId: () => null,
        sessionStartedAtMs: () => sessionStartedAtMs,
      },
    };
  }

  // ---- widget UI ---------------------------------------------------------

  // The panel (modal + multi-screen body) is created in both :float and
  // :headless modes. The toggle button and the recording pill only appear
  // in :float. All three are children of the same `.phx-replay-widget`
  // root so host CSS targets a single scope.
  //
  // Screens: `idle_start` (Path B entry — starts recording), `error`
  // (session handshake failure), `choose` (two-path entry panel),
  // `path_a_form` (Path A direct-submit form), `form` (Path B
  // post-recording submit form).
  function renderPanel(mountEl, client, cfg) {
    const root = document.createElement("div");
    root.className = "phx-replay-widget";
    root.innerHTML = `
      <div class="phx-replay-modal" role="dialog" aria-hidden="true" aria-labelledby="phx-replay-title">
        <div class="phx-replay-modal-backdrop"></div>
        <div class="phx-replay-modal-panel">
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

          <section class="phx-replay-screen phx-replay-screen--idle-start" data-screen="${SCREENS.IDLE_START}" hidden>
            <h2>Record and report</h2>
            <p class="phx-replay-screen-lede">
              Click <strong>Start</strong>, reproduce the issue, then click <strong>Stop</strong> in the recording pill.
              Nothing is captured until you start.
            </p>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="button" class="phx-replay-start-cta">Record and report</button>
            </div>
          </section>

          <section class="phx-replay-screen phx-replay-screen--error" data-screen="${SCREENS.ERROR}" hidden>
            <h2>Couldn't start recording</h2>
            <p class="phx-replay-error-message"></p>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="button" class="phx-replay-retry">Retry</button>
            </div>
          </section>

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

          <form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
            <h2 id="phx-replay-title">Describe what happened</h2>
            <p class="phx-replay-recording-meta" data-phx-replay-recording-meta>
              <span class="phx-replay-recording-meta-icon" aria-hidden="true">🔴</span>
              <span class="phx-replay-recording-meta-text">Recording attached</span>
            </p>
            <label>
              <span>What happened?</span>
              <textarea name="description" rows="4" required placeholder="Steps to reproduce, what you expected, what actually happened"></textarea>
            </label>
            <div class="phx-replay-panel-addons" data-slot="form-top"></div>
            <label class="phx-replay-severity-field" hidden>
              <span>Severity</span>
              <select name="severity">
                ${cfg.severities.map(s => `<option value="${s}"${s === cfg.defaultSeverity ? " selected" : ""}>${s}</option>`).join("")}
              </select>
            </label>
            <label>
              <span>Jam link (optional)</span>
              <input name="jam_link" type="url" placeholder="https://jam.dev/c/..." />
            </label>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="submit" class="phx-replay-submit">Send</button>
            </div>
            <div class="phx-replay-status" aria-live="polite"></div>
          </form>

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
        </div>
      </div>
    `;
    mountEl.appendChild(root);

    // ADR-0006 D5: severity defaults to hidden on both forms (Path A
    // and Path B). Hosts opt in via show_severity to expose the field
    // to end users — typically only QA-internal portals where the
    // reporter is also the triager. Un-hide both labels in lock-step.
    if (cfg.showSeverity) {
      root.querySelectorAll(".phx-replay-severity-field").forEach((el) => {
        el.removeAttribute("hidden");
      });
    }

    const modal = root.querySelector(".phx-replay-modal");
    const form = root.querySelector(".phx-replay-screen--form");
    const status = form.querySelector(".phx-replay-status");
    const screens = root.querySelectorAll(".phx-replay-screen");
    const errorMessage = root.querySelector(".phx-replay-error-message");

    // Handlers wired by the init orchestrator — defaults keep the panel
    // self-consistent if it's ever rendered without external wiring.
    let onStartClick = () => {};
    let onRetryClick = () => {};
    let onChooseReportNowClick = () => {};
    let onChooseRecordClick = () => {};
    let onReRecordClick = () => {};
    let onContinueClick = () => {};
    let onPathASubmitHandler = async (data) => { throw new Error("Path A submit handler not wired"); };

    function setScreen(name) {
      // Track which screens go from visible to hidden (slot-leaving)
      // and which goes from hidden to visible (slot-entering) so
      // screen-scoped addon slots get mount/unmount lifecycle hooks.
      let entering = null;
      const leaving = [];
      screens.forEach((s) => {
        const willHide = s.dataset.screen !== name;
        const wasHidden = s.hasAttribute("hidden");
        s.hidden = willHide;
        if (!willHide && wasHidden) entering = s;
        if (willHide && !wasHidden) leaving.push(s);
      });

      // Slot lifecycle: when a screen with a known slot becomes hidden,
      // unmount its addons; when a screen with a known slot becomes
      // visible, mount. form-top is panel-scoped (mounted at
      // construction) and skipped here.
      leaving.forEach((s) => {
        const slotEl = s.querySelector("[data-slot]");
        if (slotEl && slotEl.dataset.slot !== "form-top") {
          unmountAddonsForSlot(slotEl.dataset.slot);
        }
      });
      if (entering) {
        const slotEl = entering.querySelector("[data-slot]");
        if (slotEl && slotEl.dataset.slot !== "form-top") {
          mountAddonsForSlot(slotEl.dataset.slot, slotEl);
        }
      }
    }

    function showModal() { modal.setAttribute("aria-hidden", "false"); }
    function hideModal() { modal.setAttribute("aria-hidden", "true"); }

    // Mini rrweb-player instance for the REVIEW screen (Phase 3).
    // Lazily created when openReview() is called with events. Replaced
    // on Re-record (the second call destroys the previous instance and
    // creates a fresh one against the new events). The widget component
    // emits the rrweb-player UMD script tag for Path B-capable widgets;
    // if it didn't load (network failure, host disabled it, Path A-only
    // widget reached this code via a programmatic call), we surface a
    // "Continue without preview" stub.
    let miniPlayer = null;

    function destroyMiniPlayer() {
      if (!miniPlayer) return;
      try {
        // rrweb-player exposes a `.$destroy()` method (Svelte component).
        if (typeof miniPlayer.$destroy === "function") miniPlayer.$destroy();
      } catch (err) {
        console.warn("[PhoenixReplay] mini-player destroy failed:", err.message);
      }
      miniPlayer = null;
      const container = root.querySelector("[data-phx-replay-mini-player]");
      if (container) container.innerHTML = "";
    }

    function initMiniPlayer(events) {
      destroyMiniPlayer();
      const container = root.querySelector("[data-phx-replay-mini-player]");
      if (!container) return;
      if (!global.rrwebPlayer) {
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Playback unavailable. Continue to describe.</div>`;
        return;
      }
      // rrweb-player needs at least 2 events to construct a timeline.
      // Single-event recordings (rare — basically a Stop without any
      // captured action) bypass the player and show a stub.
      if (!Array.isArray(events) || events.length < 2) {
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Recording too short to preview. Continue to describe.</div>`;
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
      } catch (err) {
        console.warn("[PhoenixReplay] mini-player init failed:", err.message);
        container.innerHTML = `<div class="phx-replay-review-player-fallback">Playback failed. Continue to describe.</div>`;
      }
    }

    function openForm() { setScreen(SCREENS.FORM); showModal(); }
    function openStart() { setScreen(SCREENS.IDLE_START); showModal(); }
    function openError(message) {
      errorMessage.textContent = message || "Something went wrong. Please try again.";
      setScreen(SCREENS.ERROR);
      showModal();
    }
    function openChoose() { setScreen(SCREENS.CHOOSE); showModal(); }
    function openPathAForm() { setScreen(SCREENS.PATH_A_FORM); showModal(); }
    function openReview(events) {
      initMiniPlayer(events);
      setScreen(SCREENS.REVIEW);
      showModal();
    }

    // ADR-0006 Phase 3 slot lifecycle.
    //
    // Each addon mounts when its slot's "host" DOM becomes live and
    // unmounts when the host goes dead. Hosts:
    //   - "form-top": panel-scoped (lives in the legacy + Path A forms,
    //                 both rendered at panel construction). Mount once
    //                 at construction; cleanup happens in close().
    //   - "pill-action": Phase 3, hosted by the pill DOM. Lifecycle
    //                    driven by the init orchestrator's syncRecordingUI
    //                    via panel.mountSlot/unmountSlot.
    //   - "review-media": Phase 3, hosted by REVIEW screen. Lifecycle
    //                     driven by setScreen on screen transitions.
    //
    // Mount return shape:
    //   - undefined → no cleanup (legacy form-top addons).
    //   - function → called when slot goes dead (canonical new contract).
    //   - object {beforeSubmit, onPanelClose} → legacy shape; collected
    //     for the form-submit path and panel-close cleanup. Used by
    //     Phase 2's audio addon (which returns this object today and
    //     migrates in the ash_feedback companion phase).

    const addonHooks = [];   // [{ id, beforeSubmit?, onPanelClose? }]
    const addonCloseCbs = [];

    // Per-slot lifecycle state. Map<slotName, Map<addonId, cleanupFn|null>>.
    // Tracks which addon ids are currently mounted on each slot, plus
    // their cleanup function (if any) for unmount.
    const slotState = new Map();

    function ensureSlotState(slotName) {
      if (!slotState.has(slotName)) slotState.set(slotName, new Map());
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

    function mountAddonsForSlot(slotName, slotEl) {
      if (!slotEl) return;
      const state = ensureSlotState(slotName);
      PANEL_ADDONS.forEach((addon) => {
        if (addon.slot !== slotName) return;
        if (state.has(addon.id)) return;  // already mounted
        if (!pathFilterMatches(addon)) return;
        try {
          const ctx = buildAddonCtx(slotEl);
          const result = addon.mount(ctx);
          let cleanup = null;
          if (typeof result === "function") {
            // Canonical: result IS the cleanup function.
            cleanup = result;
          } else if (result && typeof result === "object") {
            // Legacy: { beforeSubmit, onPanelClose } — collect for the
            // orchestrator. cleanup stays null because panel-close cb
            // handles release for legacy addons.
            addonHooks.push({ id: addon.id, ...result });
          }
          state.set(addon.id, cleanup);
        } catch (err) {
          console.warn(`[PhoenixReplay] addon "${addon.id}" failed to mount on slot "${slotName}": ${err.message}`);
        }
      });
    }

    function unmountAddonsForSlot(slotName) {
      const state = slotState.get(slotName);
      if (!state) return;
      state.forEach((cleanup, id) => {
        if (typeof cleanup === "function") {
          try { cleanup(); } catch (err) {
            console.warn(`[PhoenixReplay] addon "${id}" cleanup failed for slot "${slotName}": ${err.message}`);
          }
        }
      });
      state.clear();
    }

    // form-top is panel-scoped: mount once at construction. Each
    // form-top slot element (legacy form + Path A form both have one)
    // gets the same set of addons mounted against it — addons that
    // care about form-context should keep state per-slotEl in their
    // ctx closure.
    root.querySelectorAll('[data-slot="form-top"]').forEach((slotEl) => {
      mountAddonsForSlot("form-top", slotEl);
    });

    function close() {
      hideModal();
      form.reset();
      status.textContent = "";
      destroyMiniPlayer();
      // Reset to the CHOOSE screen so a fresh open() without routing
      // always starts at the entry panel. The init orchestrator can
      // override via single-path skip when allow_paths has one entry.
      setScreen(SCREENS.FORM);
      // Unmount any lifecycle-managed slots that were live. form-top
      // legacy addons run their cleanup via addonCloseCbs (back-compat).
      slotState.forEach((_state, slotName) => {
        if (slotName !== "form-top") unmountAddonsForSlot(slotName);
      });
      addonCloseCbs.forEach((cb) => {
        try { cb(); } catch (err) { console.warn(`[PhoenixReplay] addon close hook failed: ${err.message}`); }
      });
    }

    root.querySelectorAll(".phx-replay-cancel").forEach((el) => el.addEventListener("click", close));
    root.querySelector(".phx-replay-modal-backdrop").addEventListener("click", close);
    root.querySelector(".phx-replay-start-cta").addEventListener("click", () => onStartClick());
    root.querySelector(".phx-replay-retry").addEventListener("click", () => onRetryClick());
    root.querySelector(".phx-replay-choose-report-now").addEventListener("click", () => onChooseReportNowClick());
    root.querySelector(".phx-replay-choose-record").addEventListener("click", () => onChooseRecordClick());
    root.querySelector(".phx-replay-rerecord").addEventListener("click", () => onReRecordClick());
    root.querySelector(".phx-replay-continue").addEventListener("click", () => onContinueClick());

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const data = new FormData(form);

      // Severity field is hidden by default; show_severity un-hides it.
      // When hidden, strip the FormData entry so the panel doesn't ship
      // a value the host chose to suppress (parallel to the Path A
      // submit listener — see Task 5).
      const severityField = form.querySelector(".phx-replay-severity-field");
      if (severityField && severityField.hidden) {
        data.delete("severity");
      }

      status.textContent = "Sending…";

      // Run all addon beforeSubmit hooks in registration order, merging
      // each returned `extras` into a single map. A throw aborts the
      // submit and surfaces the error inline.
      const merged = {};
      try {
        for (const hook of addonHooks) {
          if (typeof hook.beforeSubmit !== "function") continue;
          status.textContent = `Sending… (${hook.id})`;
          const result = await hook.beforeSubmit({ formData: data });
          if (result && result.extras && typeof result.extras === "object") {
            Object.assign(merged, result.extras);
          }
        }
      } catch (err) {
        status.textContent = `Submit failed: ${err.message}`;
        return;
      }

      status.textContent = "Sending…";
      try {
        await client.report({
          description: data.get("description"),
          severity: data.get("severity") || undefined,
          jamLink: data.get("jam_link") || null,
          extras: merged,
        });
        status.textContent = "Thanks! Your report was submitted.";
        setTimeout(close, 1200);
      } catch (err) {
        status.textContent = `Submit failed: ${err.message}`;
      }
    });

    const pathAForm = root.querySelector(".phx-replay-screen--path-a-form");
    const pathAStatus = pathAForm.querySelector(".phx-replay-status");

    pathAForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const data = new FormData(pathAForm);

      // The severity <label> is hidden by default; show_severity wiring
      // un-hides it. When hidden the host opted out, so strip the
      // FormData entry — the panel must not ship a value the host
      // chose to suppress, which would clobber any controller-side
      // default. The legacy Path B form is wrapped + gated in Task 6
      // and gets the same treatment there.
      const severityField = pathAForm.querySelector(".phx-replay-severity-field");
      if (severityField && severityField.hidden) {
        data.delete("severity");
      }

      pathAStatus.textContent = "Sending…";
      try {
        await onPathASubmitHandler(data);
        pathAStatus.textContent = "Thanks! Your report was submitted.";
        setTimeout(close, 1200);
      } catch (err) {
        pathAStatus.textContent = `Submit failed: ${err.message}`;
      }
    });

    return {
      root,
      openForm,
      openStart,
      openError,
      openChoose,
      openPathAForm,
      openReview,
      close,
      mountSlot: (slotName, slotEl) => mountAddonsForSlot(slotName, slotEl),
      unmountSlot: (slotName) => unmountAddonsForSlot(slotName),
      onStart: (fn) => { onStartClick = fn; },
      onRetry: (fn) => { onRetryClick = fn; },
      onChooseReportNow: (fn) => { onChooseReportNowClick = fn; },
      onChooseRecord: (fn) => { onChooseRecordClick = fn; },
      onReRecord: (fn) => { onReRecordClick = fn; },
      onContinue: (fn) => { onContinueClick = fn; },
      onPathASubmit: (fn) => { onPathASubmitHandler = fn; },
    };
  }

  function renderToggle(widgetRoot, cfg, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `phx-replay-toggle ${positionClass("toggle", cfg)}`;
    btn.setAttribute("aria-label", "Report an issue");
    btn.innerHTML = `
      <span aria-hidden="true">⚠︎</span>
      <span class="phx-replay-toggle-text">${cfg.widgetText}</span>
    `;
    // Insert BEFORE the modal so tab order starts with the trigger.
    widgetRoot.insertBefore(btn, widgetRoot.firstChild);
    btn.addEventListener("click", onClick);
    return {
      show: () => { btn.hidden = false; },
      hide: () => { btn.hidden = true; },
    };
  }

  // Status indicator visible during an `:active` recording in `:float`
  // mode (Path B — Record and report). The `--phx-replay-pill-*` CSS
  // var family is deliberately independent of the toggle's so hosts can
  // place them on different corners without lock-step.
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
      // Slot DOM exposed so the orchestrator (Task 5) can mount/unmount
      // addons tied to the pill's lifecycle.
      slotEl: pill.querySelector(".phx-replay-pill-action-slot"),
      // Read-only: when the active session started. Used by addons that
      // need a stable reference (e.g., audio_start_offset_ms calc).
      startedAtMs: () => startedAtMs,
    };
  }

  // Registry of mounted panels keyed by the mount element. `open`/`close`
  // on the global delegate to the first entry (99% case has one widget per
  // page); multi-mount emits a console warning.
  const instances = new Map();

  function firstInstance() {
    const iter = instances.values().next();
    return iter.done ? null : iter.value;
  }

  // Install once. On page teardown, every mounted client drains its
  // ring buffer via `fetch(..., { keepalive: true })` so tail events
  // reach the server despite the unload. Both `pagehide` and
  // `beforeunload` fire the handler — the client's own double-fire
  // guard keeps us from sending twice. `pagehide` is the primary
  // signal (bfcache-safe); `beforeunload` is the fallback for UAs
  // where `pagehide` is flaky.
  function installUnloadListener() {
    if (installUnloadListener.installed) return;
    installUnloadListener.installed = true;
    if (typeof window === "undefined") return;
    const handler = () => {
      instances.forEach(({ client }) => client.flushOnUnload?.());
    };
    window.addEventListener("pagehide", handler, { capture: true });
    window.addEventListener("beforeunload", handler, { capture: true });
  }

  // Install once. Any element marked with [data-phoenix-replay-trigger]
  // (including elements added to the DOM after page load) opens the panel
  // when clicked. Delegation avoids re-binding per element.
  function installTriggerListener() {
    if (installTriggerListener.installed) return;
    installTriggerListener.installed = true;
    if (typeof document === "undefined") return;
    document.addEventListener("click", (e) => {
      const trigger = e.target.closest && e.target.closest("[data-phoenix-replay-trigger]");
      if (!trigger) return;
      e.preventDefault();
      const inst = firstInstance();
      if (!inst) {
        console.warn("[PhoenixReplay] trigger clicked but no widget is mounted");
        return;
      }
      inst.routedOpen();
    });
  }

  // ---- public ------------------------------------------------------------

  const PhoenixReplay = {
    async init(opts) {
      if (!opts?.mount) throw new Error("PhoenixReplay.init: mount element is required");
      const cfg = Object.assign({}, DEFAULTS, opts);
      const client = createClient(cfg);
      const panel = renderPanel(cfg.mount, client, cfg);
      const mode = cfg.mode === "headless" ? "headless" : "float";

      // ADR-0006 Phase 2: route based on allow_paths.
      //   both     → two-option CHOOSE screen
      //   only A   → straight to Path A form (no panel-choice friction)
      //   only B   → straight to Path B start (recording immediately)
      function routedOpen() {
        const paths = cfg.allowPaths || ["report_now", "record_and_report"];
        const aOnly = paths.length === 1 && paths[0] === "report_now";
        const bOnly = paths.length === 1 && paths[0] === "record_and_report";
        if (aOnly) return panel.openPathAForm();   // Task 5 wires the panel method
        if (bOnly) return handleStartFromPanel();
        panel.openChoose();
      }

      let toggle = null;
      if (mode === "float") {
        toggle = renderToggle(panel.root, cfg, routedOpen);
      }

      // Phase 2: pill renders for all :float widgets (it stays hidden via
      // syncRecordingUI until startRecording transitions to :active). Phase 3
      // will extend it with a pill-action slot for addons.
      let pill = null;
      if (mode === "float") {
        pill = renderPill(panel.root, cfg, () => handleStop());
      }

      // Derive UI state from `client.isRecording()` directly — the client
      // is the source of truth. Toggle hide/show is gated on the presence
      // of a pill (`:float` mode only); when in `:active` state the pill
      // shows and the toggle hides, swapping them back when `:passive`.
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

      // Shared core: guard, await, sync UI. Callers layer their own
      // error-handling on top (panel shows an error screen; the global
      // API lets the rejection propagate).
      async function startAndSync() {
        const wasRecording = client.isRecording();
        await client.startRecording();
        if (!wasRecording) syncRecordingUI();
      }

      // Called from the panel's Start CTA and its Retry button. A
      // session-handshake failure surfaces as the `error` screen instead
      // of an unhandled rejection — clicking Start must never silently
      // do nothing.
      async function handleStartFromPanel() {
        try {
          await startAndSync();
          panel.close();
        } catch (err) {
          panel.openError(`Couldn't start recording: ${err.message}`);
        }
      }

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
        // Re-record from review = discard the just-captured events
        // (already drained by takeReviewEvents in handleStop) and start
        // a fresh active session. The pill swaps back in via
        // syncRecordingUI; the panel closes so the pill is the only UI.
        try {
          await client.startRecording();
          syncRecordingUI();
          panel.close();
        } catch (err) {
          panel.openError(`Couldn't restart recording: ${err.message}`);
        }
      }

      function handleContinue() {
        // Advance to the describe step (legacy FORM). Update the
        // recording-meta text with the elapsed duration computed from
        // the active session's start moment (preserved across
        // stopRecording's partial teardown). Falls back to the static
        // "Recording attached" if the start time isn't available.
        const startedAtMs = client._internals.sessionStartedAtMs?.();
        const metaText = document.querySelector(".phx-replay-recording-meta-text");
        if (metaText && startedAtMs) {
          const elapsed = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
          const m = Math.floor(elapsed / 60);
          const s = elapsed % 60;
          metaText.textContent = `Recording attached (${m}:${s.toString().padStart(2, "0")})`;
        }
        // The mini-player is destroyed on panel.close (final Send) —
        // the in-modal screen swap leaves the player around but hidden
        // under the active screen until close, which is fine since the
        // user only sees one screen at a time.
        panel.openForm();
      }

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

      instances.set(cfg.mount, {
        panel,
        client,
        cfg,
        routedOpen,
        startAndSync,
        handleStop,
      });
      if (instances.size > 1) {
        console.warn(
          "[PhoenixReplay] multiple widget instances detected; " +
            "window.PhoenixReplay.open()/close() will act on the first."
        );
      }
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
      return client;
    },

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

    // Canonical name for opening the panel — same routing as open().
    // Hosts wiring keyboard shortcuts or dropdown items should prefer
    // openPanel(); open() remains as a deprecated-but-supported alias.
    openPanel() {
      const inst = firstInstance();
      if (inst) inst.routedOpen();
    },

    // Skip the entry panel and open Path A's submit form directly.
    // Useful for hosts wiring a "Report a bug" header link that should
    // bypass the two-option choice. No-op if no widget is mounted.
    reportNow() {
      const inst = firstInstance();
      if (inst) inst.panel.openPathAForm();
    },

    // Skip the entry panel and start Path B (Record and report)
    // immediately — opens the session, starts rrweb, swaps to the
    // recording pill. Useful for header buttons that always mean
    // "I want to record this." Returns a promise that rejects on
    // session handshake failure.
    recordAndReport() {
      const inst = firstInstance();
      return inst ? inst.startAndSync() : Promise.resolve();
    },

    // Close the first mounted panel. Usable from host JS after triggering
    // submit programmatically or canceling a flow.
    close() {
      const inst = firstInstance();
      if (inst) inst.panel.close();
    },

    // Transition to `:active` state on the first mounted instance: opens
    // a server session and begins flushing the ring buffer. No-op if
    // already `:active`. Used by Path B (Record and report) and by
    // `recordAndReport()`. Returns a promise that rejects on session
    // handshake failure; callers can surface that in the UI.
    startRecording() {
      const inst = firstInstance();
      return inst ? inst.startAndSync() : Promise.resolve();
    },

    // Halt rrweb capture and flush the tail of the buffer. Transitions
    // to `:passive` state. In `:float` mode this also opens the Path B
    // submit form — consistent with the pill Stop button.
    stopRecording() {
      const inst = firstInstance();
      return inst ? inst.handleStop() : Promise.resolve();
    },

    // Drop the current buffer and session, then restart recording
    // against a fresh session. No-op if not currently `:active`. Useful
    // when the host wants to discard accumulated noise and capture only
    // the next window.
    resetRecording() {
      const inst = firstInstance();
      return inst ? inst.client.resetRecording() : Promise.resolve();
    },

    // Whether the first mounted instance is currently capturing events.
    isRecording() {
      const inst = firstInstance();
      return inst ? inst.client.isRecording() : false;
    },

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

    // Auto-mount helper: finds elements with [data-phoenix-replay] and
    // configures from their data-* attributes. Host drops a
    // <div data-phoenix-replay data-base-path="/api/feedback"
    //      data-csrf-token="..."></div> in the root layout; no JS glue needed.
    autoMount() {
      document.querySelectorAll("[data-phoenix-replay]").forEach((el) => {
        if (el.dataset.phoenixReplayMounted) return;
        el.dataset.phoenixReplayMounted = "1";

        const showSeverity = el.dataset.showSeverity === "true";

        // Parse allow_paths CSV. Defensive: filter to known path values
        // and warn on unknown atoms. A typo in the host's allow_paths
        // attr (e.g. [:repor_now]) would otherwise silently degrade to
        // "panel always opens CHOOSE."
        const KNOWN_PATHS = new Set(["report_now", "record_and_report"]);
        const rawPaths = (el.dataset.allowPaths || "report_now,record_and_report")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        const allowPaths = rawPaths.filter((p) => KNOWN_PATHS.has(p));
        const unknown = rawPaths.filter((p) => !KNOWN_PATHS.has(p));
        if (unknown.length > 0) {
          console.warn(
            `[PhoenixReplay] unknown allow_paths values ignored: ${unknown.join(", ")}. ` +
              `Allowed: report_now, record_and_report.`
          );
        }
        const effectiveAllowPaths = allowPaths.length > 0
          ? allowPaths
          : ["report_now", "record_and_report"];

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
          allowPaths: effectiveAllowPaths,
          bufferWindowMs,
        }).catch((err) => console.warn("[PhoenixReplay] auto-mount failed:", err));
      });
    },
  };

  // Internal factory exposed only for tests. Do not use from host code —
  // the surface may change without a CHANGELOG entry.
  PhoenixReplay._testInternals = { createRingBuffer };

  if (typeof global !== "undefined") global.PhoenixReplay = PhoenixReplay;
  if (typeof document !== "undefined") {
    // Defer to DOMContentLoaded even when readyState is already
    // "interactive" — defer scripts execute *before* DOMContentLoaded
    // fires, so a registerPanelAddon call from a later defer script
    // (e.g. ash_feedback/audio_recorder.js) needs autoMount to wait
    // until all defer scripts have run. Scheduling to DOMContentLoaded
    // guarantees that ordering. If we land after the event has already
    // fired (state "complete"), mount immediately.
    if (document.readyState === "complete") {
      PhoenixReplay.autoMount();
    } else {
      document.addEventListener("DOMContentLoaded", PhoenixReplay.autoMount, { once: true });
    }
  }
})(typeof window !== "undefined" ? window : globalThis);
