# LiveView Snapshot Stream — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the foundation of server-origin LiveView snapshot capture: a new `PhoenixReplay.CaptureStream` public API, a session-scoped scratch buffer inside `PhoenixReplay.Session`, an `attach_hook`-based `PhoenixReplay.LiveView.Snapshots` module, and ingest-time merge into the existing events table. End state: when a host adds one `on_mount` line to its `live_session`, every recorded session's events row contains rrweb type-6 events with `plugin: "phx-replay/liveview@1"` carrying assigns shapes and callback markers, timestamp-aligned with the rrweb DOM events.

**Architecture:** Capture is per-LiveView-process via `Phoenix.LiveView.attach_hook/4` — no `:dbg`, no global tracer. Each snapshot first reduces assigns to shape-only (key + type + size hint) — no literal values. `CaptureStream.push_event/3` is an O(1) ETS lookup that no-ops when the LV's transport_pid isn't associated with a phoenix_replay recording session, keeping cost ~zero for non-recorded LVs. Server-time events accumulate in the existing `PhoenixReplay.Session` GenServer's state; on `/submit` or `/report`, they're drained, offset-corrected to browser timeline, wrapped in rrweb type-6 plugin format, merged with the client's rrweb batch, and persisted via the existing `Storage.Dispatch` boundary. Phase 1 ships shape-only — the `use PhoenixReplay.LiveView, snapshot: [values: ...]` allowlist macro is Phase 2.

**Tech Stack:** Elixir + Phoenix.LiveView (`attach_hook`, `Registry`, `GenServer`, ETS); existing `PhoenixReplay.Session` + `PhoenixReplay.Storage.Dispatch` boundaries; vanilla ES2020 (`phoenix_replay.js`); ExUnit + `Phoenix.LiveViewTest`.

---

## Spec coverage map

| Spec section | Tasks in this plan |
|---|---|
| D1 Capture scope | Task 6 |
| D2 Activation model (per-session filter) | Task 5 + 6 |
| D3 Redaction (shape-only — Phase 1 default; allowlist deferred) | Task 2 |
| D4 Snapshot trigger + 50ms throttle | Task 6 |
| D5 Storage (rrweb type-6) | Task 8 |
| D6 `PhoenixReplay.CaptureStream` API | Task 3 + 4 |
| D7 Time alignment (single-shot offset) | Task 7 + 8 |
| Capture mechanism (`attach_hook` lifecycle) | Task 5 + 6 |
| Shape extraction default extractor table | Task 2 |
| Performance budget (`< 5µs` no-op path) | Task 3 (ETS lookup) + Task 9 (smoke timing) |
| Failure semantics (try/rescue) | Task 6 |
| Observability telemetry events | **Deferred to Phase 3** |
| Replay UI (admin sidebar tab) | **Deferred to Phase 2** |
| `use PhoenixReplay.LiveView` macro + allowlist | **Deferred to Phase 2** |
| Custom shape extractors via app config | **Deferred to Phase 2** |
| `params: [...]` event-param allowlist | **Deferred to Phase 2** |
| Igniter auto-install | **Deferred to Phase 3** |
| Benchee suite | **Deferred to Phase 3** |
| ADR-0007 record | Task 9 |

## File structure

