# Design: LiveView Snapshot Stream — Server-Origin Capture via `attach_hook` + `CaptureStream` API

**Date**: 2026-04-28
**Status**: Active — design approved 2026-04-28; ADR-0007 to follow as
companion decision record before Phase 1 plan.
**Owners**: phoenix_replay (primary). ash_feedback is a future external
consumer of the same `CaptureStream` API but does not require code
changes for v1.
**Driving conversation**: User session 2026-04-28 with
`/Users/johndev/Dev/ash_feedback_demo` checkout. Triggered by question
"can LiveDebugger-style information be embedded into a phoenix_replay
report so an admin replaying a session can also inspect LiveView state
at any point on the timeline?" Two preceding research passes ruled out
shipping LiveDebugger to staging/prod (`:dbg`-based, process-wide global
tracer; no PII layer; authors explicitly state dev-only) and identified
a phoenix_replay-native path using Phoenix-blessed primitives.

## Context

phoenix_replay records browser sessions (rrweb DOM + console + network
plugins) and surfaces them in an admin replay UI for triage. When a
report comes in, an admin can scrub the timeline and see what the user
saw. What they cannot see today is **what the LiveView process was
holding at any given timestamp** — the assigns, the in-flight async
calls, the PubSub message that just fired. That gap is the difference
between "I see the broken UI" and "I see why it broke."

LiveDebugger (`/Users/johndev/Dev/live-debugger/`) provides exactly this
information in dev. It is fundamentally not portable to staging/prod:
it is a parallel Phoenix application that installs an `:erlang.dbg`
node-wide tracer on every LiveView callback, persists full sockets to
ETS without any PII redaction layer, and explicitly warns against
production use. Forking the capture half is effectively rebuilding it.

Phoenix.LiveView itself emits two primitives that, together, give us
everything we need without `:dbg`:

1. `Phoenix.LiveView.attach_hook/4` — Phoenix-blessed instrumentation
   API that runs in-process at well-defined stages
   (`:handle_event`, `:handle_info`, `:handle_async`, `:handle_params`,
   `:after_render`).
2. `Phoenix.LiveView.Debug.socket/1` + `live_components/1` — public
   functions that return a socket's assigns without going through the
   tracer.

Combining them with phoenix_replay's existing per-session
infrastructure (the `PhoenixReplay.Session` GenServer from ADR-0003,
the timeline event bus from ADR-0005, the panel addon API from the
unified entry work in ADR-0006) yields a complete
capture-and-replay pipeline that is prod-safe by construction.

This spec is the implementation plan for that pipeline.

## Architectural decisions

### D1 — Capture scope: assigns + callback markers, no LiveComponent state

The capture stream records:

- **Assigns snapshots** of the root LiveView at well-defined moments
  (mount baseline, after each user-action callback completes,
  throttled at 50ms).
- **Event markers** for `handle_event`, `handle_info`, `handle_async`,
  `handle_params`, and `mount` callbacks. Markers carry the callback
  kind, the event name (for `handle_event`), and a redacted view of
  the params or info message.

It explicitly does **not** record:

- Full LiveComponent assigns. LiveComponent `handle_event` callbacks
  produce event markers (with `target_cid` and `target_module` in the
  payload), but the LiveComponent's own state is not snapshotted.
  LiveComponents bring proportionally larger data (one root LV may
  contain dozens of LCs) and the parent LV's assigns are usually the
  bug-relevant view.
- Render telemetry as its own snapshot trigger. Render fires more
  often than user-action boundaries (e.g., on parent re-render with no
  state change of debugging interest). Snapshots happen on the
  callback that *caused* the render, not the render itself.

### D2 — Activation model: always-on data path with per-session filter

The `on_mount` hook installed via `live_session` registers callback
hooks unconditionally. Each callback hook's first action is an ETS
lookup against a session-id-to-transport-pid registry. If the LV's
transport_pid is not associated with a phoenix_replay recording
session, the hook returns immediately. Cost in the not-recording
common case: ~1µs per callback (one ETS read).

