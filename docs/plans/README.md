# phoenix_replay — Plans

Forward-looking work plans. Completed phases are in
[`../../README.md`](../../README.md) under **Status** and live in git
history. Newer plans live under `active/`, `backlog/`, `proposals/`,
`completed/` — legacy phase files remain flat until re-filed.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| — | On-demand recording mode ("Start Reproduction") | Phase 1 shipped (`48d2c90`); Phase 2 pending | [active/2026-04-23-on-demand-recording.md](active/2026-04-23-on-demand-recording.md) |
| — | Session continuity across page loads (ADR-0003) | accepted, plan TBD | — |
| 5f | Igniter installer for `mix phoenix_replay.install` | proposed | [5f-igniter-installer.md](5f-igniter-installer.md) |
| 6  | Hex publish | deferred | — |

ADR-0002 (on-demand recording): Phase 1 (JS lifecycle refactor + `recording` attr + 4 JS API methods) shipped 2026-04-23 in `48d2c90`. Phase 2 (pill UI + Start-CTA panel flow + `/session` error state) pending.

ADR-0003 (session continuity): Accepted 2026-04-23 with all five open questions resolved. Implementation plan not yet written — natural "next workstream" once Phase 2 starts or before, they're orthogonal.

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