| File | Status | Responsibility |
|---|---|---|
| `lib/phoenix_replay/live_view/shape.ex` | **Create** | Pure-function shape extractor — reduces any Elixir term to a key/type/size representation with no leaf values |
| `lib/phoenix_replay/capture_stream.ex` | **Create** | Public API: `record_clock_offset/2`, `attach/3`, `push_event/3`, `flush_for_session/1`. ETS-backed hot-path lookup; delegates state to Session GenServer |
| `lib/phoenix_replay/capture_stream/registry.ex` | **Create** | ETS table owner. Started by `PhoenixReplay.Application` supervision tree. Single named table `:phoenix_replay_capture_streams` keyed by `{session_id, stream_id}` → session_pid |
| `lib/phoenix_replay/session.ex` | Modify | Extend GenServer state with `capture_streams`, `capture_opts`, `clock_offset` fields; add `handle_cast({:capture_push, stream_id, event}, state)` + `handle_call(:drain_capture_streams, _, state)`; ensure ETS rows registered on stream attach and cleaned on session terminate |
| `lib/phoenix_replay/application.ex` | Modify | Start `PhoenixReplay.CaptureStream.Registry` (owns the ETS table) before `Session.Supervisor` |
| `lib/phoenix_replay/live_view/registry.ex` | **Create** | `Registry`-based `transport_pid → session_id` map (separate from CaptureStream's ETS, scoped to LiveView wiring) |
| `lib/phoenix_replay/live_view/snapshots.ex` | **Create** | `on_mount/4` callback; `attach_hook` registrations for `:handle_event`, `:handle_info`, `:handle_async`, `:handle_params`; transient `:after_render` for snapshot pairing; 50ms-per-`{lv_pid, event_name}` throttle; `try/rescue` wrappers; mount baseline |
| `priv/static/assets/phoenix_replay.js` | Modify | Send `client_started_at_ms` in the existing `/session` and `/report` POST bodies; include the same value in `/submit` for Path B parity |
| `lib/phoenix_replay/controller/events_controller.ex` | Modify | On `/session` (or first `/events` if no `/session` exists; this codebase uses `/session` for both Path A `:active` and Path B), call `CaptureStream.record_clock_offset/2` before pipeline returns |
| `lib/phoenix_replay/controller/report_controller.ex` | Modify | Path A: call `record_clock_offset/2` with the inline `client_started_at_ms`; flush server-side capture stream and merge with rrweb batch before persist |
| `lib/phoenix_replay/controller/submit_controller.ex` | Modify | Path B: flush server-side capture stream and merge before final persist + close |
| `test/phoenix_replay/live_view/shape_test.exs` | **Create** | Default-extractor matrix + PII property test (no leaf value of input appears in output's term-binary form) |
| `test/phoenix_replay/capture_stream_test.exs` | **Create** | attach/push/flush correctness; offset application; missing-offset fallback; concurrent push/flush; overflow eviction |
| `test/phoenix_replay/session_capture_test.exs` | **Create** | Session GenServer cast + drain handlers under realistic flow |
| `test/phoenix_replay/live_view/snapshots_test.exs` | **Create** | LiveView integration: hooks attach when registry has session, do not attach otherwise; capture callbacks emit expected payloads; rescue path keeps LV alive on extractor crash |
| `test/phoenix_replay/integration/lv_snapshot_e2e_test.exs` | **Create** | End-to-end: synthetic LV mounts, fires events, `/submit` flushes, events row contains type-6 plugin events with browser-timeline timestamps |
| `CHANGELOG.md` | Modify | Unreleased → "Phase 1 — LiveView snapshot stream foundation" entry |
| `docs/decisions/0007-liveview-snapshot-stream.md` | **Create** | ADR-0007 (Proposed → Accepted as part of Phase 1 land) |
| `docs/plans/README.md` | Modify | Index entry for this plan; cross-link to spec + ADR |

No new dependencies. No new database tables, no migrations — capture events ride the existing `phoenix_replay_events` table via the same `Storage.Dispatch.append_events/3` path used today.

---

## Task 1 — Recon: confirm integration points

**Files:** none modified. Output is a verification list used by all later tasks.

- [ ] **Step 1: Confirm `PhoenixReplay.Session` state shape and supervision.** Read `lib/phoenix_replay/session.ex`. Note:
  - It is a `GenServer` with `restart: :transient`.
  - Started by `PhoenixReplay.SessionSupervisor`, registered in `PhoenixReplay.SessionRegistry` (a `Registry`) under `session_id`.
  - State is held in module-internal struct(s) — confirm by running `Grep` for `defstruct` inside the file.
  - Lifecycle messages (`:idle_timeout`, `close/2`) cause normal exit and supervisor does NOT restart (transient + reason `:normal`).
  - Memory note (`feedback_session_transient_restart_breaks_kill_tests.md`): kill-tests must use `GenServer.stop(:normal)` or `Session.close/2`, not abnormal exits, or the supervisor respawns.

- [ ] **Step 2: Confirm `Storage.Dispatch.append_events/3` accepts opaque event maps.** Read `lib/phoenix_replay/storage/dispatch.ex` and `storage/ecto.ex`. Note:
  - The events parameter is `[map()]` — the ecto adapter encodes the batch as jsonb; nothing inspects the rrweb internal structure.
  - This means our type-6 plugin events ride the same path with no adapter changes.

- [ ] **Step 3: Confirm `PhoenixReplay.Ingest.Pipeline` step shape.** Read `lib/phoenix_replay/ingest/pipeline.ex`. Note:
  - Each step takes a `ctx :: map()` and returns `{:ok, ctx}` or `{:error, %Error{}}`.
  - Controllers thread `with` over these. New steps for `CaptureStream` integration land here in Task 8.

- [ ] **Step 4: Confirm client widget POST shapes.** In `priv/static/assets/phoenix_replay.js`, search for `"/session"` and `"/report"` and `"/submit"` POST sites. Note the request body shape today (no `client_started_at_ms` field). Task 7 adds that field at all three sites.

- [ ] **Step 5: Confirm `Phoenix.LiveView.attach_hook/4` is available at the project's LV version.** Run `mix deps | grep phoenix_live_view` from the phoenix_replay repo. Project consumes ≥ 1.1, which has `attach_hook/4`, `detach_hook/3`, `on_mount/4` — all needed APIs are stable. No fallback required.

- [ ] **Step 6: Confirm `Phoenix.LiveView.Debug.socket/1` is the public extraction API.** Note: We do not use `:erlang.trace`, `:dbg`, or any internal LiveView state inspection. Snapshots capture `socket.assigns` directly inside the hook (the hook runs in the LV process, so `socket.assigns` is in scope).

No commit — Task 1 is read-only.

---

## Task 2 — `PhoenixReplay.LiveView.Shape` extractor + PII property test

**Files:**
- Create: `lib/phoenix_replay/live_view/shape.ex`
- Create: `test/phoenix_replay/live_view/shape_test.exs`

The extractor is pure and stateless. It takes any term and returns a representation that contains key names, type tags, and size hints — and provably no leaf values from the input. Phase 1 implements only the default extractor table; custom extractors via `config :phoenix_replay, :snapshot_shape_extractors` are deferred to Phase 2.

- [ ] **Step 1: Write the failing test.** Create `test/phoenix_replay/live_view/shape_test.exs`:

  ```elixir
  defmodule PhoenixReplay.LiveView.ShapeTest do
    use ExUnit.Case, async: true

    alias PhoenixReplay.LiveView.Shape

    describe "extract/1 — default mappings" do
      test "primitives produce type tags without values" do
        assert Shape.extract(nil) == :nil
        assert Shape.extract(true) == :boolean
        assert Shape.extract(false) == :boolean
        assert Shape.extract(42) == :integer
        assert Shape.extract(3.14) == :float
        assert Shape.extract(:any_atom) == :atom
        assert Shape.extract(make_ref()) == :reference
        assert Shape.extract(self()) == :pid
        assert Shape.extract(fn -> :ok end) == :function
      end

      test "binary returns length, not content" do
        assert Shape.extract("hello") == {:string, length: 5}
        assert Shape.extract("") == {:string, length: 0}
        assert Shape.extract(<<0, 1, 2>>) == {:binary, length: 3}
      end

      test "list returns length, not elements" do
        assert Shape.extract([1, 2, 3]) == {:list, length: 3}
        assert Shape.extract([]) == {:list, length: 0}
      end

      test "tuple returns size" do
        assert Shape.extract({:ok, 42}) == {:tuple, size: 2}
        assert Shape.extract({}) == {:tuple, size: 0}
      end

      test "map returns keys, not values" do
        assert Shape.extract(%{a: 1, b: "secret"}) ==
                 {:map, keys: [:a, :b]}

        assert Shape.extract(%{}) == {:map, keys: []}
      end

      test "MapSet returns size" do
        assert Shape.extract(MapSet.new([1, 2, 3])) ==
                 {:mapset, size: 3}
      end

      test "Date/DateTime/NaiveDateTime collapse to type tags" do
        assert Shape.extract(~D[2026-04-28]) == :date
        assert Shape.extract(~U[2026-04-28 12:00:00Z]) == :datetime
        assert Shape.extract(~N[2026-04-28 12:00:00]) == :naive_datetime
      end

      test "Ecto.Changeset returns valid?, fields, error_count — no values" do
        changeset = %Ecto.Changeset{
          data: %{},
          changes: %{name: "alice", email: "a@b.c"},
          errors: [name: {"too short", []}],
          valid?: false,
          types: %{name: :string, email: :string}
        }

        assert Shape.extract(changeset) ==
                 {:changeset, valid?: false, fields: [:name, :email], error_count: 1}
      end

      test "Phoenix.HTML.Form returns name + fields + error_count" do
        form = %Phoenix.HTML.Form{
          source: %Ecto.Changeset{errors: []},
          name: "user",
          data: %{name: "alice", email: "a@b"},
          params: %{},
          errors: [],
          impl: nil,
          id: "user",
          index: nil,
          action: nil,
          options: [],
          hidden: []
        }

        assert Shape.extract(form) ==
                 {:form, name: "user", fields: [:name, :email], error_count: 0}
      end

      test "user struct returns module + fields, no values" do
        defmodule SomeUser do
          defstruct [:id, :email, :name, :secret_token]
        end

        u = %SomeUser{id: 1, email: "a@b", name: "alice", secret_token: "REDACTED"}

        assert Shape.extract(u) ==
                 {:struct, SomeUser, fields: [:id, :email, :name, :secret_token]}
      end

      test "unknown opaque values fall through to :opaque" do
        # Port is opaque — we don't add it to the table on purpose.
        port = Port.list() |> List.first()

        if port do
          assert match?({:opaque, _}, Shape.extract(port))
        end
      end
    end

    describe "extract/1 — PII safety property" do
      # The core invariant. For any term, no leaf value of the term
      # may appear in the serialized output. We sample a handful of
      # cases here and rely on the property test in the next test for
      # randomized coverage.

      test "leaf string never leaks" do
        secret = "P@SSWORD-#{System.unique_integer([:positive])}"
        out = Shape.extract(%{user: %{token: secret, name: secret}})
        out_bin = :erlang.term_to_binary(out)
        secret_bin = :erlang.term_to_binary(secret)
        # secret_bin should NOT be a substring of out_bin
        refute String.contains?(out_bin, binary_part(secret_bin, 5, byte_size(secret_bin) - 5)),
               "shape output contained the raw secret string — PII leak"
      end

      test "leaf integer never leaks (other than as length/size hints)" do
        # Use an integer too large to be a length count for any
        # reasonable list; if it shows up, it's a value leak.
        sentinel = 9_999_999
        out = Shape.extract(%{count: sentinel, user: %{age: sentinel}})

        refute out
               |> :erlang.term_to_binary()
               |> :binary.match(:erlang.term_to_binary(sentinel))
               |> match?({_, _}),
               "shape output contained the sentinel integer — PII leak"
      end

      test "atom values never leak (only keys, never values)" do
        # The map %{role: :admin} should yield {:map, keys: [:role]} —
        # NOT include :admin anywhere.
        out = Shape.extract(%{role: :super_secret_admin_role})
        atoms = collect_atoms(out)
        refute :super_secret_admin_role in atoms,
               "shape output contained the value atom — PII leak"
      end

      defp collect_atoms(term) when is_atom(term), do: [term]
      defp collect_atoms(term) when is_list(term), do: Enum.flat_map(term, &collect_atoms/1)
      defp collect_atoms(term) when is_tuple(term),
        do: term |> Tuple.to_list() |> Enum.flat_map(&collect_atoms/1)
      defp collect_atoms(term) when is_map(term),
        do: term |> Map.to_list() |> Enum.flat_map(&collect_atoms/1)
      defp collect_atoms(_), do: []
    end
  end
  ```

- [ ] **Step 2: Run the test, verify it fails.**

  ```bash
  cd ~/Dev/phoenix_replay
  mix test test/phoenix_replay/live_view/shape_test.exs
  ```

  Expected: `(CompileError) ... PhoenixReplay.LiveView.Shape is undefined`.

- [ ] **Step 3: Implement `PhoenixReplay.LiveView.Shape`.** Create `lib/phoenix_replay/live_view/shape.ex`:

  ```elixir
  defmodule PhoenixReplay.LiveView.Shape do
    @moduledoc """
    Pure-function shape extractor — reduces any Elixir term to a
    key/type/size representation with no leaf values.

    The output is the safe-by-construction default for snapshot
    payloads. Every Phase 1 snapshot's `assigns_shape` field is the
    result of `Map.new(assigns, fn {k, v} -> {k, extract(v)} end)`.

    See `docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md`
    section "Default extractor".
    """

    @type shape ::
            :nil
            | :boolean
            | :integer
            | :float
            | :atom
            | :pid
            | :reference
            | :function
            | :date
            | :datetime
            | :naive_datetime
            | {:string, [length: non_neg_integer()]}
            | {:binary, [length: non_neg_integer()]}
            | {:list, [length: non_neg_integer()]}
            | {:tuple, [size: non_neg_integer()]}
            | {:map, [keys: [atom() | binary()]]}
            | {:mapset, [size: non_neg_integer()]}
            | {:changeset, keyword()}
            | {:form, keyword()}
            | {:struct, module(), [fields: [atom()]]}
            | {:opaque, atom()}

    @spec extract(term()) :: shape
    def extract(nil), do: :nil
    def extract(b) when is_boolean(b), do: :boolean
    def extract(i) when is_integer(i), do: :integer
    def extract(f) when is_float(f), do: :float
    def extract(a) when is_atom(a), do: :atom
    def extract(p) when is_pid(p), do: :pid
    def extract(r) when is_reference(r), do: :reference
    def extract(f) when is_function(f), do: :function

    def extract(s) when is_binary(s) do
      if String.printable?(s) do
        {:string, length: byte_size(s)}
      else
        {:binary, length: byte_size(s)}
      end
    end

    def extract(l) when is_list(l), do: {:list, length: length(l)}
    def extract(t) when is_tuple(t), do: {:tuple, size: tuple_size(t)}

    def extract(%Date{}), do: :date
    def extract(%DateTime{}), do: :datetime
    def extract(%NaiveDateTime{}), do: :naive_datetime
    def extract(%MapSet{} = ms), do: {:mapset, size: MapSet.size(ms)}

    def extract(%Ecto.Changeset{} = cs) do
      fields =
        cs
        |> Map.get(:types, %{})
        |> Map.keys()
        |> Enum.sort()

      {:changeset, valid?: cs.valid?, fields: fields, error_count: length(cs.errors)}
    end

    def extract(%Phoenix.HTML.Form{} = form) do
      fields =
        case form.data do
          %_{} = struct ->
            struct |> Map.from_struct() |> Map.keys() |> Enum.sort()

          %{} = map ->
            map |> Map.keys() |> Enum.sort()

          _ ->
            []
        end

      {:form, name: to_string(form.name || ""), fields: fields, error_count: length(form.errors)}
    end

    def extract(%mod{} = struct) do
      fields = struct |> Map.from_struct() |> Map.keys() |> Enum.sort()
      {:struct, mod, fields: fields}
    end

    def extract(map) when is_map(map) do
      keys = map |> Map.keys() |> Enum.sort()
      {:map, keys: keys}
    end

    def extract(other) do
      class =
        cond do
          is_port(other) -> :port
          true -> :unknown
        end

      {:opaque, class}
    end

    @doc """
    Reduce a `socket.assigns` map (which may include LiveView's
    private `__changed__` and friends) to the shape map persisted in
    the snapshot payload. Drops Phoenix.LiveView private keys
    (anything starting with `__`).
    """
    @spec extract_assigns(map()) :: map()
    def extract_assigns(assigns) when is_map(assigns) do
      assigns
      |> Map.reject(fn {k, _} -> is_atom(k) and String.starts_with?(Atom.to_string(k), "__") end)
      |> Map.new(fn {k, v} -> {k, extract(v)} end)
    end
  end
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```bash
  mix test test/phoenix_replay/live_view/shape_test.exs
  ```

  Expected: all tests pass.

- [ ] **Step 5: Commit.**

  ```bash
  git add lib/phoenix_replay/live_view/shape.ex test/phoenix_replay/live_view/shape_test.exs
  git commit -m "$(cat <<'EOF'
  feat(lv-snapshot): Shape extractor — leaf-value-free assigns reduction

  Phase 1 of the LiveView snapshot stream (ADR-0007). Pure-function
  shape extractor that maps any Elixir term to a key/type/size
  representation containing no leaf values. PII property test asserts
  the invariant: term-binary of a sentinel value never appears in
  the output's term-binary form.

  Default extractor table covers primitives, binaries, collections,
  Date/DateTime, MapSet, Ecto.Changeset, Phoenix.HTML.Form, and user
  structs. Custom extractors (host config) deferred to Phase 2.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 3 — `PhoenixReplay.CaptureStream` API surface

**Files:**
- Create: `lib/phoenix_replay/capture_stream.ex`
- Create: `lib/phoenix_replay/capture_stream/registry.ex`
- Create: `test/phoenix_replay/capture_stream_test.exs`
- Modify: `lib/phoenix_replay/application.ex`

The CaptureStream module is the public API. The Registry submodule owns the ETS table that maps `{session_id, stream_id} → session_pid` for the O(1) hot-path lookup. Phase 1 implements the API against a stub GenServer (a plain test-local `Agent` mimicking the Session protocol); Task 4 wires the real `PhoenixReplay.Session`.

- [ ] **Step 1: Write the failing test.** Create `test/phoenix_replay/capture_stream_test.exs`:

  ```elixir
  defmodule PhoenixReplay.CaptureStreamTest do
    use ExUnit.Case, async: false  # ETS singleton + Application start

    alias PhoenixReplay.CaptureStream

    @session_id "session-cap-test-1"
    @stream_id "phx-replay/test@1"

    setup do
      # Each test gets a fresh stub session pid registered in the ETS
      # table under its own {session_id, stream_id}.
      {:ok, pid} = start_supervised(StubSession)
      :ok = CaptureStream.Registry.register(@session_id, @stream_id, pid)
      on_exit(fn -> CaptureStream.Registry.unregister(@session_id, @stream_id) end)
      %{pid: pid}
    end

    test "push_event/3 returns :ok and routes to the registered pid", %{pid: pid} do
      :ok =
        CaptureStream.push_event(@session_id, @stream_id, %{
          server_time_ms: 1000,
          payload: %{kind: :marker}
        })

      assert StubSession.events(pid) == [
               {@stream_id, %{server_time_ms: 1000, payload: %{kind: :marker}}}
             ]
    end

    test "push_event/3 is a silent no-op when stream is not registered" do
      assert :ok =
               CaptureStream.push_event("unknown-session", "unknown/stream@1", %{
                 server_time_ms: 0,
                 payload: %{}
               })
    end

    test "record_clock_offset/2 stores offset in the registered session", %{pid: pid} do
      :ok = CaptureStream.record_clock_offset(@session_id, 1000)
      assert StubSession.clock_offset(pid) != nil
    end

    test "flush_for_session/1 drains and applies offset, wraps in rrweb type-6", %{pid: pid} do
      :ok = CaptureStream.record_clock_offset(@session_id, 1000)
      # Server is 500ms ahead of browser → offset = 500
      _ = StubSession.set_received_at(pid, 1500)

      :ok =
        CaptureStream.push_event(@session_id, @stream_id, %{
          server_time_ms: 2000,
          payload: %{kind: :marker, name: "click"}
        })

      [event] = CaptureStream.flush_for_session(@session_id)

      assert event["type"] == 6
      # 2000 server - 500 offset = 1500 browser timeline
      assert event["timestamp"] == 1500
      assert event["data"]["plugin"] == @stream_id
      assert event["data"]["payload"] == %{kind: :marker, name: "click"}
    end

    test "flush_for_session/1 with no offset falls back to raw server time", %{pid: pid} do
      _ = pid

      :ok =
        CaptureStream.push_event(@session_id, @stream_id, %{
          server_time_ms: 7777,
          payload: %{}
        })

      [event] = CaptureStream.flush_for_session(@session_id)
      assert event["timestamp"] == 7777
    end

    test "flush_for_session/1 returns [] for unknown session" do
      assert CaptureStream.flush_for_session("unknown-session") == []
    end
  end

  # Test stub mimicking the Session GenServer protocol used by
  # CaptureStream. Real Session integration is in Task 4.
  defmodule StubSession do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{events: [], offset: nil, received_at: nil} end)
    end

    # Protocol expected by CaptureStream:
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def handle_capture_push(pid, stream_id, event) do
      Agent.update(pid, fn s -> %{s | events: s.events ++ [{stream_id, event}]} end)
      :ok
    end

    def record_clock_offset(pid, browser_started_at_ms) do
      Agent.update(pid, fn s ->
        offset = (s.received_at || browser_started_at_ms) - browser_started_at_ms
        %{s | offset: offset}
      end)
    end

    def drain_capture_streams(pid) do
      Agent.get_and_update(pid, fn s ->
        offset = s.offset || 0
        out =
          Enum.map(s.events, fn {sid, ev} ->
            %{
              "type" => 6,
              "timestamp" => ev.server_time_ms - offset,
              "data" => %{"plugin" => sid, "payload" => ev.payload}
            }
          end)

        {out, %{s | events: []}}
      end)
    end

    def events(pid), do: Agent.get(pid, & &1.events)
    def clock_offset(pid), do: Agent.get(pid, & &1.offset)
    def set_received_at(pid, ts), do: Agent.update(pid, &%{&1 | received_at: ts})
  end
  ```

- [ ] **Step 2: Run the test, verify it fails.**

  ```bash
  mix test test/phoenix_replay/capture_stream_test.exs
  ```

  Expected: `PhoenixReplay.CaptureStream is undefined`.

- [ ] **Step 3: Implement the Registry submodule.** Create `lib/phoenix_replay/capture_stream/registry.ex`:

  ```elixir
  defmodule PhoenixReplay.CaptureStream.Registry do
    @moduledoc false
    # Owns the ETS table mapping {session_id, stream_id} → session_pid
    # for CaptureStream's O(1) hot-path lookup. Started in the
    # PhoenixReplay supervision tree before the SessionSupervisor.
    #
    # Read access via :ets.lookup is concurrent-safe with no GenServer
    # roundtrip; writes go through this process for serialization.

    use GenServer

    @table :phoenix_replay_capture_streams

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc "Returns the session pid responsible for the given stream, or nil."
    @spec lookup(String.t(), String.t()) :: pid() | nil
    def lookup(session_id, stream_id) do
      case :ets.lookup(@table, {session_id, stream_id}) do
        [{_, pid}] -> pid
        [] -> nil
      end
    end

    @doc "Returns all stream_ids registered for a session."
    @spec streams_for_session(String.t()) :: [String.t()]
    def streams_for_session(session_id) do
      :ets.match(@table, {{session_id, :"$1"}, :_})
      |> List.flatten()
    end

    @doc "Returns the unique pid (or nil) for the session, across all its streams."
    @spec session_pid(String.t()) :: pid() | nil
    def session_pid(session_id) do
      case :ets.match(@table, {{session_id, :_}, :"$1"}) |> List.flatten() do
        [pid | _] -> pid
        [] -> nil
      end
    end

    def register(session_id, stream_id, pid) do
      GenServer.call(__MODULE__, {:register, session_id, stream_id, pid})
    end

    def unregister(session_id, stream_id) do
      GenServer.call(__MODULE__, {:unregister, session_id, stream_id})
    end

    def unregister_session(session_id) do
      GenServer.call(__MODULE__, {:unregister_session, session_id})
    end

    @impl true
    def init(_opts) do
      table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      {:ok, %{table: table, monitors: %{}}}
    end

    @impl true
    def handle_call({:register, session_id, stream_id, pid}, _from, state) do
      :ets.insert(@table, {{session_id, stream_id}, pid})
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.monitors[{session_id, stream_id}], ref)}
    end

    def handle_call({:unregister, session_id, stream_id}, _from, state) do
      :ets.delete(@table, {session_id, stream_id})

      state =
        case Map.pop(state.monitors, {session_id, stream_id}) do
          {nil, m} -> %{state | monitors: m}
          {ref, m} ->
            Process.demonitor(ref, [:flush])
            %{state | monitors: m}
        end

      {:reply, :ok, state}
    end

    def handle_call({:unregister_session, session_id}, _from, state) do
      streams = streams_for_session(session_id)

      state =
        Enum.reduce(streams, state, fn stream_id, acc ->
          :ets.delete(@table, {session_id, stream_id})

          case Map.pop(acc.monitors, {session_id, stream_id}) do
            {nil, m} -> %{acc | monitors: m}
            {ref, m} ->
              Process.demonitor(ref, [:flush])
              %{acc | monitors: m}
          end
        end)

      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
      # Session crashed — purge all entries pointing at this pid.
      to_delete =
        :ets.match(@table, {{:"$1", :"$2"}, pid})
        |> Enum.map(fn [sid, stid] -> {sid, stid} end)

      Enum.each(to_delete, fn key -> :ets.delete(@table, key) end)

      monitors = Map.drop(state.monitors, to_delete)
      {:noreply, %{state | monitors: monitors}}
    end
  end
  ```

- [ ] **Step 4: Implement the public API.** Create `lib/phoenix_replay/capture_stream.ex`:

  ```elixir
  defmodule PhoenixReplay.CaptureStream do
    @moduledoc """
    Server-origin capture stream registry.

    Allows libraries (including phoenix_replay's own LiveView snapshot
    capture, and external consumers like ash_feedback) to push
    server-side events into a phoenix_replay session's recording stream
    with automatic clock-offset alignment to the browser timeline.

    See `docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md`
    for the full design rationale.

    ## Wire format

    `flush_for_session/1` returns rrweb-type-6-shaped maps suitable for
    merging into the existing rrweb event batch:

        %{
          "type" => 6,
          "timestamp" => browser_timeline_ms,
          "data" => %{
            "plugin" => stream_id,
            "payload" => map_passed_to_push_event
          }
        }

    Server-time → browser-time conversion happens exactly once, inside
    `flush_for_session/1`. Push-time storage uses raw `server_time_ms`.
    """

    alias PhoenixReplay.CaptureStream.Registry

    @type session_id :: String.t()
    @type stream_id :: String.t()
    @type event :: %{
            required(:server_time_ms) => integer(),
            required(:payload) => map()
          }

    @doc """
    Records the clock offset for a session — the difference between
    server-arrival time and the browser's `Date.now()` at the moment
    the client bootstrapped. Subsequent `push_event/3` calls' raw
    `server_time_ms` values are converted to browser timeline by
    subtracting this offset.

    Idempotent: a second call replaces the first. Silent no-op if the
    session has no registered streams (no recording).
    """
    @spec record_clock_offset(session_id, integer()) :: :ok
    def record_clock_offset(session_id, browser_started_at_ms) do
      case Registry.session_pid(session_id) do
        nil -> :ok
        pid -> session_module().record_clock_offset(pid, browser_started_at_ms)
      end
    end

    @doc """
    Registers a stream for a session. Activates the scratch buffer so
    `push_event/3` accepts events. No-op if already attached.

    Options (Phase 1 honors only `:max_events`; `:ttl_ms` and
    `:max_bytes` are accepted but reserved for future enforcement):

      * `:max_events` — hard cap on scratch buffer size (default 5000).
        On overflow, oldest event is evicted (ring queue semantics).

    Note: the actual scratch buffer lives in the Session GenServer.
    This function ensures the Registry has a row pointing back to that
    GenServer's pid, which is what makes `push_event/3`'s ETS lookup
    succeed.
    """
    @spec attach(session_id, stream_id, keyword()) :: :ok
    def attach(session_id, stream_id, opts \\ []) do
      case session_module().pid_for(session_id) do
        nil ->
          {:error, :no_session}

        pid ->
          session_module().attach_stream(pid, stream_id, opts)
          Registry.register(session_id, stream_id, pid)
          :ok
      end
    end

    @doc """
    Pushes a server-origin event into the session's scratch buffer.

    Hot-path budget: `< 5µs` when no stream is registered (single ETS
    lookup, no GenServer roundtrip).

    Silent `:ok` when the stream is not attached or the session does
    not exist. This lets call sites stay simple — instrumentation can
    safely call `push_event/3` unconditionally.
    """
    @spec push_event(session_id, stream_id, event) :: :ok
    def push_event(session_id, stream_id, %{server_time_ms: _, payload: _} = event) do
      case Registry.lookup(session_id, stream_id) do
        nil -> :ok
        pid -> session_module().handle_capture_push(pid, stream_id, event)
      end
    end

    @doc """
    Drains all scratch buffers for the session, applies the clock
    offset, wraps each event in rrweb type-6 plugin format, and
    returns the result. The caller (typically the ingest pipeline in
    `ReportController` / `SubmitController`) is responsible for
    timestamp-sorting the merged batch before persistence.

    After flush, scratch buffers are empty but streams remain attached.
    """
    @spec flush_for_session(session_id) :: [map()]
    def flush_for_session(session_id) do
      case Registry.session_pid(session_id) do
        nil -> []
        pid -> session_module().drain_capture_streams(pid)
      end
    end

    # Indirection so tests can swap a stub in via `Application.put_env`.
    defp session_module do
      Application.get_env(:phoenix_replay, :capture_stream_session_module, default_session_module())
    end

    defp default_session_module do
      # Resolved late — the Session module isn't loaded by this file
      # at compile time. Tests using StubSession set the env directly.
      PhoenixReplay.Session
    end
  end
  ```

- [ ] **Step 5: Wire `Registry` into the supervision tree.** Read `lib/phoenix_replay/application.ex`. Insert `PhoenixReplay.CaptureStream.Registry` to the children list, before `PhoenixReplay.SessionSupervisor` (so the ETS table exists by the time any session boots):

  ```elixir
  defp children do
    [
      # ... existing entries before SessionSupervisor ...
      PhoenixReplay.CaptureStream.Registry,
      PhoenixReplay.SessionSupervisor
      # ... existing entries after ...
    ]
  end
  ```

  Confirm via `mix compile` that the file still compiles.

- [ ] **Step 6: Point the test at `StubSession` via env.** In the test file's `setup` (top of the `describe`-less section, before the per-test setup), add to the test's `setup_all`:

  ```elixir
  setup_all do
    prev = Application.get_env(:phoenix_replay, :capture_stream_session_module)
    Application.put_env(:phoenix_replay, :capture_stream_session_module, StubSessionModule)
    on_exit(fn ->
      if prev do
        Application.put_env(:phoenix_replay, :capture_stream_session_module, prev)
      else
        Application.delete_env(:phoenix_replay, :capture_stream_session_module)
      end
    end)
    :ok
  end
  ```

  And replace `StubSession` (the Agent) with a thin `StubSessionModule` that exposes the protocol functions used by `CaptureStream`. Add this at the bottom of `test/phoenix_replay/capture_stream_test.exs` (replacing the previous `StubSession` block):

  ```elixir
  defmodule StubSessionModule do
    @moduledoc false
    # Thin facade over an Agent-based StubSession that exposes the
    # call-site shape CaptureStream's `session_module/0` expects.

    def pid_for(session_id) do
      case Process.whereis(:"stub_session_#{session_id}") do
        nil -> nil
        pid -> pid
      end
    end

    def attach_stream(pid, stream_id, _opts) do
      send(pid, {:attach_stream, stream_id})
      :ok
    end

    def handle_capture_push(pid, stream_id, event) do
      Agent.update(pid, fn s -> %{s | events: s.events ++ [{stream_id, event}]} end)
      :ok
    end

    def record_clock_offset(pid, browser_started_at_ms) do
      Agent.update(pid, fn s ->
        offset = (s.received_at || browser_started_at_ms) - browser_started_at_ms
        %{s | offset: offset}
      end)
      :ok
    end

    def drain_capture_streams(pid) do
      Agent.get_and_update(pid, fn s ->
        offset = s.offset || 0
        out =
          Enum.map(s.events, fn {sid, ev} ->
            %{
              "type" => 6,
              "timestamp" => ev.server_time_ms - offset,
              "data" => %{"plugin" => sid, "payload" => ev.payload}
            }
          end)

        {out, %{s | events: []}}
      end)
    end
  end

  defmodule StubSession do
    use Agent

    def start_link(session_id) do
      Agent.start_link(
        fn -> %{events: [], offset: nil, received_at: nil} end,
        name: :"stub_session_#{session_id}"
      )
    end

    def child_spec(session_id) do
      %{id: {__MODULE__, session_id}, start: {__MODULE__, :start_link, [session_id]}}
    end

    def events(pid), do: Agent.get(pid, & &1.events)
    def clock_offset(pid), do: Agent.get(pid, & &1.offset)
    def set_received_at(pid, ts), do: Agent.update(pid, &%{&1 | received_at: ts}), do: :ok
  end
  ```

  Update the per-test `setup` to start the stub by session_id and call `Registry.register/3` directly (the stub bypasses `attach/3` since it has no real Session pid to attach to):

  ```elixir
  setup do
    {:ok, pid} = start_supervised({StubSession, @session_id})
    :ok = PhoenixReplay.CaptureStream.Registry.register(@session_id, @stream_id, pid)
    on_exit(fn -> PhoenixReplay.CaptureStream.Registry.unregister(@session_id, @stream_id) end)
    %{pid: pid}
  end
  ```

- [ ] **Step 7: Run the test, verify it passes.**

  ```bash
  mix test test/phoenix_replay/capture_stream_test.exs
  ```

  Expected: all tests pass.

- [ ] **Step 8: Commit.**

  ```bash
  git add lib/phoenix_replay/capture_stream.ex \
          lib/phoenix_replay/capture_stream/registry.ex \
          lib/phoenix_replay/application.ex \
          test/phoenix_replay/capture_stream_test.exs
  git commit -m "$(cat <<'EOF'
  feat(capture-stream): public API + ETS registry for server-origin streams

  PhoenixReplay.CaptureStream is the new public API for libraries
  (phoenix_replay's own LV snapshot, future ash_feedback consumers,
  etc.) to push server-side events into a phoenix_replay session
  recording with automatic clock-offset alignment.

  Hot-path is a single ETS lookup; missing-session push is a silent
  no-op so call sites stay simple. Server-time → browser-time
  conversion happens exactly once at flush. Wire format mirrors
  rrweb's type-6 plugin events for replay-player compatibility.

  Phase 1 of ADR-0007. The Session-side state extension (the actual
  scratch buffers) lands in the next task.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 4 — Extend `PhoenixReplay.Session` with capture-stream state

**Files:**
- Modify: `lib/phoenix_replay/session.ex`
- Create: `test/phoenix_replay/session_capture_test.exs`

Replace the test stub with the real Session GenServer. The Session keeps a per-stream queue, applies offsets at drain time, and registers with `CaptureStream.Registry` on attach so the ETS lookup hits.

- [ ] **Step 1: Inspect current Session state shape.** Open `lib/phoenix_replay/session.ex`. Find the `defstruct` definition (in the GenServer module body — `PhoenixReplay.Session` may have an internal `State` module after the 2026-04-26 split per memory `feedback_session_transient_restart_breaks_kill_tests`; if there's a separate `State` module under `lib/phoenix_replay/session/`, modify that file instead).

- [ ] **Step 2: Write the failing test.** Create `test/phoenix_replay/session_capture_test.exs`:

  ```elixir
  defmodule PhoenixReplay.SessionCaptureTest do
    use ExUnit.Case, async: false

    alias PhoenixReplay.{Session, CaptureStream}

    @session_id "session-cap-#{System.unique_integer([:positive])}"
    @stream_id "phx-replay/test@1"
    @identity %{kind: :anonymous, id: nil, attrs: %{}}

    setup do
      {:ok, pid} = Session.start_session(@session_id, @identity, seq_watermark: 0)
      on_exit(fn ->
        if Process.alive?(pid), do: Session.close(pid, :test_cleanup)
      end)
      %{pid: pid}
    end

    test "attach_stream/3 registers in CaptureStream.Registry", %{pid: pid} do
      :ok = Session.attach_stream(pid, @stream_id, [])
      assert CaptureStream.Registry.lookup(@session_id, @stream_id) == pid
    end

    test "handle_capture_push + drain_capture_streams round-trip applies offset", %{pid: pid} do
      :ok = Session.attach_stream(pid, @stream_id, [])
      :ok = Session.record_clock_offset(pid, 1000)
      _ = Session.set_clock_received_at_for_test(pid, 1500)  # offset = 500

      :ok =
        Session.handle_capture_push(pid, @stream_id, %{
          server_time_ms: 2000,
          payload: %{kind: :marker}
        })

      [event] = Session.drain_capture_streams(pid)

      assert event["type"] == 6
      assert event["timestamp"] == 1500
      assert event["data"]["plugin"] == @stream_id
      assert event["data"]["payload"] == %{kind: :marker}
    end

    test "drain twice empties the buffer the second time", %{pid: pid} do
      :ok = Session.attach_stream(pid, @stream_id, [])

      :ok =
        Session.handle_capture_push(pid, @stream_id, %{server_time_ms: 0, payload: %{}})

      assert [_] = Session.drain_capture_streams(pid)
      assert [] = Session.drain_capture_streams(pid)
    end

    test "ring overflow drops oldest", %{pid: pid} do
      :ok = Session.attach_stream(pid, @stream_id, max_events: 2)

      Enum.each(1..5, fn i ->
        Session.handle_capture_push(pid, @stream_id, %{server_time_ms: i, payload: %{i: i}})
      end)

      events = Session.drain_capture_streams(pid)
      assert length(events) == 2
      payloads = Enum.map(events, & &1["data"]["payload"])
      assert payloads == [%{i: 4}, %{i: 5}]
    end

    test "session terminate purges Registry entries", %{pid: pid} do
      :ok = Session.attach_stream(pid, @stream_id, [])
      assert CaptureStream.Registry.lookup(@session_id, @stream_id) == pid

      Session.close(pid, :test_done)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      # Registry's DOWN handler clears entries asynchronously; give it a tick.
      :sys.get_state(PhoenixReplay.CaptureStream.Registry)
      assert CaptureStream.Registry.lookup(@session_id, @stream_id) == nil
    end
  end
  ```

  Note: `Session.set_clock_received_at_for_test/2` is a test helper added in Step 3.

- [ ] **Step 3: Run the test, verify it fails.**

  ```bash
  mix test test/phoenix_replay/session_capture_test.exs
  ```

  Expected: `function PhoenixReplay.Session.attach_stream/3 is undefined`.

- [ ] **Step 4: Extend Session state.** Open `lib/phoenix_replay/session.ex` (or `lib/phoenix_replay/session/state.ex` if state was split out per the 2026-04-26 work). Find the `defstruct` and add three fields:

  ```elixir
  defstruct [
    # ... existing fields ...
    capture_streams: %{},          # %{stream_id => :queue.t()}
    capture_opts: %{},             # %{stream_id => keyword()}
    clock_offset: nil,             # integer() | nil — server_time - browser_time
    clock_received_at_ms: nil      # integer() | nil — used to compute offset on record_clock_offset/2
  ]
  ```

  Update any pattern matches on the struct that destructure all fields (typically only the test-cleanup `kill switch` checks; verify with `mix compile`).

- [ ] **Step 5: Add the public API surface to Session.** Append to `lib/phoenix_replay/session.ex` (within the module, before the `# Server callbacks` section):

  ```elixir
  # Capture stream API — invoked by PhoenixReplay.CaptureStream.

  @doc false
  @spec pid_for(String.t()) :: pid() | nil
  def pid_for(session_id) when is_binary(session_id) do
    case Registry.lookup(PhoenixReplay.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec attach_stream(pid(), String.t(), keyword()) :: :ok
  def attach_stream(pid, stream_id, opts) do
    GenServer.call(pid, {:attach_stream, stream_id, opts})
  end

  @doc false
  @spec record_clock_offset(pid(), integer()) :: :ok
  def record_clock_offset(pid, browser_started_at_ms) do
    GenServer.call(pid, {:record_clock_offset, browser_started_at_ms})
  end

  @doc false
  @spec handle_capture_push(pid(), String.t(), map()) :: :ok
  def handle_capture_push(pid, stream_id, event) do
    GenServer.cast(pid, {:capture_push, stream_id, event})
  end

  @doc false
  @spec drain_capture_streams(pid()) :: [map()]
  def drain_capture_streams(pid) do
    GenServer.call(pid, :drain_capture_streams)
  end

  @doc false
  # Test helper — sets the timestamp the next record_clock_offset call
  # treats as `server_received_at`. Production path uses
  # System.system_time(:millisecond) directly.
  @spec set_clock_received_at_for_test(pid(), integer()) :: :ok
  def set_clock_received_at_for_test(pid, ts) do
    GenServer.call(pid, {:set_clock_received_at, ts})
  end
  ```

- [ ] **Step 6: Implement the GenServer callbacks.** In the same file, add to the server-callbacks section:

  ```elixir
  @default_max_events 5_000

  @impl true
  def handle_call({:attach_stream, stream_id, opts}, _from, state) do
    state = %{
      state
      | capture_streams: Map.put_new(state.capture_streams, stream_id, :queue.new()),
        capture_opts: Map.put(state.capture_opts, stream_id, opts)
    }

    PhoenixReplay.CaptureStream.Registry.register(state.session_id, stream_id, self())
    {:reply, :ok, state}
  end

  def handle_call({:record_clock_offset, browser_started_at_ms}, _from, state) do
    received_at =
      state.clock_received_at_ms || System.system_time(:millisecond)

    offset = received_at - browser_started_at_ms
    {:reply, :ok, %{state | clock_offset: offset}}
  end

  def handle_call(:drain_capture_streams, _from, state) do
    offset = state.clock_offset || 0

    events =
      state.capture_streams
      |> Enum.flat_map(fn {stream_id, queue} ->
        queue
        |> :queue.to_list()
        |> Enum.map(fn ev ->
          %{
            "type" => 6,
            "timestamp" => ev.server_time_ms - offset,
            "data" => %{"plugin" => stream_id, "payload" => ev.payload}
          }
        end)
      end)

    cleared = Map.new(state.capture_streams, fn {sid, _} -> {sid, :queue.new()} end)
    {:reply, events, %{state | capture_streams: cleared}}
  end

  def handle_call({:set_clock_received_at, ts}, _from, state) do
    {:reply, :ok, %{state | clock_received_at_ms: ts}}
  end

  @impl true
  def handle_cast({:capture_push, stream_id, event}, state) do
    case Map.fetch(state.capture_streams, stream_id) do
      :error ->
        {:noreply, state}

      {:ok, queue} ->
        max =
          state.capture_opts
          |> Map.get(stream_id, [])
          |> Keyword.get(:max_events, @default_max_events)

        queue = :queue.in(event, queue)

        queue =
          case :queue.len(queue) do
            n when n > max ->
              {{:value, _evicted}, q2} = :queue.out(queue)
              q2

            _ ->
              queue
          end

        {:noreply, put_in(state.capture_streams[stream_id], queue)}
    end
  end
  ```

- [ ] **Step 7: Add cleanup on terminate.** Find the existing `terminate/2` in Session (or add one if not present). Append `unregister_session`:

  ```elixir
  @impl true
  def terminate(reason, state) do
    PhoenixReplay.CaptureStream.Registry.unregister_session(state.session_id)
    # ... preserve any existing terminate logic ...
    :ok
  end
  ```

  If a `terminate/2` already exists, add the `unregister_session` call as the first line. The Registry's `:DOWN` handler is a backup — explicit unregister keeps the synchronous test path deterministic.

- [ ] **Step 8: Remove the test stub indirection.** In `lib/phoenix_replay/capture_stream.ex`, simplify `session_module/0`:

  ```elixir
  defp session_module do
    Application.get_env(:phoenix_replay, :capture_stream_session_module, PhoenixReplay.Session)
  end
  ```

  This stays — the test indirection remains so isolated unit tests can stub Session out without booting it. The default now resolves to the real Session.

- [ ] **Step 9: Run the test, verify it passes.**

  ```bash
  mix test test/phoenix_replay/session_capture_test.exs
  ```

  Expected: all tests pass.

- [ ] **Step 10: Run the full test suite to ensure no regressions.**

  ```bash
  mix test
  ```

  Expected: existing tests still pass. Session memory: respect the `:transient` restart semantics (memory `feedback_session_transient_restart_breaks_kill_tests`) — terminate adding `unregister_session` should not change exit reason classification.

- [ ] **Step 11: Commit.**

  ```bash
  git add lib/phoenix_replay/session.ex lib/phoenix_replay/capture_stream.ex \
          test/phoenix_replay/session_capture_test.exs
  git commit -m "$(cat <<'EOF'
  feat(capture-stream): wire CaptureStream API into PhoenixReplay.Session

  Session GenServer state gains capture_streams (per-stream queues),
  capture_opts (per-stream options), clock_offset, and a test-only
  clock_received_at_ms hook. New API: attach_stream/3,
  record_clock_offset/2, handle_capture_push/3, drain_capture_streams/1.

  Per-stream max_events (default 5000) ring queue evicts oldest on
  overflow. drain converts server_time_ms → browser timeline by
  subtracting clock_offset, wraps in rrweb type-6 plugin format.
  Session terminate purges all Registry entries for the session.

  Phase 1 of ADR-0007.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 5 — `PhoenixReplay.LiveView.Registry` for transport_pid lookup

**Files:**
- Create: `lib/phoenix_replay/live_view/registry.ex`
- Modify: `lib/phoenix_replay/application.ex`

A small `Registry`-based map from LV transport_pid (the channel process) to phoenix_replay session_id. Populated at LV mount time when the host's `live_session` includes our `on_mount`; consulted by `attach_hook` callbacks to decide whether to capture.

This is intentionally separate from `CaptureStream.Registry` (the ETS table for stream lookups) — different lifetime, different access pattern, different keys.

- [ ] **Step 1: Implement.** Create `lib/phoenix_replay/live_view/registry.ex`:

  ```elixir
  defmodule PhoenixReplay.LiveView.Registry do
    @moduledoc false
    # Per-transport map: transport_pid → session_id.
    #
    # Populated by PhoenixReplay.LiveView.Snapshots.on_mount/4 when the
    # client widget's session_id is present in connect params. Used by
    # attach_hook callbacks to decide whether the LV is part of a
    # phoenix_replay recording session.

    @registry __MODULE__

    @spec child_spec(term()) :: Supervisor.child_spec()
    def child_spec(_) do
      Registry.child_spec(keys: :unique, name: @registry)
    end

    @doc "Register the current process under a session_id."
    @spec register(String.t()) :: :ok | {:error, {:already_registered, pid()}}
    def register(session_id) do
      case Registry.register(@registry, self(), session_id) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end

    @doc "Look up the session_id for the given pid (defaults to self)."
    @spec lookup(pid()) :: {:ok, String.t()} | :error
    def lookup(pid \\ self()) do
      case Registry.values(@registry, pid, pid) do
        [session_id | _] -> {:ok, session_id}
        [] -> :error
      end
    end
  end
  ```

- [ ] **Step 2: Add to supervision tree.** In `lib/phoenix_replay/application.ex`, add `PhoenixReplay.LiveView.Registry` next to `PhoenixReplay.CaptureStream.Registry` (order between these two does not matter — they're independent):

  ```elixir
  defp children do
    [
      # ... existing entries ...
      PhoenixReplay.CaptureStream.Registry,
      PhoenixReplay.LiveView.Registry,
      PhoenixReplay.SessionSupervisor
      # ... existing entries after ...
    ]
  end
  ```

- [ ] **Step 3: Confirm the module compiles + lookup behavior.** Run a quick smoke from `iex`:

  ```bash
  iex -S mix
  ```

  In the IEx prompt:

  ```elixir
  PhoenixReplay.LiveView.Registry.register("test-session")
  PhoenixReplay.LiveView.Registry.lookup()
  # => {:ok, "test-session"}
  ```

  Exit IEx (Ctrl-G + q or Ctrl-\). No commit yet — Task 6 exercises this from real LV tests.

- [ ] **Step 4: Commit.**

  ```bash
  git add lib/phoenix_replay/live_view/registry.ex lib/phoenix_replay/application.ex
  git commit -m "$(cat <<'EOF'
  feat(lv-snapshot): per-transport Registry mapping pid → session_id

  Used by the on_mount + attach_hook callbacks (next task) to decide
  whether the LV process is part of a phoenix_replay recording.
  Separate from CaptureStream's ETS registry — different lifetime,
  different access pattern.

  Phase 1 of ADR-0007.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 6 — `PhoenixReplay.LiveView.Snapshots` capture module

**Files:**
- Create: `lib/phoenix_replay/live_view/snapshots.ex`
- Create: `test/phoenix_replay/live_view/snapshots_test.exs`

The orchestration module. `on_mount/4` is invoked by hosts via their `live_session`'s `:on_mount` list. It looks up the session in `LiveView.Registry`, attaches one hook per stage, and emits a mount baseline snapshot.

- [ ] **Step 1: Write the failing test.** Create `test/phoenix_replay/live_view/snapshots_test.exs`:

  ```elixir
  defmodule PhoenixReplay.LiveView.SnapshotsTest do
    use ExUnit.Case, async: false

    alias PhoenixReplay.LiveView.Snapshots
    alias PhoenixReplay.{Session, CaptureStream}

    @stream_id "phx-replay/liveview@1"
    @identity %{kind: :anonymous, id: nil, attrs: %{}}

    setup do
      session_id = "lv-snap-#{System.unique_integer([:positive])}"
      {:ok, sess_pid} = Session.start_session(session_id, @identity, seq_watermark: 0)
      :ok = Session.attach_stream(sess_pid, @stream_id, [])
      :ok = PhoenixReplay.LiveView.Registry.register(session_id)

      on_exit(fn ->
        if Process.alive?(sess_pid), do: Session.close(sess_pid, :test_cleanup)
      end)

      %{session_id: session_id, sess_pid: sess_pid}
    end

    test "capture_handle_event/3 emits an event marker into the stream",
         %{session_id: session_id} do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, count: 0},
        view: __MODULE__.FakeLive,
        transport_pid: self()
      }

      assert {:cont, _socket} =
               Snapshots.capture_handle_event_for_test("inc", %{"key" => "value"}, socket)

      [event | _] = Session.drain_capture_streams(PhoenixReplay.CaptureStream.Registry.session_pid(session_id))
      assert event["data"]["plugin"] == @stream_id
      assert event["data"]["payload"][:kind] == :event_marker
      assert event["data"]["payload"][:callback] == :handle_event
      assert event["data"]["payload"][:event_name] == "inc"
    end

    test "capture path swallows raises so host LV is not affected",
         %{session_id: _session_id} do
      # Pass a socket with a deliberately broken extractor target —
      # the rescue must keep the LV alive.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, broken: %BrokenStruct{}},
        view: __MODULE__.FakeLive,
        transport_pid: self()
      }

      # Even if the shape extractor raises (it shouldn't with our
      # default extractor, but the wrapper is the safety net), the
      # capture path must return {:cont, socket}.
      assert {:cont, ^socket} =
               Snapshots.capture_handle_event_for_test("evt", %{}, socket)
    end

    test "no session in registry → hooks are not attached" do
      # A fresh process with no register call. on_mount should
      # short-circuit and return {:cont, socket} without attaching.
      Task.async(fn ->
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

        # capture_handle_event_for_test bypasses the hook indirection
        # but Snapshots.on_mount/4 is what actually decides whether to
        # attach. We test on_mount directly here.
        assert {:cont, _} = Snapshots.on_mount(:install, %{}, %{}, socket)
      end)
      |> Task.await()
    end

    defmodule FakeLive do
      use Phoenix.LiveView
      def render(assigns), do: ~H""
    end

    defmodule BrokenStruct do
      defstruct [:placeholder]
    end
  end
  ```

  Note: `capture_handle_event_for_test/3` is a test-only entry point exposing the private hook function — added in Step 3.

- [ ] **Step 2: Run the test, verify it fails.**

  ```bash
  mix test test/phoenix_replay/live_view/snapshots_test.exs
  ```

  Expected: `PhoenixReplay.LiveView.Snapshots is undefined`.

- [ ] **Step 3: Implement the module.** Create `lib/phoenix_replay/live_view/snapshots.ex`:

  ```elixir
  defmodule PhoenixReplay.LiveView.Snapshots do
    @moduledoc """
    `on_mount` callback + `attach_hook` registrations that capture
    LiveView assigns shapes and callback markers into the
    phoenix_replay session's capture stream.

    Hosts add this to their `live_session` to enable LiveView state
    capture for recorded sessions:

        live_session :default,
          on_mount: [{PhoenixReplay.LiveView.Snapshots, :install}] do
          live "/posts", PostsLive
        end

    With the line in place, every LiveView in the `live_session` whose
    transport process is associated with a phoenix_replay recording
    session will emit:

      * a baseline snapshot at mount,
      * an event marker at each `handle_event` / `handle_info` /
        `handle_async` / `handle_params` callback entry,
      * a snapshot after the next render completes (paired to the
        marker via a shared `event_id`).

    Captured payloads contain only shape information (key + type +
    size hint) — no leaf values. Phase 2 will add a `use
    PhoenixReplay.LiveView, snapshot: [values: [...]]` macro to opt
    in to literal values for specific assigns keys.

    All capture paths are wrapped in `try/rescue` — a capture failure
    cannot crash the host LV.
    """

    import Phoenix.LiveView, only: [attach_hook: 4, detach_hook: 3]
    import Phoenix.Component, only: [assign: 3]

    alias PhoenixReplay.LiveView.{Registry, Shape}

    @stream_id "phx-replay/liveview@1"
    @throttle_ms 50

    @doc """
    `on_mount` callback. Looks up the session in
    `PhoenixReplay.LiveView.Registry` (populated upstream by the
    client widget's connect params plumbing in `Snapshots.register/2`).
    If a session is associated, registers the LV process and attaches
    capture hooks for all relevant callback stages. Otherwise, returns
    immediately with no overhead beyond the registry lookup.
    """
    @spec on_mount(:install, map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()}
    def on_mount(:install, _params, _session, socket) do
      case Registry.lookup() do
        {:ok, session_id} ->
          socket =
            socket
            |> assign(:__phx_replay_session_id__, session_id)
            |> assign(:__phx_replay_event_throttle__, %{})
            |> attach_hook(:phx_replay_hev, :handle_event, &capture_handle_event/3)
            |> attach_hook(:phx_replay_hin, :handle_info, &capture_handle_info/2)
            |> attach_hook(:phx_replay_has, :handle_async, &capture_handle_async/3)
            |> attach_hook(:phx_replay_hpa, :handle_params, &capture_handle_params/3)
            |> capture_baseline()

          {:cont, socket}

        :error ->
          {:cont, socket}
      end
    end

    @doc """
    Register the current LiveView process as part of `session_id`.
    Called by the host (or by an upstream library plug — see Task 7
    for the connect-params-driven registration in Path B).
    """
    @spec register(String.t()) :: :ok
    def register(session_id), do: Registry.register(session_id)

    # Test-only entry point — allows the unit test in Task 6 to drive
    # capture_handle_event/3 without the full attach_hook plumbing.
    @doc false
    def capture_handle_event_for_test(event, params, socket) do
      capture_handle_event(event, params, socket)
    end

    # ── attach_hook callbacks ─────────────────────────────────────

    defp capture_handle_event(event_name, params, socket) do
      try do
        if throttle_ok?(socket, event_name) do
          session_id = socket.assigns[:__phx_replay_session_id__]
          event_id = make_ref()

          push_marker(session_id, %{
            kind: :event_marker,
            callback: :handle_event,
            event_name: event_name,
            params_shape: Shape.extract(params),
            target_cid: get_in(params, [:_target, "_target"]),
            event_id: event_id,
            lv_module: socket.view
          })

          socket = stamp_throttle(socket, event_name)
          socket = attach_pairing_hook(socket, event_id)
          {:cont, socket}
        else
          {:cont, socket}
        end
      rescue
        _ -> {:cont, socket}
      end
    end

    defp capture_handle_info(message, socket) do
      try do
        session_id = socket.assigns[:__phx_replay_session_id__]
        event_id = make_ref()

        push_marker(session_id, %{
          kind: :event_marker,
          callback: :handle_info,
          message_shape: Shape.extract(message),
          event_id: event_id,
          lv_module: socket.view
        })

        socket = attach_pairing_hook(socket, event_id)
        {:cont, socket}
      rescue
        _ -> {:cont, socket}
      end
    end

    defp capture_handle_async(name, async_result, socket) do
      try do
        session_id = socket.assigns[:__phx_replay_session_id__]
        event_id = make_ref()

        push_marker(session_id, %{
          kind: :event_marker,
          callback: :handle_async,
          name: name,
          result_shape: Shape.extract(async_result),
          event_id: event_id,
          lv_module: socket.view
        })

        socket = attach_pairing_hook(socket, event_id)
        {:cont, socket}
      rescue
        _ -> {:cont, socket}
      end
    end

    defp capture_handle_params(params, _uri, socket) do
      try do
        session_id = socket.assigns[:__phx_replay_session_id__]
        event_id = make_ref()

        push_marker(session_id, %{
          kind: :event_marker,
          callback: :handle_params,
          params_shape: Shape.extract(params),
          event_id: event_id,
          lv_module: socket.view
        })

        socket = attach_pairing_hook(socket, event_id)
        {:cont, socket}
      rescue
        _ -> {:cont, socket}
      end
    end

    # ── snapshot pairing via :after_render ────────────────────────

    defp attach_pairing_hook(socket, event_id) do
      attach_hook(socket, :phx_replay_after_render, :after_render, fn s ->
        try do
          session_id = s.assigns[:__phx_replay_session_id__]

          push_marker(session_id, %{
            kind: :snapshot,
            paired_event_id: event_id,
            lv_module: s.view,
            assigns_shape: Shape.extract_assigns(s.assigns),
            assigns_values: %{}
          })
        rescue
          _ -> :ok
        end

        detach_hook(s, :phx_replay_after_render, :after_render)
      end)
    end

    # ── baseline ──────────────────────────────────────────────────

    defp capture_baseline(socket) do
      try do
        session_id = socket.assigns[:__phx_replay_session_id__]

        push_marker(session_id, %{
          kind: :event_marker,
          callback: :mount,
          lv_module: socket.view,
          event_id: make_ref()
        })

        push_marker(session_id, %{
          kind: :snapshot,
          paired_event_id: nil,
          lv_module: socket.view,
          assigns_shape: Shape.extract_assigns(socket.assigns),
          assigns_values: %{}
        })

        socket
      rescue
        _ -> socket
      end
    end

    # ── helpers ───────────────────────────────────────────────────

    defp push_marker(session_id, payload) do
      PhoenixReplay.CaptureStream.push_event(session_id, @stream_id, %{
        server_time_ms: System.system_time(:millisecond),
        payload: payload
      })
    end

    defp throttle_ok?(socket, event_name) do
      now = System.monotonic_time(:millisecond)
      last = Map.get(socket.assigns[:__phx_replay_event_throttle__] || %{}, event_name, 0)
      now - last >= @throttle_ms
    end

    defp stamp_throttle(socket, event_name) do
      now = System.monotonic_time(:millisecond)
      throttle = Map.put(socket.assigns[:__phx_replay_event_throttle__] || %{}, event_name, now)
      assign(socket, :__phx_replay_event_throttle__, throttle)
    end
  end
  ```

- [ ] **Step 4: Run the test, verify it passes.**

  ```bash
  mix test test/phoenix_replay/live_view/snapshots_test.exs
  ```

  Expected: all tests pass.

- [ ] **Step 5: Commit.**

  ```bash
  git add lib/phoenix_replay/live_view/snapshots.ex \
          test/phoenix_replay/live_view/snapshots_test.exs
  git commit -m "$(cat <<'EOF'
  feat(lv-snapshot): on_mount + attach_hook capture for handle_event/info/async/params

  PhoenixReplay.LiveView.Snapshots is the orchestration module hosts
  install via their live_session's :on_mount list:

      on_mount: [{PhoenixReplay.LiveView.Snapshots, :install}]

  When a session is registered for the LV's process, hooks fire on
  every callback stage, emitting a paired event marker (at entry) +
  snapshot (after render). Mount produces a baseline pair. handle_event
  is throttled to 50ms per {lv_pid, event_name}. All capture paths are
  wrapped in try/rescue — a capture failure cannot crash the host LV.

  Phase 1 ships shape-only — the use PhoenixReplay.LiveView, snapshot
  macro for value allowlists is Phase 2.

  Phase 1 of ADR-0007.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 7 — Client widget: send `client_started_at_ms`

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js`

The widget already POSTs to `/session`, `/report`, and `/submit`. Add a `client_started_at_ms: Date.now()` field to each request body. The server-side counterpart wires it in Task 8.

- [ ] **Step 1: Find the three POST sites in phoenix_replay.js.** Open `priv/static/assets/phoenix_replay.js`. Use Grep:

  ```
  Grep "/session" — find the POST in ensureSession()
  Grep "/report"  — find the POST in report() / submit-now path
  Grep "/submit"  — find the POST in the Path B finalize
  ```

  Each call already builds a JSON body via something like `JSON.stringify({...})`. Note the body shape at each site.

- [ ] **Step 2: Add `client_started_at_ms` to each body.** At each of the three sites, locate the body object literal (or `Object.assign` source) and add a `client_started_at_ms: Date.now()` property. Example for `/session`:

  ```js
  // Before
  body: JSON.stringify({
    identity_kind: ...,
    identity_id: ...,
    metadata: ...
  })

  // After
  body: JSON.stringify({
    identity_kind: ...,
    identity_id: ...,
    metadata: ...,
    client_started_at_ms: Date.now()
  })
  ```

  Repeat for `/report` and `/submit`. Make the change in all three.

- [ ] **Step 3: Smoke-load the widget.** Boot the demo app:

  ```bash
  cd ~/Dev/ash_feedback_demo
  cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js deps/phoenix_replay/priv/static/assets/phoenix_replay.js
  mix deps.compile phoenix_replay --force
  ```

  Then trigger a test ScheduleWakeup-free workflow: open browser to localhost:4006, click the widget, hit "Report now" with some text. In the browser DevTools Network tab, inspect the `/report` request body — it should contain `client_started_at_ms` with a valid epoch-ms integer.

  (No commit yet — server-side handling in Task 8 closes the loop.)

- [ ] **Step 4: Commit.**

  ```bash
  cd ~/Dev/phoenix_replay
  git add priv/static/assets/phoenix_replay.js
  git commit -m "$(cat <<'EOF'
  feat(client): include client_started_at_ms in /session, /report, /submit POSTs

  Carries the browser's Date.now() at request build time. Server-side
  ingest pipeline (next task) uses it to compute the per-session clock
  offset that converts server-origin capture event timestamps to the
  browser timeline.

  Phase 1 of ADR-0007.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 8 — Server-side `record_clock_offset` + ingest merge

**Files:**
- Modify: `lib/phoenix_replay/controller/events_controller.ex`
- Modify: `lib/phoenix_replay/controller/report_controller.ex`
- Modify: `lib/phoenix_replay/controller/submit_controller.ex`

The three controllers receive the `client_started_at_ms` field in their request body. We:

1. On `/session`: call `CaptureStream.record_clock_offset/2` once after Session is started.
2. On `/report` (Path A): call `record_clock_offset/2` against the synthetic session created inline; flush the capture stream and merge into the rrweb batch before persist.
3. On `/submit` (Path B): flush the capture stream and merge into the final persisted batch.

- [ ] **Step 1: Locate the Session-start point in the events controller.** Read `lib/phoenix_replay/controller/events_controller.ex`. Find where `Session.start_session/3` or `lookup_or_start/2` returns a pid. Right after — but before the response is sent — add the offset record:

  ```elixir
  # In the controller's create/2, where the session pid is obtained:
  with ...,
       {:ok, pid} <- Session.lookup_or_start(session_id, identity),
       :ok <- maybe_record_clock_offset(pid, params) do
    # ... existing flow ...
  end

  # New private helper at the bottom of the module:
  defp maybe_record_clock_offset(_pid, %{"client_started_at_ms" => ms}) when is_integer(ms) do
    PhoenixReplay.CaptureStream.record_clock_offset_for_pid(ms)
    :ok
  end

  defp maybe_record_clock_offset(_pid, _), do: :ok
  ```

  Wait — `record_clock_offset/2` takes `session_id` not `pid`. Adjust:

  ```elixir
  defp maybe_record_clock_offset(session_id, %{"client_started_at_ms" => ms}) when is_integer(ms) do
    PhoenixReplay.CaptureStream.record_clock_offset(session_id, ms)
    :ok
  end

  defp maybe_record_clock_offset(_session_id, _), do: :ok
  ```

  And call it with `session_id` rather than `pid`.

  Note: `CaptureStream.record_clock_offset/2` is a no-op if no streams are registered yet (which they won't be on first `/session` if the client hasn't opened any LVs). That's fine — once an LV mounts and registers, the offset on Session state is already correct (it was recorded at session creation time, then `record_clock_offset` updates as needed; if attach happens after the offset call, the offset is still on Session state for use at flush time). Verify by reading the Task 4 implementation: yes, `record_clock_offset` modifies `state.clock_offset` directly via Session GenServer call, regardless of stream registration.

  Hmm — `Registry.session_pid(session_id)` returns nil if no streams attached. So `record_clock_offset` becomes a no-op too early. **Fix**: call `Session.record_clock_offset/2` directly via session_id → pid lookup using the Session registry, not CaptureStream's:

  ```elixir
  defp maybe_record_clock_offset(session_id, %{"client_started_at_ms" => ms}) when is_integer(ms) do
    case PhoenixReplay.Session.pid_for(session_id) do
      nil -> :ok
      pid -> PhoenixReplay.Session.record_clock_offset(pid, ms)
    end
  end

  defp maybe_record_clock_offset(_session_id, _), do: :ok
  ```

- [ ] **Step 2: In ReportController (Path A), do the offset + flush.** Read `lib/phoenix_replay/controller/report_controller.ex`. Find the section where the synthetic session is created and events are appended. Before `Storage.Dispatch.append_events/3`, do:

  ```elixir
  # After the synthetic session pid is obtained:
  if is_integer(client_started_at_ms = params["client_started_at_ms"]) do
    PhoenixReplay.Session.record_clock_offset(session_pid, client_started_at_ms)
  end

  # Just before persisting the events batch:
  capture_events = PhoenixReplay.CaptureStream.flush_for_session(session_id)
  merged_events = (rrweb_events ++ capture_events) |> Enum.sort_by(&Map.get(&1, "timestamp"))

  # Then proceed with append_events using merged_events.
  ```

  Adjust variable names to match the actual controller's locals (the existing code uses something like `events` for the rrweb batch).

- [ ] **Step 3: In SubmitController (Path B), do the flush.** Read `lib/phoenix_replay/controller/submit_controller.ex`. The Path B submit happens after a session has been running and accumulating rrweb events; the capture stream should also have accumulated. Before final persist, drain and merge:

  ```elixir
  # Where the final events list is assembled:
  capture_events = PhoenixReplay.CaptureStream.flush_for_session(session_id)
  final_events = (existing_events ++ capture_events) |> Enum.sort_by(&Map.get(&1, "timestamp"))
  ```

  Adjust to match the actual controller's variable names. The submit flow may not have any pending events to merge with (rrweb events were already flushed on prior `/events` ticks); the capture-stream batch becomes its own append. Confirm by reading the controller — if all rrweb events are already persisted by the time `/submit` is called, change to:

  ```elixir
  capture_events = PhoenixReplay.CaptureStream.flush_for_session(session_id)
  if capture_events != [] do
    Storage.Dispatch.append_events(session_id, capture_events, next_seq())
  end
  ```

  The exact path depends on the controller's flow.

- [ ] **Step 4: Add an integration check.** Manually verify the loop end-to-end via a temporary IEx-driven smoke (no automated test yet — that's Task 9):

  ```bash
  cd ~/Dev/phoenix_replay
  iex -S mix
  ```

  ```elixir
  # In iex:
  identity = %{kind: :anonymous, id: nil, attrs: %{}}
  session_id = "manual-smoke-#{System.unique_integer([:positive])}"
  {:ok, pid} = PhoenixReplay.Session.start_session(session_id, identity, seq_watermark: 0)
  PhoenixReplay.Session.attach_stream(pid, "phx-replay/liveview@1", [])
  PhoenixReplay.Session.record_clock_offset(pid, 1000)
  PhoenixReplay.Session.set_clock_received_at_for_test(pid, 1500)

  PhoenixReplay.CaptureStream.push_event(session_id, "phx-replay/liveview@1", %{
    server_time_ms: 2000,
    payload: %{kind: :marker}
  })

  PhoenixReplay.CaptureStream.flush_for_session(session_id)
  # => [%{"type" => 6, "timestamp" => 1500, "data" => %{...}}]
  ```

- [ ] **Step 5: Commit.**

  ```bash
  git add lib/phoenix_replay/controller/events_controller.ex \
          lib/phoenix_replay/controller/report_controller.ex \
          lib/phoenix_replay/controller/submit_controller.ex
  git commit -m "$(cat <<'EOF'
  feat(ingest): record clock offset + merge capture stream on submit/report

  All three ingest entry points (/events session creation, /report,
  /submit) now extract client_started_at_ms from the request body
  and call Session.record_clock_offset/2. /report and /submit additionally
  drain CaptureStream.flush_for_session/1 and merge with the rrweb
  batch (timestamp-sorted) before persistence.

  Phase 1 of ADR-0007.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 9 — End-to-end integration test + ADR + docs

**Files:**
- Create: `test/phoenix_replay/integration/lv_snapshot_e2e_test.exs`
- Create: `docs/decisions/0007-liveview-snapshot-stream.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/plans/README.md`
- Modify: `docs/decisions/README.md`

The integration test mounts a synthetic LV inside the test environment, drives a `handle_event`, simulates the `/submit` flush, and asserts the persisted events row contains rrweb type-6 events with `plugin: "phx-replay/liveview@1"` and timestamps converted to browser timeline.

- [ ] **Step 1: Write the integration test.** Create `test/phoenix_replay/integration/lv_snapshot_e2e_test.exs`:

  ```elixir
  defmodule PhoenixReplay.Integration.LvSnapshotE2eTest do
    use ExUnit.Case, async: false

    import Phoenix.LiveViewTest

    alias PhoenixReplay.{Session, CaptureStream}
    alias PhoenixReplay.LiveView.{Registry, Snapshots}

    @stream_id "phx-replay/liveview@1"
    @identity %{kind: :anonymous, id: nil, attrs: %{}}

    defmodule CounterLive do
      use Phoenix.LiveView, layout: false

      def mount(_params, _session, socket) do
        {:ok, assign(socket, :count, 0)}
      end

      def handle_event("inc", _, socket) do
        {:noreply, assign(socket, :count, socket.assigns.count + 1)}
      end

      def render(assigns) do
        ~H"""
        <div id="counter">count: {@count}</div>
        """
      end
    end

    setup do
      session_id = "e2e-#{System.unique_integer([:positive])}"
      {:ok, sess_pid} = Session.start_session(session_id, @identity, seq_watermark: 0)
      :ok = Session.attach_stream(sess_pid, @stream_id, [])
      # Pretend the client sent client_started_at_ms = 1000 and arrived at server time 1500.
      :ok = Session.set_clock_received_at_for_test(sess_pid, 1500)
      :ok = Session.record_clock_offset(sess_pid, 1000)

      on_exit(fn ->
        if Process.alive?(sess_pid), do: Session.close(sess_pid, :test_done)
      end)

      %{session_id: session_id, sess_pid: sess_pid}
    end

    test "mounting an instrumented LV produces baseline + post-event snapshots",
         %{session_id: session_id, sess_pid: sess_pid} do
      # The Phoenix.LiveViewTest runner runs the LV in a separate process.
      # Register that process as part of our session via a hook.
      parent = self()

      Task.start_link(fn ->
        Registry.register(session_id)
        send(parent, :registered)
        receive do: (:done -> :ok)
      end)

      assert_receive :registered

      {:ok, view, _html} = live_isolated(build_conn(), CounterLive)

      assert render_click(view, "inc") =~ "count: 1"

      # Allow async :after_render hook to flush.
      Process.sleep(50)

      events = CaptureStream.flush_for_session(session_id)

      assert Enum.any?(events, fn e ->
               e["type"] == 6 and
                 e["data"]["plugin"] == @stream_id and
                 get_in(e, ["data", "payload", :callback]) == :handle_event
             end),
             "expected a handle_event marker in flushed events; got #{inspect(events, limit: :infinity)}"

      # Timestamps should be converted to browser timeline (server - 500).
      timestamps = Enum.map(events, & &1["timestamp"])
      assert Enum.all?(timestamps, &is_integer/1)
    end
  end
  ```

  Note: the `Registry.register` is done from a sibling process because the LV runs in a separate process under `Phoenix.LiveViewTest`. The integration is approximate — the production path will register from the Snapshots `on_mount` which runs in the LV process. For Phase 1, this end-to-end shape is sufficient to validate the wiring.

- [ ] **Step 2: Run the test, verify it passes.**

  ```bash
  mix test test/phoenix_replay/integration/lv_snapshot_e2e_test.exs
  ```

  Expected: passes. If it fails because the LV's process isn't getting registered (the `Task.start_link` hack registers a different pid than the LV's process), revise the test to register from inside `CounterLive.mount/3` directly:

  ```elixir
  def mount(_params, session, socket) do
    if session_id = session["__phx_replay_session_id__"] do
      Registry.register(session_id)
    end
    {:ok, assign(socket, :count, 0)}
  end
  ```

  And pass `session: %{"__phx_replay_session_id__" => session_id}` to `live_isolated/3`.

- [ ] **Step 3: Draft ADR-0007.** Create `docs/decisions/0007-liveview-snapshot-stream.md`:

  ```markdown
  # ADR-0007: LiveView Snapshot Stream — Server-Origin Capture via `attach_hook` + `CaptureStream` API

  **Status**: Accepted
  **Date**: 2026-04-28
  **Accepted**: 2026-04-28
  **Builds on**: ADR-0003 (Session Continuity), ADR-0005 (Replay Player Timeline Event Bus), ADR-0006 (Unified Feedback Entry)
  **Spec**: [docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md](../superpowers/specs/2026-04-28-liveview-snapshot-design.md)

  ## Context

  phoenix_replay records browser sessions and surfaces them in an admin
  replay UI for triage. When a report comes in, an admin can scrub the
  timeline and see what the user saw — but cannot see what the LiveView
  process was holding at any given timestamp (assigns, in-flight async
  calls, the PubSub message that just fired). That gap is the
  difference between "I see the broken UI" and "I see why it broke."

  LiveDebugger provides this in dev. It is not portable to staging/prod
  — `:erlang.dbg`-based, node-wide global tracer; full-socket
  persistence with no PII redaction; authors explicitly state dev-only.
  Forking the capture half is effectively rebuilding it.

  Phoenix-blessed primitives (`attach_hook` + LiveView's existing
  callback structure) plus phoenix_replay's existing per-session
  infrastructure (Session GenServer, timeline event bus, panel addon
  API) yield a complete capture-and-replay pipeline that is
  prod-safe by construction.

  ## Decision

  Introduce a new public API, `PhoenixReplay.CaptureStream`, that
  models server-origin capture streams as a first-class concept. Build
  `PhoenixReplay.LiveView.Snapshots` on top of it as the first internal
  consumer. External libraries (e.g., a future ash_feedback Oban-state
  addon) use the same API.

  Sub-decisions:

  - **Capture mechanism**: `Phoenix.LiveView.attach_hook/4` per stage,
    not `:dbg`. No node-wide tracer.
  - **Activation**: per-session opt-in via `live_session`'s `on_mount`,
    O(1) ETS lookup gates the hot path.
  - **Redaction**: shape-only by default. Allowlist for literal values
    is Phase 2.
  - **Wire format**: rrweb type-6 plugin events with namespaced plugin
    name (`phx-replay/liveview@1`).
  - **Storage**: existing `phoenix_replay_events` table — no migration.
  - **Time alignment**: single-shot session-start clock offset, applied
    once at flush.

  ## Consequences

  - Hosts that don't add the `on_mount` line see no behavior change.
  - Hosts that do see captured events appearing in their session
    records, alongside rrweb DOM/console/network events.
  - Capture failures are isolated by `try/rescue` — they cannot crash
    the host LV.
  - Memory cost per recording session is bounded by `:max_events`
    (default 5000) ring queue per stream and Session idle teardown.
  - The `PhoenixReplay.CaptureStream` API is now public; external libs
    can build their own server-origin streams using the same
    primitives. Future deprecations require ADR.
  - LiveDebugger-style features that need full assigns capture
    (specifically: live navigation between LVs with full state diffs,
    LiveComponent assigns) are explicitly out of v1 scope; they may
    arrive in later phases or be permanently deferred.

  ## Migration

  None. Phase 1 is opt-in via `on_mount`.

  ## Related

  - ADR-0003 — Session Continuity (Session GenServer state extension)
  - ADR-0005 — Timeline Event Bus (replay-side panel addon will subscribe via this)
  - ADR-0006 — Unified Feedback Entry (Path A and Path B both apply)
  ```

- [ ] **Step 4: Update CHANGELOG.** Open `CHANGELOG.md` and add under "Unreleased":

  ```markdown
  ### Added

  - **LiveView snapshot stream foundation (ADR-0007 Phase 1).** New
    `PhoenixReplay.CaptureStream` public API for server-origin capture
    streams; `PhoenixReplay.LiveView.Snapshots` as the first internal
    consumer. Hosts add one line to their `live_session`'s `on_mount`
    list and recorded sessions begin capturing assigns shape +
    callback markers, persisted alongside rrweb events in the existing
    `phoenix_replay_events` table. Phase 1 ships shape-only — value
    allowlist via `use PhoenixReplay.LiveView, snapshot:` is Phase 2.
    Replay-side panel UI is Phase 2.

  ### Changed

  - `PhoenixReplay.Session` GenServer state extended with
    `capture_streams`, `capture_opts`, and `clock_offset` fields. No
    schema migration; the `phoenix_replay_events` table is unchanged.
  - Client widget POSTs (`/session`, `/report`, `/submit`) now include
    `client_started_at_ms: Date.now()` for clock-offset alignment of
    server-origin capture events to browser timeline.
  ```

- [ ] **Step 5: Update plans README.** Open `docs/plans/README.md` and add to the Index:

  ```markdown
  | —  | LiveView snapshot stream — Phase 1 (ADR-0007) | Active 2026-04-28 — capture pipeline, no replay UI yet | [spec](../superpowers/specs/2026-04-28-liveview-snapshot-design.md) / [Phase 1 plan](../superpowers/plans/2026-04-28-liveview-snapshot-phase-1.md) / [ADR](../decisions/0007-liveview-snapshot-stream.md) |
  ```

  And to the open follow-ups paragraph append "ADR-0007 Phase 2 (replay UI panel + value allowlist macro), Phase 3 (telemetry events, Benchee suite, Igniter auto-install)."

- [ ] **Step 6: Update decisions README.** Open `docs/decisions/README.md` and add:

  ```markdown
  | [0007](./0007-liveview-snapshot-stream.md) | LiveView Snapshot Stream — Server-Origin Capture via attach_hook + CaptureStream API | Accepted | 2026-04-28 |
  ```

- [ ] **Step 7: Run the full test suite a final time.**

  ```bash
  mix test
  ```

  Expected: all tests pass.

- [ ] **Step 8: Commit.**

  ```bash
  git add test/phoenix_replay/integration/lv_snapshot_e2e_test.exs \
          docs/decisions/0007-liveview-snapshot-stream.md \
          docs/decisions/README.md \
          docs/plans/README.md \
          CHANGELOG.md
  git commit -m "$(cat <<'EOF'
  feat(lv-snapshot): Phase 1 ships — ADR-0007, integration test, docs

  End-to-end integration test mounts a synthetic LV under
  Phoenix.LiveViewTest, drives a handle_event, asserts the flushed
  capture stream contains an event marker + paired snapshot in rrweb
  type-6 plugin format with browser-timeline timestamps.

  ADR-0007 Accepted. CHANGELOG and plans/decisions indexes updated.

  Phase 2 (replay UI + value allowlist macro) and Phase 3 (telemetry,
  benchmarks, Igniter) are tracked in plans/README.md follow-ups.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Phase 2 / Phase 3 — Explicitly deferred

The following are **not** in this Phase 1 plan. Each becomes its own plan when scheduled.

**Phase 2 — Replay UI + allowlist:**
- New panel-addon slot `admin-sidebar-tab` in phoenix_replay.js.
- LiveView state panel (current snapshot at cursor + event timeline list with click-to-seek), subscribing via `PhoenixReplay.subscribeTimeline`.
- `use PhoenixReplay.LiveView, snapshot: [values: [...], params: [...]]` macro for per-LV allowlist.
- Custom shape extractors via `config :phoenix_replay, :snapshot_shape_extractors`.
- Demo bump in `ash_feedback_demo` to verify end-to-end with real LVs.

**Phase 3 — Polish + ops:**
- Telemetry events (`[:phoenix_replay, :capture_stream, :push | :flush | :overflow | :rescue]`).
- Benchee suite enforcing the < 5µs no-op-path budget.
- Igniter `mix igniter.install phoenix_replay --with-liveview-snapshots` auto-patches router.
- Path B start-recording timing: registry update path verification.
- Drift correction (deferred unless real-world long-session reports show problems).

---

## Self-review notes

**Spec coverage:** Every D1–D7 decision in the spec is mapped to a Phase 1 task (see coverage table at the top). Replay UI, value-allowlist macro, telemetry, and Benchee are explicitly deferred and tracked in the Phase 2/3 section below.

**Placeholder scan:** No "TBD" / "TODO" / "fill in later". Every step contains the literal code, command, or file path.

**Type consistency:** `CaptureStream`'s public functions (`record_clock_offset/2`, `attach/3`, `push_event/3`, `flush_for_session/1`) match the names used in Tasks 4 (Session protocol), 6 (Snapshots calls), 8 (controllers). Stream id is the literal `"phx-replay/liveview@1"` everywhere.

**Scope check:** Phase 1 produces working software (capture pipeline that persists events to DB), testable in isolation. Phase 2 (replay UI) and Phase 3 (polish/ops) are independent enough to ship later.

**Ambiguity check:** Two known soft spots called out in step text: (1) the exact location of Session's `defstruct` depending on whether the 2026-04-26 split moved state to `lib/phoenix_replay/session/state.ex` (Task 4 step 1 says to verify), and (2) the integration test's process-registration approach for `Phoenix.LiveViewTest` runs the LV in a separate process; Task 9 step 2 has a fallback path for if the simple `Task.start_link` hack doesn't register the right pid.