This is the prod-safety design. Process-wide global tracing
(LiveDebugger's `:dbg` model) cannot be made selective — once attached,
every LV callback in the node pays. `attach_hook` is per-process
*and* per-stage, so the cost is bounded to the LVs whose hooks we
actually installed, and the ETS-lookup gate keeps even those LVs cheap
when no recording is active.

### D3 — Redaction policy: shape-only by default, per-LV allowlist for values

By default, captured assigns are reduced to **shape only** before
storage. A shape representation contains key names, type tags, and
size hints (e.g., `{:list, length: 142}`, `{:map, keys: [:id, :email]}`,
`{:struct, MyApp.User, fields: [:id, :role]}`). It contains no literal
values — not even atoms, since atom values can themselves carry
semantic information about user state.

Hosts that want literal values for specific assigns opt in per-LV via
a module attribute:

```elixir
use PhoenixReplay.LiveView,
  snapshot: [values: [:active_tab, :selected_id, :form_errors]]
```

Allowlisted values are still passed through `inspect/2` with explicit
limits (`limit: 50`, `printable_limit: 200`, `structs: false`) and
truncated at a hard ceiling (default 4 KB per event payload).

The composition is: **PII-safe by construction unless the host
explicitly opts in**, and even then bounded by inspect limits.

A "dev mode that captures everything" escape hatch is explicitly
rejected. Reasoning: divergent code paths between dev and prod
create the most common class of "leaked something we didn't expect"
incidents, and shape-only is rich enough to diagnose 80%+ of bugs
("user was nil", "list was empty", "form had 3 field errors") without
touching values.

### D4 — Snapshot trigger: callback `:stop` boundaries with throttle

Snapshots are triggered after the LV callback completes and a render
has occurred (via a transient `:after_render` hook attached inside the
callback hook). Triggers:

- `mount` — baseline snapshot once, after the initial render.
- `handle_params` — every `:stop`.
- `handle_event` — every `:stop`, throttled to 50ms per
  `{lv_pid, event_name}` pair. Rationale: rapid-fire UI events
  (drag, scroll, repeated keypress) fire `handle_event` faster than
  human-perceptible debugging granularity; collapsing to the latest
  is sufficient and bounds buffer growth.
- `handle_async` — every `:stop` (no throttle; async completion
  cadence is naturally bounded).
- `handle_info` — every `:stop` (no throttle; external messages are
  important to capture in full).

`render` itself is not a trigger. Capturing on render produces
duplicate or redundant entries when a parent LV re-renders for
unrelated reasons.

### D5 — Storage: existing `events` table, rrweb type-6 plugin format

Server-origin events flow into the same `phoenix_replay_events` table
as rrweb events, using rrweb's type-6 (Plugin) event format:

```elixir
%{
  "type" => 6,
  "timestamp" => browser_timeline_ms,
  "data" => %{
    "plugin" => "phx-replay/liveview@1",
    "payload" => %{kind: ..., lv_module: ..., ...}
  }
}
```

Zero schema migration. The `Storage` behaviour, S3 adapter, and Ecto
adapter all see the merged batch as a single sequence of opaque
events. The replay player iterates a single timestamp-sorted timeline,
dispatching type-6 events to plugin-specific renderers (the same path
that already handles `rrweb/console@1` and `rrweb/network@1`).

### D6 — New public API: `PhoenixReplay.CaptureStream`

A new public module models server-origin capture streams as a
first-class concept. The LV snapshot module is the first internal
consumer. External libraries (e.g., a future ash_feedback Oban-state
addon) use the same API.

Function surface:

```elixir
PhoenixReplay.CaptureStream.record_clock_offset(session_id, browser_started_at_ms)
PhoenixReplay.CaptureStream.attach(session_id, stream_id, opts \\ [])
PhoenixReplay.CaptureStream.push_event(session_id, stream_id, %{
  server_time_ms: integer(),
  payload: map()
})
PhoenixReplay.CaptureStream.flush_for_session(session_id) :: [event_map]
```

Stream IDs are namespaced strings (e.g., `"phx-replay/liveview@1"`,
`"ash-feedback/oban@1"`). Each stream's events are stored in a
session-scoped scratch buffer, drained at report-submission time.

Critical invariant: server-time → browser-time conversion happens
exactly once, inside `flush_for_session/1`. `push_event/3` stores raw
server timestamps. This avoids races between offset recording and
event emission.

### D7 — Time alignment: single-shot session-start clock offset

When the client widget bootstraps, it sends its current `Date.now()`
in the same request that creates the recording session
(`POST /events` for Path B, or the first `/report` request for Path
A). The server records its own `System.system_time(:millisecond)` on
arrival and computes:

```
clock_offset = server_received_at_ms - client_started_at_ms
```

This offset is stored in `PhoenixReplay.Session` state. It bundles
clock skew and one-way network latency together; the bundling is
intentional — it positions server actions slightly later than the
browser action that triggered them, which is the natural visualization.

At flush time, every server-origin event's `server_time_ms` is
converted to browser timeline:

```
browser_timeline_ms = server_time_ms - clock_offset
```

Drift correction is **not** included in v1. A 30-minute session may
accumulate sub-second drift, well below human debugging granularity.
A periodic re-sync mechanism is a v2 consideration.

If `record_clock_offset/2` is never called for a session (e.g., due
to a bug in the bootstrap path), `flush_for_session/1` falls back to
treating server time as browser time and logs a warning. Player
output remains a coherent sorted timeline; absolute timestamps
relative to rrweb may be off by network latency.

## Capture mechanism — `attach_hook` lifecycle

### Installation via `on_mount`

Hosts add one line to their `live_session` block in the router:

```elixir
live_session :default,
  on_mount: [{PhoenixReplay.LiveView.Snapshots, :install}] do
  live "/posts", PostsLive
end
```

The `:install` `on_mount` callback:

```elixir
def on_mount(:install, _params, _session, socket) do
  socket =
    case PhoenixReplay.LiveView.Registry.lookup_session(socket) do
      {:ok, session_id} ->
        socket
        |> assign(:__phx_replay_session_id__, session_id)
        |> attach_hook(:phx_replay_hev, :handle_event, &capture_handle_event/3)
        |> attach_hook(:phx_replay_hin, :handle_info, &capture_handle_info/2)
        |> attach_hook(:phx_replay_has, :handle_async, &capture_handle_async/3)
        |> attach_hook(:phx_replay_hpa, :handle_params, &capture_handle_params/3)
        |> capture_mount_baseline()

      :error ->
        socket
    end

  {:cont, socket}
end
```

When no recording session is associated with this LV's transport, no
hooks are attached and the LV pays zero ongoing cost.

### Session ↔ transport_pid registry

A new `PhoenixReplay.LiveView.Registry` (Elixir `Registry` instance,
keys: `:unique`, name: `__MODULE__`) maps `transport_pid → session_id`.
Population happens at LV mount time: the LV reads `session_id` from
`Phoenix.LiveView.get_connect_params(socket)` (set by the client
widget's LiveSocket params) and registers itself. The registry entry
is auto-cleaned on transport exit.

### Capture pattern

Each callback hook follows the same shape:

```elixir
defp capture_handle_event(event_name, params, socket) do
  try do
    event_id = make_ref()
    push_event_marker(socket, %{
      kind: :event_marker,
      callback: :handle_event,
      event_name: event_name,
      params: scrub(params),
      event_id: event_id
    })

    socket =
      attach_hook(socket, :phx_replay_after_render, :after_render, fn s ->
        push_snapshot(s, %{paired_event_id: event_id})
        detach_hook(s, :phx_replay_after_render, :after_render)
      end)

    {:cont, socket}
  rescue
    _ -> {:cont, socket}
  end
end
```

Two events emit per callback: an event marker at callback entry, and a
snapshot after the next render completes. They are linked by a shared
`event_id` (an Erlang reference) so the replay UI can show "this
snapshot resulted from this event."

The transient `:after_render` hook detaches itself after firing once.
This avoids accumulating after-render hooks across many callbacks.

The `try/rescue` wrapper is non-negotiable: a capture callback raise
must not propagate to the host LV. If shape extraction encounters a
pathological value, the LV continues uninterrupted; the snapshot is
silently lost.

### LiveComponent handling

When a `handle_event` originates from a LiveComponent, Phoenix routes
it through the root LV's `:handle_event` stage with a `_target` and
component-id metadata. Our hook detects this and includes
`target_cid` and `target_module` in the marker payload. The
LiveComponent's own assigns are not captured (D1).

### Throttling

`handle_event` markers are throttled to 50ms per
`{lv_pid, event_name}` pair using a small per-LV state field. Two
clicks of "save" within 50ms produce one marker (the second). This
matches Phoenix.LiveView's default input debounce.

`handle_info`, `handle_async`, and `handle_params` are not throttled.
Their natural cadence is already bounded by external systems.

## `PhoenixReplay.CaptureStream` API surface

### Module shape

```elixir
defmodule PhoenixReplay.CaptureStream do
  @moduledoc """
  Server-origin capture stream registry.

  Allows libraries (including phoenix_replay's own LiveView snapshot
  capture, and external consumers like ash_feedback) to push
  server-side events into a phoenix_replay session's recording stream
  with automatic clock-offset alignment to the browser timeline.
  """

  @type session_id :: String.t()
  @type stream_id :: String.t()
  @type event :: %{
    required(:server_time_ms) => integer(),
    required(:payload) => map()
  }

  @spec record_clock_offset(session_id, integer()) :: :ok
  @spec attach(session_id, stream_id, keyword()) :: :ok
  @spec push_event(session_id, stream_id, event) :: :ok
  @spec flush_for_session(session_id) :: [map()]
end
```

### Storage internals

Each session's scratch buffers live in the existing
`PhoenixReplay.Session` GenServer state, extended with:

```elixir
%PhoenixReplay.Session.State{
  # ... existing fields from ADR-0003 ...
  capture_streams: %{stream_id => :queue.t()},
  capture_opts:    %{stream_id => keyword()},
  clock_offset:    integer() | nil
}
```

A separate ETS table `:phoenix_replay_capture_streams` keyed by
`{session_id, stream_id}` maps to the Session GenServer pid. This
gives `push_event/3` an O(1) lookup hot path:

```elixir
def push_event(session_id, stream_id, event) do
  case :ets.lookup(:phoenix_replay_capture_streams, {session_id, stream_id}) do
    [{_, pid}] -> GenServer.cast(pid, {:capture_push, stream_id, event})
    [] -> :ok
  end
end
```

When a session is unknown (no widget on this page) or the stream is
not attached, the call is a single ETS read and returns. This is the
hot-path budget: `< 5µs` per push when not recording.

### Backpressure and bounds

Each attached stream's queue is bounded by `:max_events` (default
5000). On overflow, oldest events are evicted (ring queue semantics)
and a `[:phoenix_replay, :capture_stream, :overflow]` telemetry event
is emitted. This matches Path A's client-side ring buffer behavior:
old events fall out as new events arrive, the user always sees the
most recent context.

A second cap, `:ttl_ms` (default 600 000 ms = 10 minutes), evicts
events older than the TTL on every push. This protects against an
unattended tab accumulating stale state in scratch.

A third cap, `:max_bytes` (default 4096 per event), is applied at the
LV snapshot module's shape-extraction layer, not at CaptureStream.
CaptureStream itself is payload-agnostic.

### Flush semantics

`flush_for_session/1` drains all attached streams' queues, applies the
clock offset to each event's `server_time_ms`, wraps each in the rrweb
type-6 envelope, and returns the unsorted list. The caller (typically
the ingest pipeline in `ReportController`, `EventsController`, or
`SubmitController`) is responsible for merging this with the rrweb
batch from the client and timestamp-sorting the result before
persistence.

After flush, the queues are empty but the streams remain attached
(the session can continue recording).

## Redaction & shape extraction

### Default extractor

A `PhoenixReplay.LiveView.Shape` module implements:

```elixir
@spec extract(any()) :: shape :: term()
```

Mapping table:

| Input | Output |
|---|---|
| `nil` | `:nil` |
| `true` / `false` | `:boolean` |
| integer | `:integer` |
| float | `:float` |
| binary | `{:string, length: byte_size}` |
| atom | `:atom` (value not included) |
| pid | `:pid` |
| reference | `:reference` |
| function | `:function` |
| list | `{:list, length: length}` |
| tuple | `{:tuple, size: tuple_size}` |
| map | `{:map, keys: keys}` (keys only, no values) |
| `%Date{}` / `%DateTime{}` / `%NaiveDateTime{}` | `:date` / `:datetime` / `:naive_datetime` |
| `%Ecto.Changeset{}` | `{:changeset, valid?: bool, fields: list, error_count: int}` |
| `%Phoenix.HTML.Form{}` | `{:form, name: name, fields: list, error_count: int}` |
| `%MapSet{}` | `{:mapset, size: size}` |
| `%MyStruct{}` (other) | `{:struct, MyStruct, fields: keys}` |
| anything else | `{:opaque, inspect_class}` |

Property test invariant: for any input `x`,
`extract(x) |> :erlang.term_to_binary()` does not contain
`:erlang.term_to_binary(x)` as a sub-binary. (Stronger version:
recursively, no leaf value of `x` appears in `extract(x)`'s
serialized form.)

### Custom extractors

Hosts can register custom extractors for their own structs via app
config:

```elixir
config :phoenix_replay, :snapshot_shape_extractors, [
  {MyApp.Cart, fn cart ->
    {:struct, MyApp.Cart, item_count: length(cart.items),
                          total_cents: cart.total_cents}
  end}
]
```

The extractor receives the struct and returns a shape term. It is the
host's responsibility to keep the shape PII-safe.

### Allowlist resolution

The macro accepts:

```elixir
use PhoenixReplay.LiveView,
  snapshot: [
    values: [list_of_assigns_keys],   # opt-in to capture literal values
    params: [list_of_event_param_keys] # opt-in for handle_event params
  ]
```

It injects a generated function on the LV module:

```elixir
def __phoenix_replay_snapshot_config__, do: %{values: [...], params: [...]}
```

The capture pipeline reads this at snapshot time and includes
`assigns_values` (for allowlisted assigns keys) and value-bearing
`params` (for allowlisted event-param keys) in the payload. Each
allowlisted value is passed through:

```elixir
inspect(value, limit: 50, printable_limit: 200, structs: false, pretty: false)
|> truncate(@max_value_bytes)
```

If the LV does not `use PhoenixReplay.LiveView`, the
`__phoenix_replay_snapshot_config__/0` function does not exist, and
the capture pipeline emits `assigns_values: %{}`.

### `handle_event` params scrubbing

`params` go through the same shape extractor by default — the marker
payload contains a shape representation of the params map (key names,
shapes per key) but no literal values. If the LV's snapshot config
includes `params: [...]`, those keys' values are included literally
(still subject to inspect limits). Form fields are deliberately not
allowlisted by default — passwords and tokens are common form params.

## Replay UI — admin sidebar `LiveView` tab

> **Status (2026-04-28):** Phase 2 (admin replay viewer UI) deferred —
> see [ADR-0008](../../decisions/0008-defer-admin-replay-viewer-ui.md).
> This section remains as the design-of-record for if/when work
> resumes.

### Slot

A new panel addon slot `admin-sidebar-tab` is added to the existing
admin replay layout. phoenix_replay registers the LV state addon
into this slot:

```javascript
PhoenixReplay.registerPanelAddon({
  id: "phx-replay-liveview-state",
  slot: "admin-sidebar-tab",
  paths: ["admin"],
  mount: (ctx) => mountLiveViewPanel(ctx)
});
```

The slot is a new panel API addition, not a reuse of the capture-time
slots (`pill-action`, `review-media`, `form-top`).

### Panel structure

The panel renders two sections:

1. **Current snapshot** — the most recent snapshot with
   `timestamp ≤ player_cursor`. Header shows
   `lv_module · instance · t = X.Xs`. Body shows `assigns_shape` as
   a key-value tree with optional `assigns_values` annotations for
   allowlisted keys.
2. **Event timeline** — list of all event markers in the session,
   chronologically. Each entry shows timestamp, callback kind,
   event name (or info kind), and the source LV module. Clicking an
   entry seeks the rrweb player to that timestamp.

Navigation (one LV terminating, another mounting in the same session)
is rendered as a divider in the timeline. The current-snapshot header
updates as the cursor crosses navigations.

### Timeline bus consumption

The panel is a `subscribeTimeline` consumer:

```javascript
PhoenixReplay.subscribeTimeline(ctx.sessionId, (detail) => {
  const { kind, timecode_ms } = detail;
  const snapshot = findLatestSnapshotBefore(allEvents, timecode_ms);
  renderCurrentSnapshot(snapshot);
  highlightTimelineItem(findEventNearestCursor(allEvents, timecode_ms));
}, { tick_hz: 10, deliver_initial: true });
```

This is the same consumer pattern the audio playback addon uses
(`audio_playback.js:44-48`). Same API, no special-case wiring.

### Data loading

The panel does not fetch additional data. The admin player already
loads all events for the session as a JSON payload; the panel filters
that payload for type-6 events with `data.plugin === "phx-replay/liveview@1"`
and parses the payloads at mount time.

### Explicit non-features in v1

- Diff view between two snapshots. Shape comparison is mostly
  uninteresting (shapes rarely change); allowlisted-value diff is
  useful but small enough to defer.
- Event marker dots overlaid on the rrweb player's own timeline. The
  rrweb player UI is not currently extended from outside; doing so
  would require a separate change to the player hook.
- Event search/filter. Sessions are short; scrolling the list is
  sufficient at the volumes we expect (< 100 events typical).
- JSON export from the panel UI. The data is in the page; users can
  use the browser console.
- LiveComponent assigns visualization (D1 — out of scope).

## Prod safety story

Mapping the original LiveDebugger blockers identified in research to
the current design:

| Blocker (LiveDebugger) | This design |
|---|---|
| `:dbg`-based, node-wide global tracer | `attach_hook`, per-process, only attached when a recording session is associated |
| Single GenServer fan-in for all traces | Scratch buffers are per-session, isolated in each `PhoenixReplay.Session` GenServer |
| Full-socket persistence with no PII layer | Shape-only by default; allowlist required to capture values; inspect limits cap allowlisted values |
| Memory growth (50 MB/LV ETS cap, 5 GB tracer) | `:max_events` (5000) ring queue per stream, `:ttl_ms` (10 min) eviction, idle session teardown auto-clears |
| Capture failure can take down LV | All capture paths wrapped in `try/rescue` with non-propagating `:cont` |

### Performance budget

| Path | Budget | Verification |
|---|---|---|
| `attach_hook` callback when not recording | < 5µs | Benchee: 1M iterations of capture_handle_event with empty registry |
| `push_event/3` when recording | < 50µs | Benchee: 1M iterations under realistic shape extraction |
| Shape extraction (10-key map of mixed types) | < 30µs | Microbench |
| `flush_for_session/1` (5000 events) | < 50ms | Per-flush, called at most once per submit |

Phase 1 includes a Benchee suite. Failure to meet budget triggers
design re-review before merge.

### Failure semantics

| Failure | Behavior | LV impact |
|---|---|---|
| `PhoenixReplay.Session` GenServer crashes | ETS entries cleaned by `Registry`/`:ets.delete_all_objects` on exit; subsequent `push_event/3` returns `:ok` | None — LV continues |
| Capture callback `try/rescue` triggered | Exception swallowed, snapshot lost, log warning | None — LV continues |
| Scratch buffer overflow | Oldest evicted, telemetry emitted | None |
| Clock offset never recorded | Fallback at flush: server time used as-is, log warning | None — replay timestamps may be off by network latency |
| `inspect/2` recursion or pathological value | inspect's `limit` arrests it; shape becomes `{:opaque, ...}` | None |

## Rollout

### v1 — opt-in via one-line `on_mount`

Hosts add `{PhoenixReplay.LiveView.Snapshots, :install}` to their
`live_session`'s `on_mount` list. No code generator changes for v1.

Existing hosts without the line continue to function exactly as
today; phoenix_replay does not auto-install LV capture.

### v2 — Igniter integration (deferred)

`mix igniter.install phoenix_replay --with-liveview-snapshots` should
auto-patch the router. This is a follow-up to the 5f Igniter installer
work; not in scope for this spec.

### Configuration knobs

Host `config :phoenix_replay`:

```elixir
config :phoenix_replay,
  capture_stream: [
    max_events: 5_000,
    ttl_ms: 600_000,
    max_value_bytes: 4_096
  ],
  snapshot_shape_extractors: []
```

All knobs are optional; defaults apply.

## Observability

phoenix_replay emits the following telemetry events:

| Event | Measurements | Metadata |
|---|---|---|
| `[:phoenix_replay, :capture_stream, :push]` | `%{}` | `%{session_id, stream_id, buffer_size, offset_known?}` |
| `[:phoenix_replay, :capture_stream, :flush]` | `%{count, duration_ms}` | `%{session_id}` |
| `[:phoenix_replay, :capture_stream, :overflow]` | `%{dropped_count}` | `%{session_id, stream_id}` |
| `[:phoenix_replay, :capture_stream, :rescue]` | `%{}` | `%{session_id, stream_id, kind}` |

Hosts attach these to their existing observability stack
(Prometheus, StatsD, Loki, etc.) without phoenix_replay knowing about
the host's tooling.

## Testing strategy

| Layer | Tests |
|---|---|
| Unit — `CaptureStream` | attach/push/flush correctness; offset application; ring overflow; missing-offset fallback; concurrent push/flush race |
| Unit — `Shape.extract/1` | exhaustive type matrix; PII-safety property test (no leaf value of input appears in output's term-binary form) |
| Unit — `Snapshots` capture callbacks | each callback kind emits expected marker; rescue path returns `{:cont, socket}` cleanly |
| Integration — `attach_hook` lifecycle | hooks attach when recording session present, do not attach otherwise; detach on transport exit |
| Integration — end-to-end | LV emits handle_event → push_event → flush → events table → admin player loads → panel renders correct snapshot at cursor |
| Property — PII invariant | random assigns generator + extract → assert no input value appears in output |
| Bench — hot paths | meet performance budget table |

## v1 explicitly deferred

- Drift correction beyond single-shot offset.
- Diff view between snapshots.
- rrweb timeline overlay markers (player UI extension).
- LiveComponent assigns capture.
- Igniter auto-install.
- Render-as-trigger snapshots.
- Multi-LV "by module" grouping in the panel (timeline is single-list).
- Dev-mode "panopticon" all-values capture (rejected on safety
  grounds, not just deferred).

## Open questions

1. **Mount ordering.** `on_mount` in `:install` must run after
   any host `on_mount` that sets connect params we depend on (e.g.,
   the session_id from the client widget). Current plan: document
   that `{PhoenixReplay.LiveView.Snapshots, :install}` should be
   appended last to the `on_mount` list. Phase 1 should verify this
   doesn't break Path B (on-demand recording starts mid-session).

2. **Live navigation across `live_session` boundaries.** When a user
   navigates between two `live_session` blocks, Phoenix terminates
   the LiveSocket and restarts. Whether the second `live_session` has
   `:install` in its `on_mount` is the host's responsibility.
   Document this in the rollout guide; do not try to make it
   automatic.

3. **Allowlist composition with libraries that themselves ship LVs.**
   If a host pulls in a library like ash_authentication that
   provides its own LVs, the host cannot easily add the snapshot
   `use` macro to those LVs. v1 accepts this — those LVs get
   shape-only capture, which is still useful. A future macro option
   like `config :phoenix_replay, snapshot_overrides: [{MyDep.Live, [...]}]`
   could close the gap; out of v1 scope.

4. **Path A baseline timing.** Path A's ring buffer means snapshots
   can be present in scratch when the user has not yet decided to
   report. The CaptureStream `:ttl_ms` (10 min) bounds this. Open
   question: should the `mount` baseline snapshot be taken even if
   the recording session is not yet established (i.e., before the
   widget bootstrap completes)? Current plan: only after session
   registration, which may delay baseline by tens of milliseconds —
   acceptable.

5. **Coordination with Path B `:start_recording` event.** Path B
   creates the recording session on user action, not on page load.
   The session-id-to-transport-pid registry needs to update
   retroactively when Path B starts. Phase 1 must verify the registry
   notification path covers this.

## Companion artifacts

- ADR-0007 (to be drafted) — high-level decision record. Will
  reference this spec.
- Phase 1 plan (to be drafted via writing-plans) — implementation
  task list with concrete file paths and order of operations.
