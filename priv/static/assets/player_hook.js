// PhoenixReplay — rrweb-player auto-init script.
//
// Scans the document for `[data-phoenix-replay-player]` elements and
// initializes `rrweb-player` on each. Two modes:
//
//   * `data-mode="replay"` (default) — one-shot: fetches the event
//     stream from `data-events-url` and renders a finite session.
//   * `data-mode="live"` (ADR-0004) — streams: seeds from a
//     `phx:phoenix_replay:catchup` window event and appends frames
//     as `phx:phoenix_replay:append` events arrive. Scoped by
//     `data-session-id` so multiple live players on the same page
//     (rare) stay isolated.
//
// Re-runs on DOMContentLoaded AND on LiveView DOM patches (via a
// MutationObserver) so admin LVs get players for free.
//
// Requires: the rrweb-player ESM script + stylesheet loaded earlier
// in the page (the `<.phoenix_replay_admin_assets />` component emits
// them).

(function (global) {
  "use strict";

  const MOUNT_ATTR = "data-phoenix-replay-player";
  const INITIALIZED = "__phx_replay_initialized";
  // Per-session live player registry — populated on first catchup.
  // `pending` buffers live appends that arrive before the player is
  // initialized (e.g. rrweb-player script still loading).
  const livePlayers = new Map();

  // ADR-0005 timeline event bus moved to phoenix_replay.js so the
  // panel mini-player can publish on the same channel as admin players.
  // The bus primitives — `wireTimelineBus`, `registerPlayer`,
  // `subscribeTimeline` — live on `window.PhoenixReplay`. This file
  // resolves them lazily because phoenix_replay.js may load after
  // player_hook.js depending on host script order.
  const bus = () => global.PhoenixReplay;

  async function initOne(el) {
    if (el[INITIALIZED]) return;
    el[INITIALIZED] = true;

    const mode = el.getAttribute("data-mode") || "replay";
    if (mode === "live") {
      initLive(el);
      return;
    }

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
      const player = new Player({
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

      const sessionId = el.getAttribute("data-session-id") || el.id;
      bus()?.registerPlayer?.(sessionId, player);
      bus()?.wireTimelineBus?.(player, sessionId);
    } catch (err) {
      console.error("[PhoenixReplay] player init failed:", err);
      el.textContent = `Replay error: ${err.message}`;
    }
  }

  function initLive(el) {
    const sessionId = el.getAttribute("data-session-id");
    if (!sessionId) {
      console.warn("[PhoenixReplay] live player missing data-session-id");
      return;
    }

    // Placeholder until catchup arrives.
    el.textContent = "Waiting for session…";

    // Register or merge with any pre-existing entry (an append may
    // have arrived before init, though the LV orders catchup first —
    // this is defensive).
    const prior = livePlayers.get(sessionId);
    livePlayers.set(sessionId, {
      el,
      player: null,
      initialized: false,
      pending: prior?.pending || [],
    });
  }

  async function handleCatchup(sessionId, events) {
    const state = livePlayers.get(sessionId);
    if (!state) return;

    const Player = await resolvePlayer();
    if (!Player) {
      state.el.textContent =
        "rrweb-player not loaded. Include <.phoenix_replay_admin_assets /> in the layout.";
      return;
    }

    // rrweb-player needs at least the full-snapshot meta event to
    // initialize. An empty catchup means the recording just started
    // and nothing has been persisted yet; wait for the first append
    // to arrive (it will include the full snapshot).
    if (!events || events.length === 0) {
      state.pendingCatchup = true;
      return;
    }

    state.el.textContent = "";
    state.player = new Player({
      target: state.el,
      props: {
        events,
        width: state.el.clientWidth || 1024,
        height: parseInt(state.el.getAttribute("data-height"), 10) || 560,
        autoPlay: true,
        showController: true,
        maxScale: 1,
      },
    });
    state.initialized = true;
    bus()?.registerPlayer?.(sessionId, state.player);
    bus()?.wireTimelineBus?.(state.player, sessionId);

    // Flush appends buffered during the init window.
    if (state.pending.length > 0) {
      state.pending.forEach((ev) => state.player.addEvent(ev));
      state.pending = [];
    }
  }

  async function handleAppend(sessionId, events) {
    let state = livePlayers.get(sessionId);
    if (!state) {
      // LV pushed an append before initLive ran for this element —
      // stash for later.
      state = { el: null, player: null, initialized: false, pending: [] };
      livePlayers.set(sessionId, state);
    }

    // If catchup was empty earlier, treat the first append as the
    // seed instead of a live frame append.
    if (state.pendingCatchup) {
      state.pendingCatchup = false;
      await handleCatchup(sessionId, events);
      return;
    }

    if (state.initialized && state.player) {
      events.forEach((ev) => state.player.addEvent(ev));
    } else {
      state.pending.push(...events);
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

  // LiveView `push_event/3` dispatches each event as
  // `phx:<name>` on `window`, with the payload on `e.detail`.
  // See ADR-0004 / Live.SessionWatch for the three events below.
  window.addEventListener("phx:phoenix_replay:catchup", (e) => {
    const { session_id, events } = e.detail || {};
    if (session_id) handleCatchup(session_id, events || []);
  });
  window.addEventListener("phx:phoenix_replay:append", (e) => {
    const { session_id, events } = e.detail || {};
    if (session_id) handleAppend(session_id, events || []);
  });
  // :closed / :abandoned are rendered by the LV template
  // (status banner below the player). No JS action needed beyond
  // letting the rrweb-player idle — no more addEvent calls will
  // arrive after the session ends.

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      initAll();
      observe();
    });
  } else {
    initAll();
    observe();
  }

  // PhoenixReplayAdmin keeps subscribeTimeline as a back-compat alias —
  // existing consumers (audio_playback hook, host scripts) keep working
  // unchanged while internally delegating to phoenix_replay.js's bus.
  global.PhoenixReplayAdmin = {
    initAll,
    initOne,
    subscribeTimeline: (sessionId, callback, opts) =>
      bus()?.subscribeTimeline?.(sessionId, callback, opts) || (() => {}),
  };
})(window);
