# Multi-page reproductions

> Status: shipped in ADR-0003 (Phase 1: client carry; Phase 2: server
> GenServer + PubSub).

PhoenixReplay can capture a reproduction that spans more than one page
load. A user starts recording on `/orders/42`, clicks an `<a href>` to
`/customers/7`, fills a form, submits it, lands on `/customers/7/edit`
— the entire flow ends up in one continuous rrweb stream attached to
one `session_id`.

## What survives a navigation

| Transition | Survives? |
|---|---|
| `<a href>` to a dead view | ✅ |
| LV → LV `push_navigate` | ✅ |
| LV → dead view (or vice versa) | ✅ |
| `<form method="post">` submit + redirect | ✅ |
| Hard reload (`location.reload`) | ✅ |
| User closes the tab and reopens within idle window | ❌ — `sessionStorage` is per-tab; closing the tab discards the carry token |
| User opens the page in a second tab | ❌ — each tab is its own recording (ADR-0003 OQ4) |
| Idle longer than `:session_idle_timeout_ms` (default 15 min) | ❌ — server marks the session stale |

## How it works

### Layer 1 — client (Phase 1)

On the client, two `sessionStorage` keys carry continuity across an
unload:

- `phx_replay_token` — the session token returned from `POST /session`
- `phx_replay_recording` — `"active"` while a recording is in flight
  (only used by `:on_demand` widgets to know whether to auto-resume on
  the next page)

When the page is about to unload, a `pagehide`/`beforeunload` handler
flushes any buffered events using `fetch(..., { keepalive: true })`.
This keeps the existing `x-phoenix-replay-session` header — no CSRF
carve-out needed. Capped at three batches per unload (~3 ×
`maxEventsPerBatch`) to stay inside browser keepalive limits.

When the next page mounts and `ensureSession()` runs, the client sends
the cached token back as `x-phoenix-replay-session`. The server
decides whether the session is still resumable.

### Layer 2 — server (Phase 2)

Every active session is owned by a `PhoenixReplay.Session` GenServer:

- Started on `POST /session` (fresh-mint or resume); also lazily
  started by `POST /events` when the process has been GC'd but the DB
  still has rows for the session.
- Holds `seq_watermark`, the last 50 accepted seqs (in-flight dedup),
  the identity, and an idle timer.
- On every accepted batch: persists via the storage adapter,
  broadcasts `{:event_batch, session_id, events, seq}`, resets the
  idle timer.
- On `Session.close/2` (called by `POST /submit` with reason
  `:submitted`): broadcasts `{:session_closed, session_id, reason}`,
  exits normally.
- On idle timeout: broadcasts
  `{:session_abandoned, session_id, last_event_at}`, exits.

`SessionController.create/2` resolves resume in this order:

1. **Registry hit** — alive `Session` process for the requested
   `session_id` → ask it for its watermark, return `resumed: true`.
2. **DB fallback** — `Storage.resume_session/2`. Covers the
   crash-restart case (the GenServer died but the events table still
   has rows). Spawns a fresh `Session` seeded with the persisted
   watermark.
3. **Fresh** — mint a new `session_id` + spawn a fresh `Session`.

A stale or invalid token collapses to (3). What "stale" looks like to
the user depends on `recording=` (ADR-0003 OQ1):

- `recording={:continuous}` → silent fresh-start. The user sees
  nothing; recording continues with a new `session_id`.
- `recording={:on_demand}` → the panel surfaces the existing
  ADR-0002 Phase 2 error screen with a "Retry" CTA.

## Privacy

`sessionStorage` is per-tab and per-origin. The token + recording flag
both vanish when the tab closes — no recording state ever lands in
`localStorage`, IndexedDB, or cookies. A `Session` GenServer holds the
identity in memory only; on idle/abandon/submit it exits and the
identity goes with it.

## Configuring the idle window

The server-side stale-cutoff is the same value the GenServer uses for
its idle timer — `:session_idle_timeout_ms` (default `900_000`,
15 min). Hosts running long manual reproduction workflows can widen
it:

```elixir
config :phoenix_replay,
  session_idle_timeout_ms: 1_800_000  # 30 min
```

Widening the window has a cost: more idle GenServers sit in the
process table, and the DB-fallback resume path will accept older
sessions. For most workflows, 15 minutes is plenty — most active
reproductions span seconds to a few minutes.

## Subscribing from a live admin view

Each session broadcasts on `"\#{prefix}:session:\#{session_id}"` —
default prefix `"phoenix_replay"`, override with
`:pubsub_topic_prefix`. Point the library at your host's existing
`Phoenix.PubSub` instance with `config :phoenix_replay, :pubsub,
MyApp.PubSub` and your admin LV can stream frames as they land:

```elixir
def mount(%{"id" => session_id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "phoenix_replay:session:\#{session_id}")
  end
  {:ok, socket}
end

def handle_info({:event_batch, _session_id, events, _seq}, socket) do
  # Push to rrweb-player via push_event/3
  {:noreply, push_event(socket, "phoenix_replay:append", %{events: events})}
end

def handle_info({:session_closed, _, _reason}, socket) do
  {:noreply, push_event(socket, "phoenix_replay:closed", %{})}
end

def handle_info({:session_abandoned, _, _last_event_at}, socket) do
  {:noreply, push_event(socket, "phoenix_replay:abandoned", %{})}
end
```

A separate plan (in `docs/plans/`) covers shipping the admin "watch
live" LiveView itself.

## Failure modes

| Symptom | Cause | What to check |
|---|---|---|
| Resume always returns `resumed: false` | Token TTL expired (mint → resume gap > 30 min) or storage backend reports `:not_found` | DevTools: confirm `x-phoenix-replay-session` header is sent. Server logs: look for the `/session` POST decision. |
| Tail events on the last page never appear | Browser blocked `fetch keepalive` (rare) or batch exceeded keepalive size cap (~64KB) | DevTools Network panel with "Preserve log" — look for `/events` POSTs at `pagehide`. |
| Live admin LV gets no `:event_batch` messages | `:pubsub` config points at the wrong PubSub, or topic prefix mismatch | `iex> PhoenixReplay.Config.pubsub()` — confirm it matches your host's PubSub. Subscribe to the topic from `iex` and trigger a `POST /events`. |
| `Session` GenServer count grows unbounded | Idle timeout too long, or a consumer holds sessions open without ever calling submit | `Registry.count(PhoenixReplay.SessionRegistry)`. Tighten `:session_idle_timeout_ms` if needed. |

## Out of scope

- Cross-tab session sharing (each tab is its own recording — ADR-0003
  OQ4).
- Multi-node session registry (no `:global` / `Horde` integration).
  Sessions are pinned to the node that minted them — load balancers
  must use sticky sessions or the resume path will hit the DB
  fallback every page (still works, just costs an extra query).
- Auth-bound cross-device resume (a user logging in on a phone after
  starting on a laptop).
