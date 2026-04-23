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
| `session_idle_timeout_ms` | Default `900_000` (15 min). After this much inactivity, a session can no longer be resumed across page loads and the per-session GenServer broadcasts `:session_abandoned` and exits. |
| `pubsub` | Optional. Atom naming the host's `Phoenix.PubSub` instance. When set, `PhoenixReplay.Session` broadcasts ride that bus (live admin views can subscribe). When unset, the library starts its own `PhoenixReplay.PubSub` — zero-config but burns one extra process. |
| `pubsub_topic_prefix` | Default `"phoenix_replay"`. Topics resolve to `"\#{prefix}:session:\#{session_id}"`. Bump only if you have a name collision. |

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

### 4a. Moving the toggle button

The default `:bottom_right` corner often collides with existing chat
widgets (Intercom / Crisp) or the LiveView debugger pill in dev. Pick
another corner with the `position` preset attr:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  position={:bottom_left}
/>
```

Valid values: `:bottom_right` (default), `:bottom_left`, `:top_right`,
`:top_left`.

For offsets other than the four corners, use the CSS custom
properties exposed on `.phx-replay-toggle` in a host stylesheet
loaded after the library's:

```css
.phx-replay-toggle {
  --phx-replay-toggle-bottom: 5rem;  /* above a footer bar */
  --phx-replay-toggle-right:  2rem;
  /* also available: --phx-replay-toggle-top, --phx-replay-toggle-left,
     --phx-replay-toggle-z */
}
```

The preset classes are wrapped in `:where()`, so a host override on
`.phx-replay-toggle` always wins — no `!important` needed.

### 4b. Headless mode — bring your own trigger

Add the widget with `mode={:headless}` to skip the floating button
entirely. The panel still renders; your code decides when to open it.

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  mode={:headless}
/>

<button data-phoenix-replay-trigger>Report a bug</button>
```

Any element carrying the `data-phoenix-replay-trigger` attribute opens
the panel when clicked. The listener is delegated at the document
level, so dropdown items, LiveView-patched DOM, and dynamically
inserted triggers all work without re-binding.

For programmatic control — keyboard shortcuts, "something went wrong"
modals that prompt a bug report, etc. — call the global API from your
JS:

```js
window.PhoenixReplay.open();
window.PhoenixReplay.close();
```

See [`docs/guides/headless-integration.md`](docs/guides/headless-integration.md)
for worked examples (header link, keyboard shortcut, self-hosted
assets).

### 4c. Recording mode — continuous vs on-demand

By default (`recording={:continuous}`), rrweb starts capturing the
moment the widget mounts. The user sees a bug, clicks the toggle,
describes it, and the preceding events are already on disk —
retroactive reporting.

Pass `recording={:on_demand}` to flip the contract: the recorder
stays idle until the user explicitly clicks Start. The `/session`
handshake is deferred too — sessions that never lead to a
reproduction create no server state.

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  recording={:on_demand}
/>
```

The four combinations:

| `mode` × `recording` | Behavior |
|---|---|
| `:float` × `:continuous` (default) | Toggle visible, rrweb captures from mount, submit flushes the tail. |
| `:float` × `:on_demand` | Toggle click opens a Start CTA. Start swaps toggle for a pulsing Recording pill with a Stop button; Stop opens the submit form. |
| `:headless` × `:continuous` | No toggle, rrweb captures from mount, host opens the panel when the user wants to report. |
| `:headless` × `:on_demand` | No toggle. Host calls `window.PhoenixReplay.startRecording()` / `.stopRecording()` from its own UX (e.g., custom consent modal); `stopRecording()` opens the submit form. |

**Privacy positioning.** `:continuous` is appropriate for internal
tools, staging, or consumer surfaces where capture is disclosed in
the privacy policy. `:on_demand` is the right pick for regulated
verticals, customer-facing beta programs, or any product where
explicit per-session consent is required. It can always be upgraded
to `:continuous` later; the reverse is a privacy-policy change.

See [`docs/guides/on-demand-recording.md`](docs/guides/on-demand-recording.md)
for the full flows, pill positioning, and multi-tab notes.

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

### 6. Subscribe to live session events (optional)

Each in-flight session is owned by a `PhoenixReplay.Session` GenServer
(supervised by `PhoenixReplay.SessionSupervisor`, registered under
`PhoenixReplay.SessionRegistry`). It broadcasts on
`"\#{prefix}:session:\#{session_id}"`:

- `{:event_batch, session_id, events, seq}` — after a successful
  `POST /events`
- `{:session_closed, session_id, reason}` — `POST /submit` (or any
  manual `Session.close/2` call)
- `{:session_abandoned, session_id, last_event_at}` — idle timeout
  fired without a `close/2`

A live admin LiveView can subscribe and stream rrweb frames into
`rrweb-player` as they land, or render a "session abandoned" timeline
without polling:

```elixir
@impl true
def mount(%{"id" => session_id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "phoenix_replay:session:\#{session_id}")
  end
  ...
end

def handle_info({:event_batch, _session_id, events, _seq}, socket), do: ...
def handle_info({:session_closed, _, _}, socket), do: ...
def handle_info({:session_abandoned, _, _}, socket), do: ...
```

Point the library at your existing PubSub via `config :phoenix_replay,
:pubsub, MyApp.PubSub` so subscribers and broadcasters share one bus.

### 7. Build your admin UI

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

- [`docs/guides/headless-integration.md`](docs/guides/headless-integration.md)
  — worked examples for `mode={:headless}` (header link, keyboard
  shortcut, self-hosted assets)
- [`docs/guides/on-demand-recording.md`](docs/guides/on-demand-recording.md)
  — `recording={:on_demand}` trade-offs, `:float` and `:headless`
  flows, pill positioning, multi-tab scope
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
