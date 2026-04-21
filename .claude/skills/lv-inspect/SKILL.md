---
name: lv-inspect
description: Inspect LiveView state (assigns, components) via Phoenix.LiveView.Debug in project_eval
argument-hint: "[pid_tuple | 'list' | 'assigns' | 'assign:key' | 'components' | 'summary']"
---

# LiveView State Inspector

Inspect runtime state of LiveView processes using `Phoenix.LiveView.Debug` (Phoenix core) via `project_eval`.
No LiveDebugger dependency needed — these are built into Phoenix LiveView.

## Getting the PID

The current page's LiveView PID is in the `<framework-details>` context block.
Example: `Main LiveView #phx-GKR3k4n7RrVOhbBh with PID #PID<0.1378068.0>`

Extract the three numbers → `pid(0, 1378068, 0)` in project_eval.

**PID changes on page reload/reconnect** — always use the PID from current context.

## Commands

### `/lv-inspect list` — All active LiveViews

```elixir
Phoenix.LiveView.Debug.list_liveviews()
|> Enum.map(fn lv -> %{pid: lv.pid, view: lv.view, topic: lv.topic} end)
```

### `/lv-inspect assigns` — Assign key list

```elixir
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid(0, PID2, 0))
keys = socket.assigns |> Map.keys() |> Enum.sort()
{length(keys), keys}
```

### `/lv-inspect assign:KEY` — Specific assign value

```elixir
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid(0, PID2, 0))
Map.get(socket.assigns, :KEY)
```

### `/lv-inspect assign:KEY1,KEY2` — Multiple assigns

```elixir
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid(0, PID2, 0))
Map.take(socket.assigns, [:KEY1, :KEY2])
```

### `/lv-inspect components` — LiveComponents in page

```elixir
{:ok, components} = Phoenix.LiveView.Debug.live_components(pid(0, PID2, 0))
Enum.map(components, fn c -> %{cid: c.cid, module: c.module, id: c.id} end)
```

### `/lv-inspect summary` — Assigns overview (types + sizes, avoids context pollution)

```elixir
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid(0, PID2, 0))

socket.assigns
|> Map.drop([:__changed__, :flash])
|> Enum.map(fn {k, v} ->
  summary = cond do
    is_list(v) -> {:list, length(v)}
    is_map(v) and Map.has_key?(v, :__struct__) -> {:struct, v.__struct__}
    is_map(v) -> {:map, map_size(v)}
    is_binary(v) and byte_size(v) > 100 -> {:string, byte_size(v)}
    is_pid(v) -> {:pid, inspect(v)}
    true -> v
  end
  {k, summary}
end)
|> Enum.sort_by(&elem(&1, 0))
```

## Execution Workflow

1. **Read PID** from `<framework-details>` context
2. **Substitute** `pid(0, PID2, 0)` with actual values
3. **Run** via `project_eval`
4. **Filter large values** — if an assign is too large for context:
   - Lists: `{:list, length(list)}`
   - Maps >10 keys: `{:map, Map.keys(map)}`
   - Structs: `{:struct, mod, Map.keys(Map.from_struct(s))}`

## API Reference

All functions are from `Phoenix.LiveView.Debug` (Phoenix core, always available):

| Function | Returns |
|----------|---------|
| `list_liveviews()` | `[%{pid, view, topic, transport_pid}]` |
| `socket(pid)` | `{:ok, %Phoenix.LiveView.Socket{}}` or `{:error, term}` |
| `live_components(pid)` | `{:ok, [%{id, cid, module, assigns, private, children_cids}]}` |
| `liveview_process?(pid)` | `boolean` |

For lower-level OTP inspection (rarely needed):

```elixir
:sys.get_state(pid)              # Raw GenServer state
:erlang.process_info(pid)        # Memory, message queue, stack
Process.info(pid, :messages)     # Pending messages
```

## Notes

- `socket/1` reads state directly from the LiveView process (real-time, most reliable)
- PID lifecycle: LiveView PIDs change on page reload/reconnect — always use current context PID
- project_eval spawns an ephemeral process — PubSub subscriptions won't persist, but direct process queries work fine
- For before/after comparison: read assigns, trigger action via browser_eval, read assigns again
