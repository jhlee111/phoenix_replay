# phoenix_replay — Plans

Forward-looking work plans. Completed phases are in
[`../../README.md`](../../README.md) under **Status** and live in git
history. Newer plans live under `active/`, `backlog/`, `proposals/`,
`completed/` — legacy phase files remain flat until re-filed.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| — | Session continuity across page loads (ADR-0003) | Phase 1 shipped (`044f250`); Phase 2 pending | [active/2026-04-23-session-continuity.md](active/2026-04-23-session-continuity.md) |
| 5f | Igniter installer for `mix phoenix_replay.install` | proposed | [5f-igniter-installer.md](5f-igniter-installer.md) |
| 6  | Hex publish | deferred | — |

ADR-0003 (session continuity): Phase 1 shipped 2026-04-23 in `044f250` — client-side `sessionStorage` + `fetch(keepalive)` tail flush + `/session` resume branch + `Storage.resume_session/2` callback. Phase 2 (`PhoenixReplay.Session` GenServer + Registry + PubSub broadcasts + idle timeout) is the next workstream here.

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
