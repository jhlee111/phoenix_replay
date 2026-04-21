---
name: review-plan
description: "Review an implementation plan against Elixir/Phoenix/Ash best practices, anti-patterns, and GsNet project rules"
argument-hint: "[plan-file-path] — defaults to most recent .claude/plans/*.md"
---

# Plan Review Skill

Review an implementation plan for correctness, best practices, anti-patterns, and alignment with GsNet project conventions.

## Invocation

```
/review-plan                                  # Review most recent plan
/review-plan .claude/plans/my-plan.md         # Review specific plan
/review-plan docs/plans/active/foo-plan.md    # Review from docs/plans
```

## Workflow

### Step 1: Locate the Plan

- If a path argument is given, use it directly.
- If no argument, find the most recent `*.md` in `.claude/plans/` by modification time.
- If no plan found, check `docs/plans/active/` as fallback.
- If still nothing, ask the user.

### Step 2: Read & Parse the Plan

Read the plan file. Extract:
- **Changed files**: Every file path the plan mentions modifying or creating.
- **Plan items**: Each discrete change described (fix, refactor, new file, test, etc.).

### Step 3: Read Context Files

Read every file the plan proposes to change. Also read:
- Closely related files in the same module/directory (e.g., if plan changes `menu_builder.ex`, also read `route_catalog.ex` and the sidebar component that consumes it).
- Existing tests for the files being changed.
- Any Ash resource files referenced (to check DSL correctness).

**Do NOT** read the entire codebase — limit to files within 1 hop of the change set.

### Step 4: Load Framework References

Load relevant skill references based on what the plan touches:
- If plan touches Ash resources/actions → load `ash-framework` skill
- If plan touches LiveView/controllers → load `phoenix-framework` skill
- Always apply CLAUDE.md project rules

### Step 5: Apply Review Checklist

Evaluate each plan item against the checklist below. For each item, assign a verdict:

| Verdict | Meaning |
|---------|---------|
| **Good** | Correct, idiomatic, no issues |
| **Replace** | Wrong approach — provide specific alternative |
| **Reconsider** | Not wrong but has trade-offs worth discussing |
| **Missing** | Plan should address this but doesn't |

### Step 6: Output the Review

Use the exact output format described below.

---

## Review Checklist (Hybrid)

### A. Elixir Anti-Patterns (always check)

1. **Atom safety** — No `String.to_atom/1` at runtime. Use compile-time maps, explicit atom literals, or `String.to_existing_atom/1` with guaranteed pre-existing atoms.
2. **Bare rescue** — No `rescue _ ->` or `rescue _e ->` that silently swallows errors. Rescue specific exceptions, or at minimum log the error.
3. **Fail-open error handling** — Security-sensitive code must fail closed (deny on error), not open (allow on error).
4. **throw/catch for control flow** — Use pattern matching, `with`, or early returns instead of `throw`/`catch` for normal control flow.
5. **Dynamic atom creation from external input** — Never `String.to_atom` on user input, DB values, or API responses.
6. **Nested modules in same file** — One module per file.
7. **Process.sleep in non-test code** — Use proper OTP patterns.
8. **Overly broad pattern matches** — `def handle_event(event, _, socket)` ignoring params that should be validated.
9. **Blocking GenServer** — Long-running work (DB queries, HTTP calls, authorization checks) inside `handle_call`/`handle_cast` blocks the process mailbox. Offload to `Task` and send results back via message.

### B. Phoenix / LiveView Patterns (when applicable)

1. **Fat LiveView** — Business logic belongs in context/domain modules, not in `handle_event`.
2. **assign in conditional branches** — Must rebind `socket =` from block result, not assign inside.
3. **data-confirm / window.confirm** — GsNet uses LiveView confirmation modals (CLAUDE.md rule).
4. **Missing error handling on live_redirect** — After destructive actions, handle the `{:noreply, socket}` vs redirect correctly.

### C. Ash Framework Patterns (when applicable)

1. **scope: option** — All Ash operations must use `scope:` not scattered `tenant:`/`authorize?:` (CLAUDE.md rule).
2. **require Ash.Query** — Must be present when using `Ash.Query` macros.
3. **ash.codegen not ash_postgres.generate_migrations** — For migration generation (CLAUDE.md rule).
4. **AshPrefixedId on all resources** — Every resource with AshPostgres must use it (CLAUDE.md rule).
5. **FK indexes** — All FK columns must have `index?: true` (CLAUDE.md rule).
6. **Code interfaces** — Actions should be available via code interface, not direct Ash calls from LiveView.
7. **Generic actions over orchestrator modules** — Multi-step logic in `run` callbacks (CLAUDE.md rule).
8. **No `argument :tenant_id`** — Multitenancy handles it (CLAUDE.md rule).
9. **AshGrant scope expressions** — Use correct actor_context keys per scope level (CLAUDE.md rule).
10. **Bulk operations** — Use `Ash.bulk_create`/`Ash.bulk_update` for >100 records.

