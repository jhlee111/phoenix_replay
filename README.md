# PhoenixReplay

> **Status: Proof of Concept.** APIs will change. Do not use in
> production. Shipped and exercised daily inside a single host
> application (gs_net) — adoption elsewhere will surface edges.

In-app bug-report widget + [`rrweb`](https://github.com/rrweb-io/rrweb)
session-replay ingest for Phoenix applications. Capture console logs,
network timeline, DOM mutations, and host-supplied metadata from a
floating widget; store it in your own database; replay it inside your
own admin UI.

No SaaS dependency. No lock-in. MIT.

## Why

When QA says "I saw the page go weird, can you reproduce?", time-to-fix
is dominated by time-to-reproduce. PhoenixReplay captures the
reproduction automatically, stores it under your control, and plays it
back in your own admin pages — the way LogRocket / Sentry Replay /
PostHog do it, but self-hosted inside a Phoenix app at near-zero
marginal cost.

## Architecture

```
┌─────────────┐    POST /session    ┌───────────────┐
│   Widget    │ ────────────────►   │ Ingest        │
│ (browser)   │    POST /events     │ controllers   │
│  rrweb +    │    POST /submit     │               │
│  recorder   │                     └───────┬───────┘
└─────────────┘                             │
                                            ▼
                                    ┌───────────────┐
                                    │   Storage     │
                                    │   behaviour   │
                                    └───────┬───────┘
                                            │
                             ┌──────────────┴──────────────┐
                             ▼                             ▼
                    PhoenixReplay.Storage.Ecto      AshFeedback.Storage
                    (raw Ecto, always for events)   (Ash resource, optional
                                                     — routes feedback writes
                                                     through your Ash domain)
```

Events (rrweb frames) always land on raw Ecto — high-volume, append-only,
JSONB. Feedback rows can optionally be persisted as an Ash resource if
you install [`ash_feedback`](https://github.com/jhlee111/ash_feedback) —
you get policies, PaperTrail, AshPrefixedId, and a triage state machine
baked into the Feedback resource.

> Not to be confused with
> [`ash_storage`](https://github.com/ash-project/ash_storage) — that's
> an official Ash extension for **file attachments** (images, PDFs).
> `ash_feedback` is about the Feedback row itself, not file uploads.

## Requirements

- Elixir 1.14+
- Phoenix 1.7+ / LiveView 0.20+
- Postgres (migrations use `jsonb`, `citext`, `uuid_generate_v4`)
- A session store (the ingest pipeline requires `fetch_session` +
  `protect_from_forgery`)

## Installation

```elixir
# mix.exs
def deps do
  [
    {:phoenix_replay, github: "jhlee111/phoenix_replay", branch: "main"}
  ]
end
```

Then:

```bash
mix deps.get
mix phoenix_replay.install   # writes one migration
mix ecto.migrate
```

The installer creates one migration that provisions two tables:

- `phoenix_replay_feedbacks` — one row per submitted bug report
- `phoenix_replay_events` — rrweb frames, keyed by session

### 1. Configure

```elixir
# config/config.exs (or per-env)
config :phoenix_replay,
  environment: config_env(),
  identify: {MyApp.Feedback.Identify, :fetch_identity, []},
  metadata: {MyApp.Feedback.Identify, :fetch_metadata, []},
  storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo},
  session_token_secret: System.get_env("PHOENIX_REPLAY_SECRET") ||
    raise("missing PHOENIX_REPLAY_SECRET (≥32 bytes)"),
  limits: [max_batch_bytes: 5_000_000],
  scrub: [
    console: [
      ~r/Bearer\s+[A-Za-z0-9._\-]+/,
      ~r/api[_-]?key[=:"'\s]+[A-Za-z0-9._\-]+/i,
      ~r/eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+/
    ],
    query_deny_list: ~w(token access_token password secret code)
  ]
```

**Config keys:**

| Key | Purpose |
|-----|---------|
| `environment` | Tagged on every batch. Used by the triage UI to distinguish `:dev` / `:staging` / `:preview` / `:prod`. |
| `identify` | `{M, F, A}` — returns `%{kind: atom, id: String, attrs: map}` or `nil` (401). Only authed users may open a session. |
| `metadata` | `{M, F, A}` — server-side enrichment merged into each submitted feedback (`environment`, `user_agent`, `remote_ip`, etc.). |
| `storage` | `{module, opts}` implementing the `PhoenixReplay.Storage` behaviour (the write path for feedback + events). Bundled: `PhoenixReplay.Storage.Ecto` (raw Ecto). For an Ash-native Feedback resource with triage + PaperTrail + policies, use `{AshFeedback.Storage, resource: ..., repo: ...}` from [`ash_feedback`](https://github.com/jhlee111/ash_feedback). |
| `session_token_secret` | HMAC secret for session tokens. ≥32 bytes. Rotate per environment. |
| `limits` | `max_batch_bytes` — single POST cap. Complex admin pages can emit >1MB FullSnapshots; 5MB is a safe dev default. |
| `scrub` | PII rules applied BEFORE storage. Setting `console:` or `query_deny_list:` **replaces** defaults, so re-declare the baseline patterns plus your host-specific ones. |

### 2. Router

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import PhoenixReplay.Router

  pipeline :feedback_ingest do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :load_from_session  # or your auth plug — must assign :current_user
  end

  pipeline :admin_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :load_from_session
  end

  # Widget → ingest
  scope "/" do
    pipe_through :feedback_ingest
    feedback_routes "/api/feedback"
  end

  # Admin replay JSON (rrweb event fetch for playback)
  scope "/admin" do
    pipe_through :admin_json
    admin_routes "/feedback"
  end
end
```

Both macros come from `PhoenixReplay.Router`. `feedback_routes` mounts
`POST /session`, `POST /events`, `POST /submit`. `admin_routes` mounts
`GET /:session_id/events`.

### 3. Endpoint — serve widget assets

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/phoenix_replay",
  from: {:phoenix_replay, "priv/static/assets"},
  gzip: false
```

### 4. Mount the widget in your root layout

```heex
# lib/my_app_web/components/layouts/root.html.heex
<body>
  {@inner_content}
  <PhoenixReplay.UI.Components.phoenix_replay_widget
    :if={Application.get_env(:my_app, :feedback_widget_enabled, false)}
    base_path="/api/feedback"
    csrf_token={get_csrf_token()}
  />
</body>
```

`rrweb` is loaded from jsdelivr by default. Self-host with
`rrweb_src="/assets/rrweb.min.js"` or disable replay entirely with
`rrweb_src={nil}` (description + severity still submit).

The widget auto-mounts on `DOMContentLoaded` — no JS glue required.

### 5. Identity callback

```elixir
# lib/my_app/feedback/identify.ex
defmodule MyApp.Feedback.Identify do
  def fetch_identity(conn) do
    case conn.assigns[:current_user] do
      %{id: id} = user ->
        %{
          kind: :user,
          id: to_string(id),
          attrs: %{"email" => to_string(user.email)}
        }

      _ ->
        # Anonymous → 401. The widget self-hides when the handshake fails.
        nil
    end
  end

  def fetch_metadata(conn) do
    %{
      "environment" => to_string(Application.get_env(:phoenix_replay, :environment)),
      "user_agent" => first_header(conn, "user-agent"),
      "referer" => first_header(conn, "referer"),
      "remote_ip" => format_ip(conn.remote_ip)
    }
  end

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name), do: ([v | _] -> v; _ -> nil)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: nil
end
```

### 6. Build your admin UI

The library ships the JSON endpoints + the `rrweb-player` LiveView hook.
You bring the listing/detail LVs. For a Cinder + Ash-native triage UI,
use [`ash_feedback`](https://github.com/jhlee111/ash_feedback) as the
storage adapter — it adds a state machine, comments, PubSub, and
PaperTrail.

## Scrubber — redacting PII

Scrubbing happens on the ingest side **before** rows reach the DB.
Patterns are Regex; first match wins and replaces with `"***REDACTED***"`.

- `scrub: [console: [...]]` — matched against stringified console args
- `scrub: [query_deny_list: [...]]` — URL query-string keys (not values)
  stripped from the network timeline

**Gotcha**: setting either key replaces the library defaults. Re-declare
the baseline patterns (Bearer, API-key, JWT) plus host-specific ones.

## Docs

- [`docs/plans/README.md`](docs/plans/README.md) — forward-looking
  plan index (5f / 6)

## Status

- [x] Phase 0 — Repo scaffold + API freeze
- [x] Phase 1 — Capture client JS (rrweb + widget + session handshake)
- [x] Phase 2 — Ingest controllers + Ecto storage adapter
- [x] Phase 3 — Admin UI components + rrweb-player LV hook
- [x] Phase 4 — Ash companion (`ash_feedback`)
- [ ] [Phase 5f](docs/plans/5f-igniter-installer.md) — Igniter installer (`mix phoenix_replay.install`)
- [ ] Phase 6 — Hex publish (PoC hardening first)

## Companion packages

- [`ash_feedback`](https://github.com/jhlee111/ash_feedback) — Ash
  resource for the Feedback row, with policies, `AshPrefixedId`,
  `AshPaperTrail`, PubSub, and a triage state machine
  (new → acknowledged → in_progress → verified_on_preview → resolved).
  Ships a thin `PhoenixReplay.Storage` implementation that routes
  `POST /submit` through the Ash domain.

## License

MIT. See [LICENSE](LICENSE).
