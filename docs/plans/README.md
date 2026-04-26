# phoenix_replay — Plans

Forward-looking work plans. Completed phases are in
[`../../README.md`](../../README.md) under **Status** and live in git
history. Newer plans live under `active/`, `backlog/`, `proposals/`,
`completed/` — legacy phase files remain flat until re-filed.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| —  | Mode-aware panel addons + Path A/B IA | Shipped 2026-04-25 — `registerPanelAddon({modes})`, Path B trigger renamed | [`docs/superpowers/specs/2026-04-25-mode-aware-panel-addons.md`](../superpowers/specs/2026-04-25-mode-aware-panel-addons.md) / [plan](../superpowers/plans/2026-04-25-mode-aware-panel-addons.md) |
| —  | Unified Feedback Entry (ADR-0006) | Phases 1 + 2 + 2b + 3 + 4 shipped 2026-04-25..2026-04-26. ADR closed. | [ADR](../decisions/0006-unified-feedback-entry.md) / [spec](../superpowers/specs/2026-04-25-unified-feedback-entry-design.md) / [Phase 1](../superpowers/plans/2026-04-25-unified-entry-phase-1.md) / [Phase 2](../superpowers/plans/2026-04-25-unified-entry-phase-2.md) / [Phase 2b](../superpowers/plans/2026-04-26-unified-entry-phase-2b-hardening.md) / [Phase 3](../superpowers/plans/2026-04-25-unified-entry-phase-3.md) / [Phase 4](../superpowers/plans/2026-04-26-unified-entry-phase-4-shim-drop.md) |
| 6  | Hex publish | deferred | — |

## Proposals (drafted, not yet committed)

_None._

Open follow-ups (no plan file yet): session-abandonment dashboard, JS test infrastructure (Playwright/Puppeteer — recurring debt across ADR-0001/2/3/4), ADR-0004 Phase 3 (reusable `<.session_watch>` / `<.sessions_index>` components for power users — deferred until a real consumer needs them), README addon-API doc refresh (Options section still claims `slot: "form-top"` is the only supported slot; Phase 3 added `pill-action` + `review-media` but the prose was never updated; flagged in ADR-0006 Phase 4 review 2026-04-26), ADR-0005 follow-ups (`speed:` field hardcoded to `1` in `player_hook.js`'s `wireTimelineBus` — needs rrweb-player speed-UI wiring; subscribers don't auto-unsubscribe when `replayPlayers`/`livePlayers` entries are removed — consumers must call `unsubscribe()` themselves today).

## Completed phases (historical)

| # | Scope | When |
|---|-------|------|
| 0  | Repo scaffold + API freeze | — |
| 1  | Capture client JS (rrweb + widget + session token handshake) | — |
| 2  | Ingest controllers + Ecto storage adapter | — |
| 3  | rrweb-player LiveView hook + admin JSON endpoints | — |
| 4  | Ash companion (`ash_feedback`) | — |
| 5a | Triage columns migration (consolidated into base install) | — |
| — | Widget trigger UX — position preset + headless mode (ADR-0001) — see [completed plan](completed/2026-04-23-widget-trigger-ux.md) | 2026-04-23 |
| — | On-demand recording ("Start Reproduction") — `recording={:on_demand}`, pill UI, panel state machine (ADR-0002); Phase 1 in `48d2c90`, Phase 2 in `3da8bfc` — see [completed plan](completed/2026-04-23-on-demand-recording.md) | 2026-04-23 |
| — | Session continuity across page loads (ADR-0003); Phase 1 in `044f250` (client + minimal server), Phase 2 in `87057aa` (`PhoenixReplay.Session` GenServer + Registry + PubSub broadcasts + idle teardown) — see [completed plan](completed/2026-04-23-session-continuity.md) | 2026-04-23 |
| — | Live session watch — admin "shoulder-surf" (ADR-0004); Phase 1 in `d65d0f7` (`Live.SessionWatch` + per-session catchup + dedup + JS live-mode), Phase 2 in `b4fa097` (`Live.SessionsIndex` + global topic + `Session.list_active/0`) — see [completed plan](completed/2026-04-24-live-session-watch.md) | 2026-04-24 |
| 5f | Igniter installer (`mix igniter.install phoenix_replay`) — config + router + endpoint + root layout + identify stub + migration patchers, all idempotent. Shipped across `ee8cf9d` / `630f66b` / `a3f5e90` / `bdb43d4` — see [completed plan](completed/2026-04-24-5f-igniter-installer.md) | 2026-04-24 |
| — | Replay player timeline event bus (ADR-0005); Phase 1 in `0a66fab` (window `phoenix_replay:timeline` event channel + `play`/`pause`/`seek`/`ended` state events on both one-shot and live-mode players), Phase 2 in `777d3b0` (`PhoenixReplayAdmin.subscribeTimeline` helper + per-subscriber tick cadence), Phase 3 docs (new `docs/guides/timeline-event-bus.md` + README section) — see [completed plan](completed/2026-04-24-timeline-event-bus.md) | 2026-04-24..2026-04-26 |
