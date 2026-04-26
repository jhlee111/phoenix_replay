# ADR-0006 Phase 2b — `/report` Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four production-blocker follow-ups deferred from
ADR-0006 Phase 1 (F1, F3, F4, F9 in
`docs/superpowers/specs/2026-04-25-unified-feedback-entry-design.md`):
sanitize 422/500 error bodies, add a body-size cap on `POST /report`,
add per-actor rate limiting on `POST /report`, and lock in the
metadata merge order with regression tests.

**Architecture:** All four follow-ups live entirely on the server side
in `lib/phoenix_replay/controller/{report,submit}_controller.ex` plus
two small additions to `lib/phoenix_replay/config.ex` documentation.
A new `PhoenixReplay.ChangesetErrors` module replaces `inspect/1`
calls in both controllers' 422 responses. Body-size and actor-rate
checks on `/report` mirror the existing `EventsController` patterns
exactly (same `Config.limits/0` lookup pattern, same `RateLimiter.hit/3`
key shape — but with distinct keys so `/events` traffic does not consume
`/report` quota and vice versa). F9 is verify-only (the merge order
is already correct: `client |> stringify |> Map.merge(stringify(host))`
makes host win on collision in both controllers) — covered by twin
regression tests, no production code change.

**Tech Stack:** Elixir 1.18, Phoenix.Controller, Plug.Conn,
Ecto.Changeset, ExUnit, the existing in-house `PhoenixReplay.RateLimiter`
ETS-backed counter and `PhoenixReplay.Config` keyword-list runtime
lookup.

**Execution location:** Plan executes in `~/Dev/phoenix_replay`. The
ash_feedback_demo host is **not** modified (Phase 2b is purely a
phoenix_replay-internal hardening pass). After commit + push, the demo
picks up the new SHA via `mix deps.update phoenix_replay`.

---

## File Structure

| Path | Role | New / Modify |
|---|---|---|
| `lib/phoenix_replay/changeset_errors.ex` | Single-purpose changeset → JSON-friendly map serializer used by `/report` and `/submit` 422 responses | New |
| `lib/phoenix_replay/controller/report_controller.ex` | Adds `check_body_size/2` + `check_actor_rate/2`, swaps `inspect(changeset)` → `ChangesetErrors.serialize/1` | Modify |
| `lib/phoenix_replay/controller/submit_controller.ex` | Swaps `inspect(changeset)` → `ChangesetErrors.serialize/1` (only) | Modify |
| `lib/phoenix_replay/config.ex` | Doc additions for `:max_report_bytes` + `:report_rate_per_minute` keys | Modify |
| `test/phoenix_replay/changeset_errors_test.exs` | Unit tests for the new serializer | New |
| `test/phoenix_replay/controller/report_controller_test.exs` | New cases: 422 shape, 413 body cap, 429 rate limit, host-wins metadata | Modify |
| `test/phoenix_replay/controller/submit_controller_test.exs` | New case: host-wins metadata regression | Modify |
| `CHANGELOG.md` | New entry under `[Unreleased]` for the hardening batch | Modify |

The serializer is a standalone module, not a `Phoenix.View`/`ErrorView`
subclass — those are template-driven and would pull in heavier
machinery for a tiny pure-data transform. A function-only module
keeps the dependency surface flat and is what the controllers actually
call.

---

## Task 1 — F1: Shared changeset error serializer

**Files:**
- Create: `lib/phoenix_replay/changeset_errors.ex`
- Create: `test/phoenix_replay/changeset_errors_test.exs`
- Modify: `lib/phoenix_replay/controller/report_controller.ex:55`
- Modify: `lib/phoenix_replay/controller/submit_controller.ex:47`
- Modify: `lib/phoenix_replay/controller/report_controller.ex:65` (also kill the `inspect(reason)` in the catch-all 500)

### Steps

- [ ] **Step 1: Write the failing serializer test**

Create `test/phoenix_replay/changeset_errors_test.exs`:

