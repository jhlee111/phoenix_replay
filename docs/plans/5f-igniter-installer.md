# Phase 5f — Igniter installer for `mix phoenix_replay.install`

**Status**: proposed
**Est**: 4–6 hours (phoenix_replay half; ash_feedback has its own half)

## Motivation

Today `mix phoenix_replay.install` is plain Mix and only copies one
migration. Every other touchpoint (config block, router pipelines +
macro calls, endpoint Plug.Static, root layout widget, identity
callback scaffold) is manual README reading. That's ~15 minutes of
copy-paste per adopter and a real misconfiguration risk.

[Igniter](https://hexdocs.pm/igniter) AST-patches the host codebase
so the whole thing becomes a single command.

## Scope

Rewrite `mix phoenix_replay.install` as an Igniter task composing:

1. **Add dep** to `mix.exs` (skip if already there).
2. **Insert `:phoenix_replay` config** block in `config/config.exs`
   with sensible defaults + `# TODO:` comments for
   `session_token_secret` and `identify` / `metadata` callbacks.
3. **`import PhoenixReplay.Router`** in the host router module.
4. **Add `:feedback_ingest` + `:admin_json` pipelines** (skip if
   already there).
5. **Add `feedback_routes` + `admin_routes` scope calls** under the
   right pipeline.
6. **Insert `Plug.Static` mount** in `endpoint.ex` at
   `/phoenix_replay` → `{:phoenix_replay, "priv/static/assets"}`.
7. **Inject `<PhoenixReplay.UI.Components.phoenix_replay_widget />`**
   in `root.html.heex` behind an
   `Application.get_env(:host_app, :feedback_widget_enabled, false)`
   feature flag.
8. **Generate `HostApp.Feedback.Identify`** stub module with
   `fetch_identity/1` + `fetch_metadata/1` skeletons.
9. **Copy the base migration** (current behaviour) + prompt the
   follow-up `mix ecto.migrate`.

## Fallback for non-Igniter hosts

If Igniter isn't in the host's deps, keep the current plain-Mix
behaviour (copy the migration, print README pointer for the rest).
Detect via `Code.ensure_loaded?(Igniter)`.

## Tests

- Igniter smoke tests against a fresh `mix phx.new` dummy app
  fixture — every patcher idempotent (re-running produces zero
  diff).
- Multi-shape fixtures:
  - Vanilla Phoenix (happy path)
  - Phoenix with existing `:api` pipeline (shouldn't clobber)
  - Phoenix with a custom router file layout (detect or prompt)
- Manual verification: run the installer on a scratch app, mount the
  widget, submit a test feedback without any post-installer edits
  beyond filling in `session_token_secret`.

## Definition of Done

- `mix phoenix_replay.install` runs cleanly on a blank Phoenix app.
- The floating widget appears on the dev server's home page, the
  handshake endpoint returns 200, and a test submission hits the
  database.
- [`../../README.md`](../../README.md) installation section is
  shortened to "run the installer, fill in these 2 TODOs."
- Unit + smoke tests pass.

## Dependencies

- Add `{:igniter, "~> 0.6", optional: true}` to phoenix_replay's
  deps.
- ash_feedback's `mix ash_feedback.install` (its Phase 5f) runs
  AFTER this task; that task's docstring should surface a helpful
  error if `phoenix_replay`'s config isn't detected.
