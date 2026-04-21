# PhoenixReplay

> **Status:** pre-alpha. API not frozen. Do not use in production.

In-app bug-report widget + `rrweb` session-replay ingest for Phoenix
applications. Capture console logs, network timeline, DOM mutations, and
host-supplied metadata from a floating widget; store everything in your
own database; replay it inside your own admin UI.

No SaaS dependency. No lock-in. MIT.

## Why

When QA says "I saw the page go weird, can you reproduce?", the
time-to-fix is dominated by the time-to-reproduce. PhoenixReplay captures
the reproduction automatically, stores it under your control, and plays
it back in your own admin pages — the way LogRocket / Sentry Replay /
PostHog do it, but self-hosted inside a Phoenix app at near-zero
marginal cost.

## Status

- [ ] Phase 0 — Repo scaffold + API freeze
- [ ] Phase 1 — Capture client JS (rrweb + widget + session token)
- [ ] Phase 2 — Ingest controllers + Ecto storage
- [ ] Phase 3 — Admin UI components + rrweb-player LV hook
- [ ] Phase 4 — Ash companion (`ash_feedback`)
- [ ] Phase 5 — Hex publish

## Companion packages

- [`ash_feedback`](../ash_feedback) — Ash adapter for the
  `PhoenixReplay.Storage` behaviour. Gives Ash users idiomatic
  resources, policies, `AshPrefixedId`, `AshPaperTrail`, and `AshGrant`
  scope examples without forcing Ash on non-Ash hosts.

## Installation

_(not yet published)_

```elixir
def deps do
  [
    {:phoenix_replay, path: "../phoenix_replay"}  # incubation
    # Later: {:phoenix_replay, "~> 0.1"}
  ]
end
```

## Quick start (design target — not implemented yet)

```elixir
# config/config.exs
config :phoenix_replay,
  identify: {MyApp.Auth, :fetch_identity, []},
  metadata: {MyApp, :feedback_metadata, 1},
  storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo}

# router.ex
import PhoenixReplay.Router
feedback_routes "/api/feedback"

# root.html.heex
<.phoenix_replay_widget csrf_token={get_csrf_token()} />
```

## License

MIT. See [LICENSE](LICENSE).
