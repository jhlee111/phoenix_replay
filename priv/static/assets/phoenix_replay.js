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
    severities: ["info", "low", "medium", "high", "critical"],
    defaultSeverity: "medium",
  };

  // ---- transport ---------------------------------------------------------

  async function postJson(url, body, { csrfToken, sessionToken, tokenHeader, csrfHeader, gzip = true }) {
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

  function startRecording({ buffer }) {
    if (!global.rrweb || !global.rrweb.record) {
      console.warn("[PhoenixReplay] rrweb not loaded; recording disabled. Metadata-only reports still work.");
      return { stop: () => {} };
    }

    const plugins = [];
    if (global.rrwebConsoleRecord?.getRecordConsolePlugin) {
      plugins.push(global.rrwebConsoleRecord.getRecordConsolePlugin({ lengthThreshold: 100, level: ["error", "warn", "log", "info"] }));
    }
    if (global.rrwebNetworkRecord?.getRecordNetworkPlugin) {
      plugins.push(global.rrwebNetworkRecord.getRecordNetworkPlugin({ initiatorTypes: ["fetch", "xmlhttprequest"] }));
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

    async function startSession() {
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
            await startSession().catch(() => {});
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

    async function start() {
      await startSession();
      recorder = startRecording({ buffer });
      scheduleFlush();
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

      // Start a fresh session so the next report doesn't share buffer/seq.
      recorder?.stop?.();
      recorder = startRecording({ buffer });
      await startSession().catch(() => {});
    }

    return { start, report, flush, _internals: { buffer } };
  }

  // ---- widget UI ---------------------------------------------------------

  function renderWidget(mountEl, client, cfg) {
    const root = document.createElement("div");
    root.className = "phx-replay-widget";
    root.innerHTML = `
      <button type="button" class="phx-replay-toggle" aria-label="Report an issue">
        <span aria-hidden="true">⚠︎</span>
        <span class="phx-replay-toggle-text">${cfg.widgetText}</span>
      </button>
      <div class="phx-replay-modal" role="dialog" aria-hidden="true" aria-labelledby="phx-replay-title">
        <div class="phx-replay-modal-backdrop"></div>
        <form class="phx-replay-modal-panel">
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
    `;
    mountEl.appendChild(root);

    const modal = root.querySelector(".phx-replay-modal");
    const form = root.querySelector(".phx-replay-modal-panel");
    const status = root.querySelector(".phx-replay-status");

    function openModal() { modal.setAttribute("aria-hidden", "false"); }
    function closeModal() {
      modal.setAttribute("aria-hidden", "true");
      form.reset();
      status.textContent = "";
    }

    root.querySelector(".phx-replay-toggle").addEventListener("click", openModal);
    root.querySelector(".phx-replay-cancel").addEventListener("click", closeModal);
    root.querySelector(".phx-replay-modal-backdrop").addEventListener("click", closeModal);

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
        setTimeout(closeModal, 1200);
      } catch (err) {
        status.textContent = `Submit failed: ${err.message}`;
      }
    });
  }

  // ---- public ------------------------------------------------------------

  const PhoenixReplay = {
    async init(opts) {
      if (!opts?.mount) throw new Error("PhoenixReplay.init: mount element is required");
      const cfg = Object.assign({}, DEFAULTS, opts);
      const client = createClient(cfg);
      renderWidget(cfg.mount, client, cfg);
      await client.start();
      return client;
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