```elixir
defmodule PhoenixReplay.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.ChangesetErrors

  defmodule FakeSchema do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :description, :string
      field :severity, :string
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [:description, :severity])
      |> validate_required([:description])
      |> validate_inclusion(:severity, ~w(low medium high))
    end
  end

  test "serializes a failed changeset to a field => [messages] map" do
    changeset = FakeSchema.changeset(%{"severity" => "urgent"})

    assert %{
             description: ["can't be blank"],
             severity: ["is invalid"]
           } = ChangesetErrors.serialize(changeset)
  end

  test "interpolates validation parameters (count, etc.) into messages" do
    changeset =
      %FakeSchema{}
      |> Ecto.Changeset.cast(%{"description" => "ok", "severity" => "high"}, [
        :description,
        :severity
      ])
      |> Ecto.Changeset.validate_length(:description, min: 5)

    assert %{description: [msg]} = ChangesetErrors.serialize(changeset)
    assert msg =~ "should be at least 5 character"
  end

  test "tolerates a non-changeset value by returning a string fallback" do
    assert ChangesetErrors.serialize(:some_unexpected_term) == "some_unexpected_term"
    assert ChangesetErrors.serialize("already a string") == "already a string"
  end
end
```

- [ ] **Step 2: Run the failing test**

```
cd ~/Dev/phoenix_replay
mix test test/phoenix_replay/changeset_errors_test.exs
```

Expected: compilation error / `module PhoenixReplay.ChangesetErrors is not loaded`.

- [ ] **Step 3: Implement `PhoenixReplay.ChangesetErrors`**

Create `lib/phoenix_replay/changeset_errors.ex`:

```elixir
defmodule PhoenixReplay.ChangesetErrors do
  @moduledoc false
  # JSON-friendly serializer for `Ecto.Changeset` validation failures.
  #
  # Returned to API clients in 422 response bodies. Keeps internal
  # representations (struct refs, anonymous fns from the changeset's
  # action stack, validation opts) out of the wire payload — the
  # `inspect/1` fallback we used to ship leaked module names and
  # ref-strings that were both noisy and a soft information disclosure.

  @doc """
  Returns a map of `%{field_atom => [error_message_string, ...]}`.

  Falls back to a string representation for any non-changeset input
  so callers can pipe through this serializer unconditionally without
  guarding the input type at every call site.
  """
  @spec serialize(term()) :: %{atom() => [String.t()]} | String.t()
  def serialize(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  def serialize(other) when is_binary(other), do: other
  def serialize(other), do: inspect(other) |> String.trim_leading(":")
end
```

- [ ] **Step 4: Run the test → expect green**

```
mix test test/phoenix_replay/changeset_errors_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Wire into `report_controller.ex`**

Edit `lib/phoenix_replay/controller/report_controller.ex`:

Change the `alias` line at top:

```elixir
alias PhoenixReplay.{ChangesetErrors, Hook, Scrub, Storage}
```

Replace line 55:

```elixir
        {:error, changeset} ->
          send_error(conn, 422, "submit_failed", ChangesetErrors.serialize(changeset))
```

Replace line 65 (the catch-all 500):

```elixir
      {:error, reason} ->
        send_error(conn, 500, "report_failed", ChangesetErrors.serialize(reason))
```

- [ ] **Step 6: Wire into `submit_controller.ex`**

Edit `lib/phoenix_replay/controller/submit_controller.ex`:

Change the `alias` line at top:

```elixir
alias PhoenixReplay.{ChangesetErrors, Hook, Session, SessionToken, Storage}
```

Replace line 47:

```elixir
        {:error, changeset} ->
          send_error(conn, 422, "submit_failed", ChangesetErrors.serialize(changeset))
