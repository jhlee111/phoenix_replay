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
    // Batching.
    maxEventsPerBatch: 50,
    flushIntervalMs: 5000,
    maxBufferedEvents: 10_000, // ring-buffer cap
    // Network.
    tokenHeader: "x-phoenix-replay-session",
    csrfHeader: "x-csrf-token",
    // Widget UX.
    widgetText: "Report issue",
    position: "bottom_right",
    recording: "continuous",
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
  const SCREENS = { IDLE_START: "idle_start", ERROR: "error", FORM: "form" };

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

  // ---- ring buffer -------------------------------------------------------

  function createRingBuffer(max) {
    const arr = [];
    return {
      push(evt) {
        arr.push(evt);
        if (arr.length > max) arr.splice(0, arr.length - max);
      },
      drain() {
        const out = arr.splice(0, arr.length);
        return out;
      },
      size() {
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

    const buffer = createRingBuffer(cfg.maxBufferedEvents);
    let sessionToken = null;
    let seq = 0;
    let flushTimer = null;
    let recorder = null;
    let recording = false;

    // Idempotent: a no-op when a session token is already held. On-demand
    // mode leans on this — the session handshake waits until the user
    // clicks Start (via startRecording), not widget mount.
    async function ensureSession() {
      if (sessionToken) return;
      const res = await postJson(`${basePath}${cfg.sessionPath}`, {}, {
        csrfToken,
        csrfHeader: cfg.csrfHeader,
        tokenHeader: cfg.tokenHeader,
        gzip: false,
      });
      sessionToken = res?.token;
      if (!sessionToken) throw new Error("PhoenixReplay: server did not return a session token");
      seq = 0;
    }

    async function flush() {
      if (!sessionToken) return;
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

    async function startRecording() {
      if (recording) return;
      // Each recording gets a fresh session token. A prior stopRecording
      // left the previous token alive so a subsequent report() could still
      // submit the drained tail; if the host is instead beginning a new
      // reproduction, that tail is abandoned and we mint a new session.
      sessionToken = null;
      seq = 0;
      await ensureSession();
      recorder = createRecorder({ buffer });
      recording = true;
      scheduleFlush();
    }

    async function stopRecording() {
      if (!recording) return;
      recorder?.stop?.();
      recorder = null;
      recording = false;
      // Stop the periodic flush before the final drain — otherwise the
      // timer keeps firing no-op `/events` posts (and occasionally racing
      // with late rrweb cleanup emissions) after we've torn down.
      cancelFlushTimer();
      await flush();
    }

    async function resetRecording() {
      // Per ADR-0002 OQ5: on-demand idle → no-op. Currently recording
      // (either mode) → stop cleanly, drop buffered events + session,
      // then start fresh.
      if (!recording) return;
      recorder?.stop?.();
      recorder = null;
      recording = false;
      buffer.drain();
      sessionToken = null;
      seq = 0;
      await startRecording();
    }

    function isRecording() {
      return recording;
    }

    // Legacy public: unchanged shape. `start()` used to combine session
    // handshake + recorder + flush timer. All three now live inside
    // `startRecording`; keeping `start` as an alias avoids a breaking
    // change for any host that calls it directly.
    async function start() {
      await startRecording();
    }

    async function report({ description, severity, metadata = {}, jamLink = null }) {
      // Flush any buffered events first so the submit record captures the
      // full tail of the session.
      await flush();

      await postJson(`${basePath}${cfg.submitPath}`, {
        description,
        severity: severity || cfg.defaultSeverity,
        metadata,
        jam_link: jamLink,
      }, {
        csrfToken,
        csrfHeader: cfg.csrfHeader,
        sessionToken,
        tokenHeader: cfg.tokenHeader,
      });

      // Tear down the current session. Continuous mode spins up a fresh
      // one immediately so the next report doesn't share buffer/seq.
      // On-demand mode returns to idle — the user starts the next
      // reproduction explicitly.
      if (recording) {
        recorder?.stop?.();
        recorder = null;
        recording = false;
      }
      cancelFlushTimer();
      sessionToken = null;
      seq = 0;
      if (cfg.recording !== "on_demand") {
        await startRecording().catch(() => {});
      }
    }

    return {
      start,
      report,
      flush,
      startRecording,
      stopRecording,
      resetRecording,
      isRecording,
      _internals: { buffer },
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
          <section class="phx-replay-screen phx-replay-screen--idle-start" data-screen="${SCREENS.IDLE_START}" hidden>
            <h2>Start reproduction</h2>
            <p class="phx-replay-screen-lede">
              Click <strong>Start</strong>, reproduce the issue, then click <strong>Stop</strong> in the recording pill.
              Nothing is captured until you start.
            </p>
            <div class="phx-replay-actions">
              <button type="button" class="phx-replay-cancel">Cancel</button>
              <button type="button" class="phx-replay-start-cta">Start reproduction</button>
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

    function close() {
      hideModal();
      form.reset();
      status.textContent = "";
      // Reset to the form screen so a fresh open() without routing shows
      // the report form (backward-compat for `:continuous`). The init
      // orchestrator overrides via `openStart` when on-demand + idle.
      setScreen(SCREENS.FORM);
    }

    root.querySelectorAll(".phx-replay-cancel").forEach((el) => el.addEventListener("click", close));
    root.querySelector(".phx-replay-modal-backdrop").addEventListener("click", close);
    root.querySelector(".phx-replay-start-cta").addEventListener("click", () => onStartClick());
    root.querySelector(".phx-replay-retry").addEventListener("click", () => onRetryClick());

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const data = new FormData(form);
      status.textContent = "Sending…";
      try {
        await client.report({
          description: data.get("description"),
          severity: data.get("severity"),
          jamLink: data.get("jam_link") || null,
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
      const onDemand = cfg.recording === "on_demand";

      // `routedOpen` decides which screen the toggle / trigger / global
      // `open()` should surface:
      //   - on-demand + idle → Start CTA screen
      //   - anything else    → report form (backward-compat)
      function routedOpen() {
        if (onDemand && !client.isRecording()) panel.openStart();
        else panel.openForm();
      }

      let toggle = null;
      if (mode === "float") {
        toggle = renderToggle(panel.root, cfg, routedOpen);
      }

      // The pill only appears for :float + :on_demand. Headless consumers
      // bring their own indicator; `stopRecording()` still opens the form
      // (see `handleStop`) so they land in the library's submit flow.
      let pill = null;
      if (mode === "float" && onDemand) {
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

      // Called from the pill Stop button and the global `stopRecording`
      // API. On-demand additionally opens the submit form so both the
      // pill path and headless consumers land in the same library flow.
      async function handleStop() {
        const wasRecording = client.isRecording();
        await client.stopRecording();
        if (!wasRecording) return;
        syncRecordingUI();
        if (onDemand) panel.openForm();
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
      if (!onDemand) await client.start();
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

    // Auto-mount helper: finds elements with [data-phoenix-replay] and
    // configures from their data-* attributes. Host drops a
    // <div data-phoenix-replay data-base-path="/api/feedback"
    //      data-csrf-token="..."></div> in the root layout; no JS glue needed.
    autoMount() {
      document.querySelectorAll("[data-phoenix-replay]").forEach((el) => {
        if (el.dataset.phoenixReplayMounted) return;
        el.dataset.phoenixReplayMounted = "1";
        PhoenixReplay.init({
          mount: el,
          basePath: el.dataset.basePath,
          csrfToken: el.dataset.csrfToken,
          widgetText: el.dataset.widgetText,
          position: el.dataset.position,
          mode: el.dataset.mode,
          recording: el.dataset.recording,
        }).catch((err) => console.warn("[PhoenixReplay] auto-mount failed:", err));
      });
    },
  };

  if (typeof global !== "undefined") global.PhoenixReplay = PhoenixReplay;
  if (typeof document !== "undefined") {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", PhoenixReplay.autoMount);
    } else {
      PhoenixReplay.autoMount();
    }
  }
})(typeof window !== "undefined" ? window : globalThis);
