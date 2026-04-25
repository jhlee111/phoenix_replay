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
  // Per-session one-shot replay player registry — captures the
  // rrweb-player instance for the timeline event bus (ADR-0005). Live
  // players already track their instance under `livePlayers`.
  const replayPlayers = new Map();

  // ADR-0005 timeline event bus — emits state-change events to the
  // window for any consumer to observe (audio sync, LV state debugger,
  // overlays, etc). See `wireTimelineBus` for what we attach to and
  // `dispatchTimeline` for the payload shape.
  const TIMELINE_EVENT = "phoenix_replay:timeline";
  // Heuristic for detecting user scrub vs. natural playback: if the
  // current-time delta between two consecutive ui-update-current-time
  // events exceeds (expected by speed) by more than this much, treat
  // it as a seek. 500ms is well above RAF jitter at any speed.
  const SEEK_DELTA_THRESHOLD_MS = 500;
  // Per-session subscribers registered via `subscribeTimeline`. Each
  // entry: `{callback, intervalId, tickHz}`. State events fan out to
  // every subscriber regardless of `tickHz`; tick events come from
  // each subscriber's own interval (independent throttling).
  const subscribers = new Map();

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
      replayPlayers.set(sessionId, { el, player });
      wireTimelineBus(player, sessionId);
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
    wireTimelineBus(state.player, sessionId);

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

  // ADR-0005 Phase 1 — attach state-change listeners and dispatch
  // window CustomEvents on the timeline bus. Tick events + the
  // `subscribeTimeline` helper land in Phase 2.
  function wireTimelineBus(player, sessionId) {
    if (!player || !sessionId) return;

    let speed = 1;
    let lastTimeMs = 0;
    let lastTimeStamp = performance.now();
    let lastDispatchedKind = null;

    const emit = (kind, timecodeMs) =>
      dispatchTimeline(sessionId, kind, timecodeMs, speed);

    // play / pause come through the same event with a string payload.
    // rrweb-player fires "playing" | "paused" | "live"; we only care
    // about the first two for the public bus.
    player.addEventListener("ui-update-player-state", (payload) => {
      const state = typeof payload === "string" ? payload : payload?.payload;
      if (state === "playing" && lastDispatchedKind !== "play") {
        lastDispatchedKind = "play";
        // Re-anchor the wall-clock so the first ui-update-current-time
        // after resume isn't compared against an elapsed-during-pause
        // wallElapsed (which would falsely trip the seek heuristic).
        lastTimeStamp = performance.now();
        emit("play", lastTimeMs);
      } else if (state === "paused" && lastDispatchedKind !== "pause") {
        lastDispatchedKind = "pause";
        emit("pause", lastTimeMs);
      }
    });

    // Current-time updates fire at RAF cadence while playing. Use them
    // to (a) keep `lastTimeMs` fresh for state-change payloads, and
    // (b) detect user scrubs as discontinuities exceeding what `speed`
    // would predict for the wall-clock elapsed since the last update.
    player.addEventListener("ui-update-current-time", (payload) => {
      const t = typeof payload === "number" ? payload : payload?.payload;
      if (typeof t !== "number") return;

      const now = performance.now();
      const wallElapsed = now - lastTimeStamp;
      const expectedDelta = wallElapsed * speed;
      const actualDelta = t - lastTimeMs;
      const drift = Math.abs(actualDelta - expectedDelta);

      if (lastTimeMs > 0 && drift > SEEK_DELTA_THRESHOLD_MS) {
        emit("seek", t);
      }

      lastTimeMs = t;
      lastTimeStamp = now;
    });

    // `replayer.on("finish")` is the canonical end-of-playback signal.
    // Guard with try/catch — on alpha builds the replayer may not be
    // ready synchronously after Player construction.
    try {
      const replayer = player.getReplayer?.();
      replayer?.on?.("finish", () => emit("ended", lastTimeMs));
    } catch (_) {
      /* replayer not ready; ended event simply won't fire */
    }
  }

  function dispatchTimeline(sessionId, kind, timecodeMs, speed) {
    const detail = {
      session_id: sessionId,
      kind,
      timecode_ms: typeof timecodeMs === "number" ? Math.round(timecodeMs) : 0,
      speed: typeof speed === "number" ? speed : 1,
    };
    // 1. Window CustomEvent — escape hatch for advanced consumers.
    window.dispatchEvent(new CustomEvent(TIMELINE_EVENT, { detail }));
    // 2. Per-session subscribers (via subscribeTimeline) — friendlier
    //    path that handles per-subscriber tick rate.
    notifySubscribers(sessionId, detail);
  }

  function notifySubscribers(sessionId, detail) {
    const list = subscribers.get(sessionId);
    if (!list || list.length === 0) return;
    for (const sub of list) {
      try {
        sub.callback(detail);
      } catch (err) {
        console.error("[PhoenixReplay] timeline subscriber callback error:", err);
      }
    }
  }

  function getPlayerForSession(sessionId) {
    return (
      replayPlayers.get(sessionId)?.player ||
      livePlayers.get(sessionId)?.player ||
      null
    );
  }

  // ADR-0005 Phase 2 — friendlier subscription helper. Most consumers
  // should never need to talk to the raw `phoenix_replay:timeline`
  // window event; subscribe here and get state events + a chosen tick
  // cadence delivered straight to your callback.
  //
  //   const stop = PhoenixReplayAdmin.subscribeTimeline(sessionId, fn, {
  //     tick_hz: 10,           // default; 0 disables ticks (state-only)
  //     deliver_initial: true, // fire one :tick synchronously on subscribe
  //   });
  //   // ...later:
  //   stop();
  //
  // Tick subscribers are independent — high-rate consumers don't pay
  // for low-rate ones, and vice versa. State events (play/pause/seek/
  // ended) reach every subscriber regardless of `tick_hz`.
  function subscribeTimeline(sessionId, callback, opts = {}) {
    if (!sessionId || typeof callback !== "function") {
      console.warn("[PhoenixReplay] subscribeTimeline requires sessionId + callback");
      return () => {};
    }

    const tickHz = typeof opts.tick_hz === "number" ? opts.tick_hz : 10;
    const deliverInitial = opts.deliver_initial !== false;

    const tick = () => {
      const player = getPlayerForSession(sessionId);
      if (!player) return;
      let t = 0;
      try {
        const replayer = player.getReplayer?.();
        const got = replayer?.getCurrentTime?.();
        if (typeof got === "number") t = got;
      } catch (_) {
        return;
      }
      try {
        callback({
          session_id: sessionId,
          kind: "tick",
          timecode_ms: Math.round(t),
          speed: 1,
        });
      } catch (err) {
        console.error("[PhoenixReplay] timeline subscriber callback error:", err);
      }
    };

    const intervalId = tickHz > 0 ? setInterval(tick, 1000 / tickHz) : null;
    const entry = { callback, intervalId, tickHz };

    if (!subscribers.has(sessionId)) subscribers.set(sessionId, []);
    subscribers.get(sessionId).push(entry);

    // `tick_hz: 0` means "no tick events at all" — deliver_initial is
    // a no-op in that case so the contract stays clean for state-only
    // consumers (e.g. annotation logs).
    if (deliverInitial && tickHz > 0) tick();

    return function unsubscribe() {
      if (entry.intervalId) clearInterval(entry.intervalId);
      const list = subscribers.get(sessionId);
      if (!list) return;
      const idx = list.indexOf(entry);
      if (idx >= 0) list.splice(idx, 1);
      if (list.length === 0) subscribers.delete(sessionId);
    };
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

  global.PhoenixReplayAdmin = { initAll, initOne, subscribeTimeline };
})(window);