```

- [ ] **Step 7: Add a 422 contract test in the report controller test**

Add to `test/phoenix_replay/controller/report_controller_test.exs` inside the existing `describe "POST /report"` block:

```elixir
test "422 detail is a serialized error map, not a stringified changeset", %{conn: conn} do
  # Force a submit failure: the test storage's submit/3 returns {:ok, _}
  # by default, so swap in a one-shot {:error, changeset} via a
  # process-dictionary toggle on a custom adapter — or, simpler, set
  # storage to FailingStorage for this test only.
  start_supervised!({PhoenixReplay.Test.FailingStorage, []})
  Application.put_env(:phoenix_replay, :storage, {PhoenixReplay.Test.FailingStorage, []})

  on_exit(fn ->
    Application.put_env(:phoenix_replay, :storage, {PhoenixReplay.Test.RecordingStorage, []})
  end)

  conn = PhoenixReplay.ReportController.create(conn, %{"description" => "trigger 422"})

  assert conn.status == 422
  body = json_response(conn, 422)
  assert body["error"] == "submit_failed"
  # detail must be a structured map, never an inspect-string
  assert is_map(body["detail"])
  refute is_binary(body["detail"]) and String.contains?(body["detail"], "Ecto.Changeset")
end
```

Add the test storage `test/support/failing_storage.ex`:

```elixir
defmodule PhoenixReplay.Test.FailingStorage do
  @moduledoc false
  # Test-only Storage adapter whose submit/3 always returns
  # {:error, changeset} so controller error paths can be exercised.
  @behaviour PhoenixReplay.Storage

  use Agent

  defmodule FakeSchema do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :description, :string
    end

    def invalid_changeset do
      %__MODULE__{}
      |> cast(%{}, [:description])
      |> validate_required([:description])
      |> Map.put(:action, :insert)
    end
  end

  def start_link(_opts \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @impl true
  def start_session(_, _), do: {:ok, "failing-session-#{System.unique_integer([:positive])}"}
  @impl true
  def resume_session(_, _), do: {:error, :not_found}
  @impl true
  def append_events(_, _, _), do: :ok
  @impl true
  def submit(_session_id, _params, _identity), do: {:error, FakeSchema.invalid_changeset()}
  @impl true
  def fetch_feedback(_, _), do: {:error, :not_found}
  @impl true
  def fetch_events(_), do: {:ok, []}
  @impl true
  def list(_, _), do: {:ok, %{results: [], count: 0}}
end
```

Path note: this file goes in `test/support/failing_storage.ex` (same
folder as `recording_storage.ex`); the `mix.exs` `elixirc_paths` for
`:test` already includes `test/support`.

- [ ] **Step 8: Run report_controller_test → expect green**

```
mix test test/phoenix_replay/controller/report_controller_test.exs
```

Expected: previous 5 tests pass + new 422 test passes.

- [ ] **Step 9: Run the whole suite → expect green**

```
mix test
```

Expected: 0 failures. Existing `submit_controller_test.exs` continues
to pass because its tests don't exercise the 422 path.

- [ ] **Step 10: Commit**

```bash
git add lib/phoenix_replay/changeset_errors.ex \
        lib/phoenix_replay/controller/report_controller.ex \
        lib/phoenix_replay/controller/submit_controller.ex \
        test/phoenix_replay/changeset_errors_test.exs \
        test/phoenix_replay/controller/report_controller_test.exs \
        test/support/failing_storage.ex
git commit -m "feat(controllers): structured 422 error bodies via ChangesetErrors (F1)"
```

---

## Task 2 — F3: body-size cap on `POST /report`

**Files:**
- Modify: `lib/phoenix_replay/controller/report_controller.ex`
- Modify: `lib/phoenix_replay/config.ex` (docstring only)
- Modify: `test/phoenix_replay/controller/report_controller_test.exs`

**Default cap:** 5 MB (`5 * 1_048_576 = 5_242_880` bytes). Rationale:
typical 60-second rrweb buffer is ~1–3 MB depending on activity
density; 5 MB leaves headroom for description + extras + a noisy
window. Phoenix's default `Plug.Parsers` cap is 8 MB so we stay below
that ceiling. Hosts that need more (e.g., longer `buffer_window_seconds`)
can override via `config :phoenix_replay, limits: [max_report_bytes:
8_388_608]`.

### Steps

- [ ] **Step 1: Write the failing 413 test**

Add to `test/phoenix_replay/controller/report_controller_test.exs`
inside the `describe "POST /report"` block:

```elixir
test "413 when content-length exceeds max_report_bytes", %{conn: conn} do
  prior_limits = Application.get_env(:phoenix_replay, :limits)
  Application.put_env(:phoenix_replay, :limits, max_report_bytes: 1024)

  on_exit(fn ->
    case prior_limits do
      nil -> Application.delete_env(:phoenix_replay, :limits)
      v -> Application.put_env(:phoenix_replay, :limits, v)
    end
  end)

  oversized_conn =
    conn
    |> put_req_header("content-length", "2048")

  oversized_conn =
    PhoenixReplay.ReportController.create(oversized_conn, %{
      "description" => "would-be too big",
      "events" => []
    })

  assert oversized_conn.status == 413
  assert %{"error" => "body_too_large"} = json_response(oversized_conn, 413)
end

test "happy path passes when content-length is under the cap", %{conn: conn} do
  prior_limits = Application.get_env(:phoenix_replay, :limits)
  Application.put_env(:phoenix_replay, :limits, max_report_bytes: 1_000_000)

  on_exit(fn ->
    case prior_limits do
      nil -> Application.delete_env(:phoenix_replay, :limits)
      v -> Application.put_env(:phoenix_replay, :limits, v)
    end
  end)

  small_conn =
    conn
    |> put_req_header("content-length", "256")

  small_conn = PhoenixReplay.ReportController.create(small_conn, %{"description" => "tiny"})

  assert small_conn.status == 201
end
```

- [ ] **Step 2: Run the failing tests**

```
mix test test/phoenix_replay/controller/report_controller_test.exs
```

Expected: the 413 test fails (no body-size check in place; controller
proceeds to 201).

- [ ] **Step 3: Add `check_body_size/2` to the controller**

Edit `lib/phoenix_replay/controller/report_controller.ex`:

Add `Config` to the alias line:

```elixir
alias PhoenixReplay.{ChangesetErrors, Config, Hook, Scrub, Storage}
```

Replace the `def create(conn, params) do ... end` body so the `with`
chain begins with the body-size check (mirroring `EventsController`):

```elixir
  @default_limits [max_report_bytes: 5_242_880]

  def create(conn, params) do
    identity = Identify.fetch(conn) || %{kind: :anonymous}
    limits = Keyword.merge(@default_limits, Config.limits())

    with :ok <- check_body_size(conn, limits),
         {:ok, description} <- fetch_description(params),
         {:ok, events} <- fetch_events(params),
         {:ok, session_id} <- Storage.Dispatch.start_session(identity, DateTime.utc_now()),
         :ok <- maybe_append(session_id, events) do
      # ... existing body unchanged ...
```

Add a clause to the `else` block to surface `:body_too_large` as 413:

```elixir
    else
      {:error, :body_too_large} ->
        send_error(conn, 413, "body_too_large")

      {:error, :missing_description} ->
        send_error(conn, 422, "missing_description")

      {:error, :events_not_list} ->
        send_error(conn, 400, "events_must_be_list")

      {:error, reason} ->
        send_error(conn, 500, "report_failed", ChangesetErrors.serialize(reason))
    end
  end
```

Add the helper near the bottom (above `defp send_error/4`):

```elixir
  # Mirrors EventsController.check_body_size/2 — content-length-only
  # check (cheap, runs before body parsing). The key difference is the
  # config knob: :max_report_bytes (Path A's single-shot bound) vs.
  # :max_batch_bytes (per-flush bound on /events).
  defp check_body_size(conn, limits) do
    max = Keyword.get(limits, :max_report_bytes, 5_242_880)

    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {n, _} when n <= max -> :ok
          {_, _} -> {:error, :body_too_large}
          :error -> :ok
        end

      _ ->
        :ok
    end
  end
```

- [ ] **Step 4: Run the test → expect green**

```
mix test test/phoenix_replay/controller/report_controller_test.exs
```

Expected: all 8 tests pass (5 original + 1 from Task 1 + 2 new).

- [ ] **Step 5: Update Config docstring**

Edit `lib/phoenix_replay/config.ex`. Inside the `:limits` bullet list
under the existing `* :session_ttl_seconds` line, add:

```elixir
    *   :max_report_bytes (default: 5 MB) — body cap on POST /report
        (Path A single-shot upload). Rejects with 413 before parsing.
    *   :report_rate_per_minute (default: 10 per actor) — submission
        rate cap on POST /report. Returns 429 with retry-after.
```

(Both keys documented together since Task 3 lands the second one in
the same release.)

- [ ] **Step 6: Run the whole suite → expect green**

```
mix test
```

Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/phoenix_replay/controller/report_controller.ex \
        lib/phoenix_replay/config.ex \
        test/phoenix_replay/controller/report_controller_test.exs
git commit -m "feat(report): max_report_bytes cap returns 413 (F3)"
```

---

## Task 3 — F4: per-actor rate limit on `POST /report`

**Files:**
- Modify: `lib/phoenix_replay/controller/report_controller.ex`
- Modify: `test/phoenix_replay/controller/report_controller_test.exs`

**Default limit:** 10 reports/minute per actor. Rationale: Path A is a
deliberate user click; legitimate users won't exceed 10 in a minute.
Scripted abuse hits 429 quickly without a noisy false-positive surface.
Distinct rate-limit key (`{:report, identity_id}`) so a Path B user
actively flushing `/events` doesn't burn through their `/report`
quota — the two endpoints have independent semantics and should have
independent buckets.

### Steps

- [ ] **Step 1: Add RateLimiter to the test setup**

Edit `test/phoenix_replay/controller/report_controller_test.exs`. In
the existing `setup do` block, add the start_supervised + reset:

```elixir
  setup do
    start_supervised!(PhoenixReplay.RateLimiter)
    PhoenixReplay.RateLimiter.reset()

    start_supervised!(RecordingStorage)
    # ... rest unchanged ...
```

- [ ] **Step 2: Write the failing 429 test**

Add inside `describe "POST /report"`:

```elixir
test "429 after report_rate_per_minute hits in a single window", %{conn: conn} do
  prior_limits = Application.get_env(:phoenix_replay, :limits)
  Application.put_env(:phoenix_replay, :limits, report_rate_per_minute: 3)

  on_exit(fn ->
    case prior_limits do
      nil -> Application.delete_env(:phoenix_replay, :limits)
      v -> Application.put_env(:phoenix_replay, :limits, v)
    end
  end)

  # 3 requests must succeed; the 4th must 429 with a retry-after header.
  for _ <- 1..3 do
    ok_conn = PhoenixReplay.ReportController.create(conn, %{"description" => "ok"})
    assert ok_conn.status == 201
  end

  blocked = PhoenixReplay.ReportController.create(conn, %{"description" => "blocked"})

  assert blocked.status == 429
  assert %{"error" => "rate_limited"} = json_response(blocked, 429)
  assert [retry] = Plug.Conn.get_resp_header(blocked, "retry-after")
  assert {n, _} = Integer.parse(retry)
  assert n > 0 and n <= 60
end

test "different actors have independent buckets", %{conn: conn} do
  prior_limits = Application.get_env(:phoenix_replay, :limits)
  Application.put_env(:phoenix_replay, :limits, report_rate_per_minute: 1)

  on_exit(fn ->
    case prior_limits do
      nil -> Application.delete_env(:phoenix_replay, :limits)
      v -> Application.put_env(:phoenix_replay, :limits, v)
    end
  end)

  conn_b =
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> assign(:phoenix_replay_identity, %{kind: :user, id: "u-other", attrs: %{}})
    |> Phoenix.Controller.accepts(["json"])

  ok_a = PhoenixReplay.ReportController.create(conn, %{"description" => "actor a"})
  ok_b = PhoenixReplay.ReportController.create(conn_b, %{"description" => "actor b"})

  assert ok_a.status == 201
  assert ok_b.status == 201
end
```

- [ ] **Step 3: Run the failing tests**

```
mix test test/phoenix_replay/controller/report_controller_test.exs
```

Expected: rate-limit tests fail (no rate-limit check in place; all
4 attempts return 201).

- [ ] **Step 4: Add `check_actor_rate/2` to the controller**

Edit `lib/phoenix_replay/controller/report_controller.ex`:

Add `RateLimiter` to the alias line:

```elixir
alias PhoenixReplay.{ChangesetErrors, Config, Hook, RateLimiter, Scrub, Storage}
```

Extend `@default_limits`:

```elixir
  @default_limits [max_report_bytes: 5_242_880, report_rate_per_minute: 10]
```

Insert the rate check at the top of the `with` chain (before
`check_body_size/2` so an attacker can't burn parser cycles before the
gate fires):

```elixir
    with :ok <- check_actor_rate(identity, limits),
         :ok <- check_body_size(conn, limits),
         {:ok, description} <- fetch_description(params),
         # ... rest unchanged ...
```

Add the rate-limited error branch in the `else` (above `:body_too_large`):

```elixir
      {:error, :rate_limited, retry_after} ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_error(429, "rate_limited")

      {:error, :body_too_large} ->
        send_error(conn, 413, "body_too_large")
```

Add the helper above `check_body_size/2`:

```elixir
  # Distinct key from EventsController's {:actor, _} bucket so Path A
  # /report and Path B /events have independent quotas. A user actively
  # reproducing a bug (Path B) shouldn't burn their /report budget on
  # event flushes, and vice versa.
  defp check_actor_rate(identity, limits) do
    limit = Keyword.get(limits, :report_rate_per_minute, 10)
    key = {:report, identity[:id] || identity[:kind] || :anonymous}
    RateLimiter.hit(key, limit, 60)
  end
```

- [ ] **Step 5: Run the test → expect green**

```
mix test test/phoenix_replay/controller/report_controller_test.exs
```

Expected: all 10 tests pass (5 original + 1 from Task 1 + 2 from
Task 2 + 2 new).

- [ ] **Step 6: Run the whole suite → expect green**

```
mix test
```

Expected: 0 failures. (The Config docstring was already updated in
Task 2 to cover both new keys, so no doc edit needed in this task.)

- [ ] **Step 7: Commit**

```bash
git add lib/phoenix_replay/controller/report_controller.ex \
        test/phoenix_replay/controller/report_controller_test.exs
git commit -m "feat(report): per-actor rate limit returns 429 (F4)"
```

---

## Task 4 — F9 host-wins regression + CHANGELOG + plan index

**Files:**
- Modify: `test/phoenix_replay/controller/report_controller_test.exs`
- Modify: `test/phoenix_replay/controller/submit_controller_test.exs`
- Modify: `CHANGELOG.md`
- Modify: `docs/plans/README.md` (after the commit lands, update the
  ADR-0006 row to mark Phase 2b shipped)

F9 is verify-only: both controllers already do
`client_metadata |> stringify_keys() |> Map.merge(stringify_keys(host_metadata))`
so host wins on collision. We pin that behavior with twin tests (one
per controller) so a future refactor that flips the merge order trips
in CI rather than silently changing semantics.

### Steps

- [ ] **Step 1: Write the failing host-wins test in report_controller_test**

Add inside `describe "POST /report"`:

```elixir
test "F9: host metadata wins when client and host share a key", %{conn: conn} do
  prior_metadata = Application.get_env(:phoenix_replay, :metadata)
  Application.put_env(:phoenix_replay, :metadata, fn _conn ->
    %{"page" => "host-wins", "host_only" => "x"}
  end)

  on_exit(fn ->
    case prior_metadata do
      nil -> Application.delete_env(:phoenix_replay, :metadata)
      v -> Application.put_env(:phoenix_replay, :metadata, v)
    end
  end)

  params = %{
    "description" => "merge order",
    "metadata" => %{"page" => "client-loses", "client_only" => "y"}
  }

  conn = PhoenixReplay.ReportController.create(conn, params)

  assert conn.status == 201
  assert {_session_id, submit_params, _identity} = RecordingStorage.last_submit()

  # Collision — host wins
  assert submit_params["metadata"]["page"] == "host-wins"
  # Non-collision — both pass through
  assert submit_params["metadata"]["host_only"] == "x"
  assert submit_params["metadata"]["client_only"] == "y"
end
```

- [ ] **Step 2: Write the matching test in submit_controller_test**

Add inside `describe "POST /submit — extras passthrough"` (or open a
new `describe "POST /submit — metadata merge"`):

```elixir
describe "POST /submit — metadata merge order" do
  test "F9: host metadata wins when client and host share a key", %{
    conn: conn,
    session_id: session_id
  } do
    prior_metadata = Application.get_env(:phoenix_replay, :metadata)
    Application.put_env(:phoenix_replay, :metadata, fn _conn ->
      %{"page" => "host-wins", "host_only" => "x"}
    end)

    on_exit(fn ->
      case prior_metadata do
        nil -> Application.delete_env(:phoenix_replay, :metadata)
        v -> Application.put_env(:phoenix_replay, :metadata, v)
      end
    end)

    params = %{
      "description" => "merge order",
      "metadata" => %{"page" => "client-loses", "client_only" => "y"}
    }

    conn = PhoenixReplay.SubmitController.create(conn, params)

    assert conn.status == 201
    assert {^session_id, submit_params, _identity} = RecordingStorage.last_submit()

    assert submit_params["metadata"]["page"] == "host-wins"
    assert submit_params["metadata"]["host_only"] == "x"
    assert submit_params["metadata"]["client_only"] == "y"
  end
end
```

- [ ] **Step 3: Run both controller test files → expect green**

```
mix test test/phoenix_replay/controller/report_controller_test.exs \
         test/phoenix_replay/controller/submit_controller_test.exs
```

Expected: all tests pass. The merge order is already correct — these
tests pin existing behavior, so they pass on first run. (If they
fail, that's a real bug F9 was meant to surface; investigate before
proceeding.)

- [ ] **Step 4: Add CHANGELOG entry**

Edit `CHANGELOG.md`. Insert a new section under `## [Unreleased]`,
above the `### ADR-0006 Phase 3 — ...` block, so the chronology
reads top-down:

```markdown
### ADR-0006 Phase 2b — `/report` hardening (2026-04-26)

Closes the four production-blocker follow-ups deferred from Phase 1
(F1, F3, F4, F9 in
`docs/superpowers/specs/2026-04-25-unified-feedback-entry-design.md`):

- **F1 — sanitized 422/500 bodies.** Both `/report` and `/submit`
  now serialize `Ecto.Changeset` errors via
  `PhoenixReplay.ChangesetErrors.serialize/1` (which uses
  `Ecto.Changeset.traverse_errors/2`) instead of leaking
  `inspect(changeset)` strings. The 500 catch-all on `/report` runs
  through the same serializer for consistency.
- **F3 — body-size cap on `POST /report`.** New `:max_report_bytes`
  limit (default 5 MB) rejects oversized requests with 413 before
  parsing, mirroring `EventsController.check_body_size/2`. Hosts that
  raised `buffer_window_seconds` past ~90s should bump this to match.
- **F4 — per-actor rate limit on `POST /report`.** New
  `:report_rate_per_minute` limit (default 10/min) returns 429 with a
  `retry-after` header. Distinct rate-limit key from
  `EventsController` so Path B traffic doesn't consume Path A quota
  and vice versa.
- **F9 — metadata merge order pinned.** Twin regression tests in
  `report_controller_test.exs` + `submit_controller_test.exs` assert
  that host metadata wins on collision (matching the current
  `client |> stringify |> Map.merge(stringify(host))` order in both
  controllers). No production code change — this is regression
  protection only.

No host-side migration required. Hosts that need a larger body cap or
a more permissive rate limit can override:

```elixir
config :phoenix_replay,
  limits: [
    max_report_bytes: 8_388_608,
    report_rate_per_minute: 30
  ]
```

ADR-0006 follow-up table: F1, F3, F4, F9 → resolved. F2 (orphan-events
GC), F5/F6/F8/F12 (cleanups), F7 (JS test infra), F10/F11 (Scrub +
Hook robustness) remain open per the spec table — not blocking
production for ADR-0006.
```

- [ ] **Step 5: Run the whole suite → expect green**

```
mix test
```

Expected: 0 failures across all controller, changeset_errors, session,
storage, and integration tests.

- [ ] **Step 6: Commit the F9 tests + CHANGELOG together**

```bash
git add CHANGELOG.md \
        test/phoenix_replay/controller/report_controller_test.exs \
        test/phoenix_replay/controller/submit_controller_test.exs
git commit -m "docs(changelog): ADR-0006 Phase 2b hardening (F1 F3 F4 F9)

F9 contributes regression tests only; merge order was already correct."
```

- [ ] **Step 7: Update the plan index**

Edit `docs/plans/README.md`. In the ADR-0006 row, replace the
**Next:** sentence so it reads:

```markdown
| —  | Unified Feedback Entry (ADR-0006) | Phases 1 + 2 + 2b + 3 shipped 2026-04-25..2026-04-26. **Next:** Phase 4 (drop legacy `modes:` shim now that ash_feedback audio migrated; drop `open()` alias) — plan not written yet. | [ADR](../decisions/0006-unified-feedback-entry.md) / [spec](../superpowers/specs/2026-04-25-unified-feedback-entry-design.md) / [Phase 1](../superpowers/plans/2026-04-25-unified-entry-phase-1.md) / [Phase 2](../superpowers/plans/2026-04-25-unified-entry-phase-2.md) / [Phase 2b](../superpowers/plans/2026-04-26-unified-entry-phase-2b-hardening.md) / [Phase 3](../superpowers/plans/2026-04-25-unified-entry-phase-3.md) |
```

- [ ] **Step 8: Commit the index update**

```bash
git add docs/plans/README.md
git commit -m "docs(plans): mark ADR-0006 Phase 2b shipped; Phase 4 still next"
```

- [ ] **Step 9: (Optional) push to origin**

```bash
git push
```

Skip if the user wants to review the four commits locally first.

---

## Verification checklist (run after Task 4)

- `mix test` → 0 failures
- `mix test test/phoenix_replay/controller/report_controller_test.exs`
  → 11 tests (5 original + 6 added across F1/F3/F4/F9)
- `mix test test/phoenix_replay/controller/submit_controller_test.exs`
  → 4 tests (3 original + 1 F9)
- `mix test test/phoenix_replay/changeset_errors_test.exs` → 3 tests
- `git log --oneline -5` shows four `feat(...)`/`docs(...)` commits in
  chronological order: F1, F3, F4, hardening CHANGELOG, plan index
- No browser smoke required — server-side hardening only, no JS or UI
  changes. The ash_feedback_demo continues to work against the in-tree
  `_build` artifacts; consumers refresh via
  `mix deps.update phoenix_replay` after the next push.

## Out of scope (explicitly deferred)

- **F2 — orphan events when submit fails after append.** Symmetric
  risk in `/submit` and `/report`; needs a transaction wrapper at the
  `Storage.Ecto` layer or a periodic GC sweep. Separate plan.
- **F5/F6/F8/F12 — JS cleanups.** Cosmetic, no behavior change.
  Bundle into a single Phase 4 cleanup pass alongside the `modes:`
  shim drop.
- **F7 — JS test infrastructure.** ADR-scale work (Vitest /
  Playwright). Tracked in `docs/plans/README.md` "Open follow-ups".
- **F10/F11 — Scrub + Hook robustness.** Defensive hardening, not
  production-blocker. Bundle with F2 in a Storage hardening phase.
- **Phase 4 (drop `modes:` shim + `open()` alias).** Different plan;
  the alpha-license cleanup waits for a deliberate cycle. The shims
  are documented as deprecated and have no active consumers
  (`ash_feedback`'s audio addon migrated to `paths:` per
  `audio_recorder.js:397-409`).