### D. GsNet Project Rules (always check)

1. **Domain-first design** — New domain models shouldn't be constrained by MNET legacy structure.
2. **Layer rules** — Domain modules thin, code interfaces required, generic actions preferred.
3. **Test plan** — Changes should include or reference tests. Unit tests in `test/gs_net/`, policy tests in `test/policy_tests/`.
4. **Test through public API** — Don't test private functions directly.
5. **AshStateMachine for status transitions** — Not manual `set_attribute(:status, ...)`.
6. **AshOban for resource jobs** — Not manual CronWorker fan-out.

### E. Elixir Coding Style (always check)

Review all code snippets in the plan for idiomatic Elixir. Flag non-idiomatic patterns as **Replace** when a clearly better alternative exists, **Reconsider** when it's a minor style preference.

#### E.1 Pattern matching over conditionals

Use pattern matching and multi-clause functions instead of `if`/`else`, `unless`, `cond`, or `||` for value dispatch.

```elixir
# ❌ if/else for value dispatch
def process(value) do
  if is_nil(value), do: :default, else: transform(value)
end

# ✅ Multi-clause
def process(nil), do: :default
def process(value), do: transform(value)
```

```elixir
# ❌ Conditional on a known set of values
def handle(type) do
  if type == :admin, do: admin_path(), else: user_path()
end

# ✅ Multi-clause
def handle(:admin), do: admin_path()
def handle(_type), do: user_path()
```

#### E.2 `with` for multi-step happy paths

Use `with` when chaining operations that can fail, instead of nested `case` or sequential variable assignments that need error handling.

```elixir
# ❌ Nested case
case fetch_user(id) do
  {:ok, user} ->
    case authorize(user) do
      :ok -> do_work(user)
      error -> error
    end
  error -> error
end

# ✅ with
with {:ok, user} <- fetch_user(id),
     :ok <- authorize(user) do
  do_work(user)
end
```

Do NOT use `with` for simple assignments that cannot fail — plain variables or a pipeline is clearer.

#### E.3 `||` defaults → `Keyword.get/3` or pattern matching

Replace `opts[:key] || default` with `Keyword.get(opts, :key, default)` for keyword lists. For maps, use `Map.get/3` or pattern match in the function head.

```elixir
# ❌ JavaScript-style defaults
tool_names = tool_opts[:tool_names] || true
extra = tool_opts[:extra] || []

# ✅ Keyword.get with defaults
tool_names = Keyword.get(tool_opts, :tool_names, :all)
extra = Keyword.get(tool_opts, :extra, [])
```

#### E.4 Multi-clause over inline `if` in reduce/map callbacks

When a function inside `Enum.reduce`, `Enum.map`, etc. branches on a value, extract to a named multi-clause helper.

```elixir
# ❌ Inline conditional in reduce
Enum.reduce(items, acc, fn item, acc ->
  if item.type == :special do
    handle_special(item, acc)
  else
    acc
  end
end)

# ✅ Multi-clause helper
Enum.reduce(items, acc, &accumulate/2)

defp accumulate(%{type: :special} = item, acc), do: handle_special(item, acc)
defp accumulate(_item, acc), do: acc
```

#### E.5 MapSet/Map operations over list workarounds

Use native data structure operations instead of list manipulations when working with sets or maps.

```elixir
# ❌ List concat + dedup + filter for set logic
(list_a ++ MapSet.to_list(set_b))
|> Enum.uniq()
|> Enum.filter(&MapSet.member?(allowed, &1))

# ✅ Set operations
MapSet.new(list_a)
|> MapSet.union(set_b)
|> MapSet.intersection(allowed)
|> MapSet.to_list()
```

```elixir
# ❌ Enum.reduce to build a MapSet
Enum.reduce(names, existing_set, &MapSet.put(&2, &1))

# ✅ MapSet.union
MapSet.union(existing_set, MapSet.new(names))
```

#### E.6 `Map.merge/2` over chained `Map.put/3`

When adding multiple keys to a map, use a single `Map.merge/2` instead of chaining `Map.put/3`.

```elixir
# ❌ Chained puts
map
|> Map.put(:key_a, val_a)
|> Map.put(:key_b, val_b)
|> Map.put(:key_c, val_c)

# ✅ Single merge
Map.merge(map, %{key_a: val_a, key_b: val_b, key_c: val_c})
```

#### E.7 Guard clauses over defensive `if`

Use `when` guards in function heads instead of `if` checks at the top of function bodies.

