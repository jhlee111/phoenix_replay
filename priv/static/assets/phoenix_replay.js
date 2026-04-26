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
    FORM: "form",                  // Path B describe step (legacy name preserved)
    PATH_A_FORM: "path_a_form",    // Path A single-step submit (markup added in Task 5)
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
  // `resumed: false` — the previous session is stale. For
  // `:continuous` the client recovers silently; for `:on_demand`
  // this surfaces as the panel error screen because losing the
  // chain violates explicit consent.
  class PhoenixReplaySessionInterruptedError extends Error {
    constructor() {
      super("Previous recording was interrupted");
      this.name = "PhoenixReplaySessionInterruptedError";
    }
  }

  // `sessionStorage` is tab-local, survives reloads + same-tab
  // navigations, gone on tab close. Matches ADR-0002 OQ4's tab-local
  // on-demand scope — and is the right lifetime for a recording
  // session that should never bleed between tabs.
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
    // (today's :continuous behavior, reached via startRecording — Task 4
    // may add additional entry paths). Default :passive at mount;
    // transitions:
    //   :passive -> :active   on startRecording()
    //   :active  -> :passive  on stopRecording() / report() teardown
    let state = "passive";

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
    //     (ADR-0003 OQ1): continuous silently overwrites; on-demand
    //     throws `PhoenixReplaySessionInterruptedError` so the panel
    //     can render the error screen and force re-consent.
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

    return {
      start,
      report,
      flush,
      flushOnUnload,
      startRecording,
      stopRecording,
      resetRecording,
      isRecording,
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
  // Screens: `idle_start` (only rendered for `:on_demand`), `error`
  // (session handshake failure), `form` (the description/severity/submit
  // flow — the only screen used in `:continuous`).
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

          <form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
            <h2 id="phx-replay-title">Report an issue</h2>
            <label>
              <span>What happened?</span>
              <textarea name="description" rows="4" required placeholder="Steps to reproduce, what you expected, what actually happened"></textarea>
            </label>
            <div class="phx-replay-panel-addons" data-slot="form-top"></div>
            <label>
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
        </div>
      </div>
    `;
    mountEl.appendChild(root);

    const modal = root.querySelector(".phx-replay-modal");
    const form = root.querySelector(".phx-replay-screen--form");
    const status = form.querySelector(".phx-replay-status");
    const screens = root.querySelectorAll(".phx-replay-screen");
    const errorMessage = root.querySelector(".phx-replay-error-message");

    // Handlers wired by the init orchestrator — defaults keep the panel
    // self-consistent if it's ever rendered without external wiring.
    let onStartClick = () => {};
    let onRetryClick = () => {};

    function setScreen(name) {
      screens.forEach((s) => { s.hidden = s.dataset.screen !== name; });
    }

    function showModal() { modal.setAttribute("aria-hidden", "false"); }
    function hideModal() { modal.setAttribute("aria-hidden", "true"); }

    function openForm() { setScreen(SCREENS.FORM); showModal(); }
    function openStart() { setScreen(SCREENS.IDLE_START); showModal(); }
    function openError(message) {
      errorMessage.textContent = message || "Something went wrong. Please try again.";
      setScreen(SCREENS.ERROR);
      showModal();
    }

    // Mount panel addons against their slots. Each addon's mount(ctx)
    // returns optional { beforeSubmit, onPanelClose } hooks; we collect
    // them for the submit orchestrator and the panel close cleanup.
    const slotEls = new Map();  // slot name -> DOM element
    root.querySelectorAll("[data-slot]").forEach((el) => {
      slotEls.set(el.dataset.slot, el);
    });

    const addonHooks = [];  // [{ id, beforeSubmit?, onPanelClose? }]
    const addonCloseCbs = [];

    // ADR-0006 Phase 2 transitional shim. The mode-aware addon spec
    // (2026-04-25) registered audio addons with `modes: ["on_demand"]`.
    // ADR-0006 dropped the recording attr; the new equivalent is
    // "this addon mounts when allow_paths includes Path B
    // (record_and_report)." Until Phase 4 renames `modes` to `paths`,
    // this shim maps the legacy symbols:
    //   "on_demand"  → mount when allowPaths includes record_and_report
    //   "continuous" → mount when allowPaths includes report_now
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

    function close() {
      hideModal();
      form.reset();
      status.textContent = "";
      // Reset to the form screen so a fresh open() without routing shows
      // the report form (backward-compat for `:continuous`). The init
      // orchestrator overrides via `openStart` when on-demand + idle.
      setScreen(SCREENS.FORM);
      addonCloseCbs.forEach((cb) => {
        try { cb(); } catch (err) { console.warn(`[PhoenixReplay] addon close hook failed: ${err.message}`); }
      });
    }

    root.querySelectorAll(".phx-replay-cancel").forEach((el) => el.addEventListener("click", close));
    root.querySelector(".phx-replay-modal-backdrop").addEventListener("click", close);
    root.querySelector(".phx-replay-start-cta").addEventListener("click", () => onStartClick());
    root.querySelector(".phx-replay-retry").addEventListener("click", () => onRetryClick());

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const data = new FormData(form);
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
          severity: data.get("severity"),
          jamLink: data.get("jam_link") || null,
          extras: merged,
        });
        status.textContent = "Thanks! Your report was submitted.";
        setTimeout(close, 1200);
      } catch (err) {
        status.textContent = `Submit failed: ${err.message}`;
      }
    });

    return {
      root,
      openForm,
      openStart,
      openError,
      close,
      onStart: (fn) => { onStartClick = fn; },
      onRetry: (fn) => { onRetryClick = fn; },
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

  // Status indicator for an active `:on_demand` reproduction in `:float`
  // mode. The `--phx-replay-pill-*` CSS var family is deliberately
  // independent of the toggle's so hosts can place them on different
  // corners without lock-step.
  function renderPill(widgetRoot, cfg, onStop) {
    const pill = document.createElement("div");
    pill.className = `phx-replay-pill ${positionClass("pill", cfg)}`;
    pill.setAttribute("role", "status");
    pill.setAttribute("aria-live", "polite");
    pill.hidden = true;
    pill.innerHTML = `
      <span class="phx-replay-pill-dot" aria-hidden="true"></span>
      <span class="phx-replay-pill-label">Recording…</span>
      <button type="button" class="phx-replay-pill-stop">Stop</button>
    `;
    widgetRoot.appendChild(pill);
    pill.querySelector(".phx-replay-pill-stop").addEventListener("click", onStop);
    return {
      show: () => { pill.hidden = false; },
      hide: () => { pill.hidden = true; },
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

      // Phase 2: intermediate shape. Task 4 rewrites this to branch
      // on cfg.allowPaths (CHOOSE screen, or single-path skip). Until
      // then keep the pre-Phase-2 always-form behavior so report_now-
      // only hosts don't see a Record-and-report CTA.
      function routedOpen() {
        panel.openForm();
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
      // of a pill so :continuous never blinks the toggle; only :float +
      // :on_demand swaps toggle ↔ pill in place.
      function syncRecordingUI() {
        const recording = client.isRecording();
        if (pill) recording ? pill.show() : pill.hide();
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
        panel.openForm();
      }

      panel.onStart(handleStartFromPanel);
      panel.onRetry(handleStartFromPanel);

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

    // Open the first mounted panel. Usable from host JS, dropdown menu
    // items, keyboard shortcuts, etc. No-op if no widget is mounted.
    // Routes to the Start CTA when the widget is :on_demand and idle.
    open() {
      const inst = firstInstance();
      if (inst) inst.routedOpen();
    },

    // Close the first mounted panel. Usable from host JS after triggering
    // submit programmatically or canceling a flow.
    close() {
      const inst = firstInstance();
      if (inst) inst.panel.close();
    },

    // Begin rrweb capture on the first mounted instance. No-op if
    // recording is already active. In `:continuous` mode the recorder
    // starts at mount, so this is a no-op there — use in `:on_demand`
    // to begin a reproduction. Returns a promise that rejects on session
    // handshake failure; callers can surface that in the UI.
    startRecording() {
      const inst = firstInstance();
      return inst ? inst.startAndSync() : Promise.resolve();
    },

    // Halt rrweb capture and flush the tail of the buffer. In :on_demand
    // mode this also opens the report form so the user lands in the
    // submit flow — consistent with the float pill Stop button.
    stopRecording() {
      const inst = firstInstance();
      return inst ? inst.handleStop() : Promise.resolve();
    },

    // Drop the current buffer and session, then restart recording
    // against a fresh session. No-op if not currently recording. Useful
    // in `:continuous` when the host wants to discard accumulated noise
    // and capture only the next window.
    resetRecording() {
      const inst = firstInstance();
      return inst ? inst.client.resetRecording() : Promise.resolve();
    },

    // Whether the first mounted instance is currently capturing events.
    isRecording() {
      const inst = firstInstance();
      return inst ? inst.client.isRecording() : false;
    },

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
