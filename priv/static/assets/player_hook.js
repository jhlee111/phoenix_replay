// PhoenixReplay — rrweb-player auto-init script.
//
// Scans the document for `[data-phoenix-replay-player]` elements and
// initializes `rrweb-player` on each, fetching the event stream from
// `data-events-url`. Re-runs on DOMContentLoaded AND on LiveView
// DOM patches (via a MutationObserver) so admin LVs get players for
// free.
//
// Requires: the rrweb-player ESM script + stylesheet loaded earlier
// in the page (the `<.phoenix_replay_admin_assets />` component emits
// them).

(function (global) {
  "use strict";

  const MOUNT_ATTR = "data-phoenix-replay-player";
  const INITIALIZED = "__phx_replay_initialized";

  async function initOne(el) {
    if (el[INITIALIZED]) return;
    el[INITIALIZED] = true;

    const eventsUrl = el.getAttribute("data-events-url");
    if (!eventsUrl) {
      console.warn("[PhoenixReplay] player element missing data-events-url");
      return;
    }

    try {
      el.textContent = "Loading replay…";
      const res = await fetch(eventsUrl, {
        credentials: "same-origin",
        headers: { accept: "application/json" },
      });
      if (!res.ok) {
        el.textContent = `Failed to load events (${res.status})`;
        return;
      }
      const { events } = await res.json();
      if (!events || events.length === 0) {
        el.textContent = "No events recorded for this session.";
        return;
      }

      const Player = await resolvePlayer();
      if (!Player) {
        el.textContent =
          "rrweb-player not loaded. Include <.phoenix_replay_admin_assets /> in the layout.";
        return;
      }

      el.textContent = "";
      new Player({
        target: el,
        props: {
          events,
          width: el.clientWidth || 1024,
          height: parseInt(el.getAttribute("data-height"), 10) || 560,
          autoPlay: false,
          showController: true,
          maxScale: 1,
        },
      });
    } catch (err) {
      console.error("[PhoenixReplay] player init failed:", err);
      el.textContent = `Replay error: ${err.message}`;
    }
  }

  async function resolvePlayer() {
    // The UMD bundle exposes `window.rrwebPlayer` as a namespace
    // object: `{ Player, default }`. The constructor is either
    // `.default` (matches the ESM default export) or `.Player`.
    // The assets helper loads the UMD; if the global is missing, it
    // wasn't included.
    const probe = () =>
      global.rrwebPlayer?.default ||
      global.rrwebPlayer?.Player ||
      (typeof global.rrwebPlayer === "function" ? global.rrwebPlayer : null);

    const direct = probe();
    if (direct) return direct;

    // One-frame retry: script tags with `defer` + separate <script>
    // order can briefly race on initial page load.
    await new Promise((r) => setTimeout(r, 50));
    return probe();
  }

  function initAll(root = document) {
    root.querySelectorAll(`[${MOUNT_ATTR}]`).forEach(initOne);
  }

  function observe() {
    const observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        m.addedNodes.forEach((node) => {
          if (node.nodeType !== 1) return;
          if (node.matches?.(`[${MOUNT_ATTR}]`)) initOne(node);
          node.querySelectorAll?.(`[${MOUNT_ATTR}]`).forEach(initOne);
        });
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      initAll();
      observe();
    });
  } else {
    initAll();
    observe();
  }

  global.PhoenixReplayAdmin = { initAll, initOne };
})(window);