```elixir
# ❌ Defensive if at top
def notify(pid, msg) do
  if is_pid(pid), do: send(pid, msg), else: :ok
end

# ✅ Multi-clause with guard
def notify(pid, msg) when is_pid(pid), do: send(pid, msg)
def notify(_pid, _msg), do: :ok
```

#### E.8 Function head destructuring over body extraction

Extract values from maps/keyword lists in function heads or `with` bindings, not via sequential `opts[:key]` in the function body.

```elixir
# ❌ Sequential extraction
def handle_cast({:send_message, text, opts}, state) do
  scope = opts[:scope]
  page = opts[:page_context]
  pdf = opts[:pdf_contents]
  # ...
end

# ✅ Destructure required keys; access optional ones individually
def handle_cast({:send_message, text, opts}, state) do
  with scope when not is_nil(scope) <- opts[:scope],
       page_tools <- resolve_page_tools(opts[:page_context]) do
    # scope is bound, optional keys accessed as needed
  end
end
```

For keyword lists where you need many optional keys with defaults, `Keyword.validate!/2` or `Keyword.merge/2` with a defaults keyword list is acceptable.

#### E.9 Pipeline consistency

Don't mix pipeline style and variable rebinding in the same transformation. Pick one.

```elixir
# ❌ Mixed
result = fetch_data(id)
result = result |> transform()
result = Enum.map(result, &format/1)

# ✅ Single pipeline
result =
  id
  |> fetch_data()
  |> transform()
  |> Enum.map(&format/1)
```

#### E.10 Function arity and parameter grouping

Functions with more than 5 parameters should group related params into a map or struct. This is especially important for recursive functions that thread state.

```elixir
# ❌ Too many positional args
defp loop(messages, model, llm_opts, registry, context, target_pid, iteration, tool_state)

# ✅ Group into a loop state struct/map
defp loop(messages, %{model: model, registry: registry} = loop_state, iteration)
```

### F. Contextual Issues (based on related files)

Check for issues the plan should address but doesn't mention:
- Pre-existing bugs or anti-patterns in the changed files that the plan's changes interact with.
- Missing error handling at system boundaries.
- Inconsistencies between the plan's approach and patterns established elsewhere in the same module.
- Non-idiomatic Elixir in the plan's code that interacts with existing idiomatic code in the same file.

**Important**: Only flag contextual issues that are *relevant* to the plan's changes. Don't audit the entire file for unrelated issues.

---

## Output Format

### Header

```markdown
## Plan Review: [plan title from first heading]

**Plan file**: `path/to/plan.md`
**Files in scope**: [list of files read]
**Checklist sections applied**: A, B, C, D, E, F (list which were relevant)
```

### Verdict Table

```markdown
### Verdicts

| # | Plan Item | Verdict | Issue |
|---|-----------|---------|-------|
| 1 | [concise description] | Good | — |
| 2 | [concise description] | Replace | [1-line reason] → see detail below |
| 3 | [concise description] | Reconsider | [1-line trade-off] |
| 4 | — | Missing | [thing plan should address] |
```

### Detail Sections

For each non-Good verdict, provide a detail section:

```markdown
### #2: [Plan Item] → Replace

**Checklist**: A.1 (Atom safety)

**Problem**: [What's wrong and why, referencing the specific anti-pattern]

**Suggested fix**:
```elixir
# concrete code showing the better approach
```

**Impact**: [What breaks or degrades if this isn't changed]
```

### Contextual Findings

```markdown
### Contextual Findings

Issues in changed files that interact with the plan's changes:

- **[file:line]** — [issue description]. [Checklist ref if applicable].
```

### Summary

```markdown
### Summary

- **X/Y items Good** — ready to implement as-is
- **Z items need changes** — [1-line summary of most important change]
- **Overall**: [Go / Go with changes / Needs rework]
```

---

## Guidelines

- **Be concrete**: Always show code for Replace/Reconsider verdicts. Don't just say "use a better pattern."
- **Be proportional**: A minor style preference is Reconsider. Reserve Replace for correctness/safety problems AND clear Elixir idiom violations (Section E) where the idiomatic alternative is unambiguously better.
- **Respect the plan's scope**: Don't suggest expanding scope or adding features. Review what's there.
- **Check assumptions**: If the plan says "X is safe because Y", verify Y is actually true by reading the code.
- **Test coverage**: If the plan includes tests, verify they test through public API and cover the changes adequately. If no tests are mentioned for non-trivial changes, flag as Missing.
- **Idiomatic Elixir matters**: Code in plans becomes production code. Flag non-idiomatic patterns (Section E) in every code snippet — these are easier to fix during planning than after implementation. Show the idiomatic alternative side-by-side.
