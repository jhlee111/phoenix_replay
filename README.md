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

- [x] Phase 0 — Repo scaffold + API freeze
- [x] Phase 1 — Capture client JS (rrweb + widget + session token handshake)
- [ ] Phase 2 — Ingest controllers + Ecto storage
- [ ] Phase 3 — Admin UI components + rrweb-player LV hook
- [ ] Phase 4 — Ash companion (`ash_feedback`)
- [ ] Phase 5 — Hex publish

### How to mount the widget (Phase 1)

```elixir
# lib/my_app_web/endpoint.ex — serve the widget assets
plug Plug.Static,
  at: "/phoenix_replay",
  from: {:phoenix_replay, "priv/static/assets"},
  gzip: false
```

```heex
# lib/my_app_web/components/layouts/root.html.heex
<.phoenix_replay_widget
  base_path={~p"/api/feedback"}
  csrf_token={get_csrf_token()}
/>
```

`rrweb` is loaded from a CDN by default (`jsdelivr`). Override with
`rrweb_src={...}` to self-host, or `rrweb_src={nil}` to disable replay
(description + severity still submit).

The widget auto-mounts on DOMContentLoaded — no JS glue required.

> Transport endpoints (`/session`, `/events`, `/submit`) land in Phase 2.
> The widget currently renders and handshakes against stubs that return
> 501 Not Implemented.

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
