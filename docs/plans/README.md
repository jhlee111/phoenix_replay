# phoenix_replay — Plans

Forward-looking work plans. Completed phases are in
[`../../README.md`](../../README.md) under **Status** and live in git
history. Newer plans live under `active/`, `backlog/`, `proposals/`,
`completed/` — legacy phase files remain flat until re-filed.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| 5f | Igniter installer for `mix phoenix_replay.install` | proposed | [5f-igniter-installer.md](5f-igniter-installer.md) |
| 6  | Hex publish | deferred | — |

**Next candidate (no plan yet)**: on-demand recording mode (Jam-style
"start reproduction") — spec'd as a follow-up in ADR-0001. Needs its
own ADR (0002 candidate) and plan before work starts.

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
