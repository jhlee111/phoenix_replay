---
name: refactor
description: "Review changed code for Elixir/Ash/Phoenix best practices, anti-patterns, and idiomatic style — then fix issues found"
argument-hint: "[file-path or glob] — defaults to files changed in current git diff"
---

# Refactor Skill

Review code against Elixir/Ash/Phoenix best practices, anti-patterns, and GsNet project conventions. Identify issues and apply fixes directly.

## Invocation

```
/refactor                                        # Review files in current git diff
/refactor lib/gs_net/legal/authoring.ex          # Review specific file
/refactor lib/gs_net/ai/*.ex                     # Review matching files
/refactor --dry-run                              # Report issues without fixing
/refactor --scope=style                          # Only check Elixir style (Section E)
/refactor --scope=ash                            # Only check Ash patterns (Section C)
/refactor --scope=phoenix                        # Only check Phoenix patterns (Section B)
/refactor --scope=all                            # Full checklist (default)
```

## Workflow

### Step 1: Identify Target Files

- If a file path or glob is given, use it directly.
- If no argument, get changed files from `git diff --name-only HEAD` (staged + unstaged).
- If still nothing, get files from the most recent commit: `git diff --name-only HEAD~1 HEAD`.
- Filter to only `.ex` and `.exs` files.
- If `--dry-run` is specified, report findings without making edits.
- If `--scope=<section>` is specified, only apply that checklist section.

### Step 2: Read Target Files

Read every target file. Also read:
- Closely related files in the same module/directory (siblings, callers, tests).
- Any Ash resource files referenced by the target (to verify DSL patterns).
- Limit to files within 1 hop of the target set — don't scan the whole codebase.

### Step 3: Load Framework References

Based on what the code touches:
- If code uses Ash resources/actions/queries → load `ash-framework` skill references
- If code uses LiveView/controllers/components → load `phoenix-framework` skill references
- Always apply CLAUDE.md project rules

### Step 4: Apply Review Checklist

Evaluate the code against all applicable sections. For each finding, classify severity:

| Severity | Meaning | Action |
|----------|---------|--------|
| **Fix** | Bug, safety issue, or rule violation — must change | Auto-fix |
| **Improve** | Non-idiomatic or suboptimal — clear better alternative | Auto-fix |
| **Consider** | Trade-off worth noting but subjective | Report only |

### Step 5: Apply Fixes

For each Fix and Improve finding:
1. Make the edit using the Edit tool.
2. Record what changed and why.

For Consider findings, report without editing.

### Step 6: Output Report

After all edits, output the summary report in the format below.

---

## Review Checklist

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
10. **Unused variables without underscore** — Variables bound but never used must be prefixed with `_`.
11. **Hardcoded secrets/credentials** — No API keys, passwords, or tokens in source. Use config/env.
12. **Large binary/string concatenation in loops** — Use IO lists instead.

### B. Phoenix / LiveView Patterns (when applicable)

1. **Fat LiveView** — Business logic belongs in context/domain modules, not in `handle_event`.
2. **assign in conditional branches** — Must rebind `socket =` from block result, not assign inside.
3. **data-confirm / window.confirm** — GsNet uses LiveView confirmation modals (CLAUDE.md rule).
4. **Missing error handling on live_redirect** — After destructive actions, handle the `{:noreply, socket}` vs redirect correctly.
5. **Leaking assigns to components** — Pass only needed assigns, not the whole socket.
6. **Heavy computation in mount/0** — Defer to `handle_params` or `handle_async` for data loading.
7. **Missing `phx-debounce` on text inputs** — Prevents excessive server round-trips.
8. **Inline styles in HEEx** — Use CSS classes, not inline `style=` attributes.

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
11. **Ash.Changeset pattern matching** — Use `case`/pattern matching instead of `if` for changeset attribute/argument checks.
12. **Generic action tenant access** — Use `input.tenant`, NOT `input.context[:tenant]`.

### D. GsNet Project Rules (always check)

1. **Domain-first design** — New domain models shouldn't be constrained by MNET legacy structure.
2. **Layer rules** — Domain modules thin, code interfaces required, generic actions preferred.
3. **AshStateMachine for status transitions** — Not manual `set_attribute(:status, ...)`.
4. **AshOban for resource jobs** — Not manual CronWorker fan-out.
5. **MSSQL BIT parsing** — Must use `Types.parse_bit/1`, never `== 1` (CLAUDE.md rule).
6. **MnetTime for datetime boundary** — All MNET datetimes through `MnetTime` (CLAUDE.md rule).
7. **Shadow DOM flex scroll** — Every intermediate flex container needs `min-height: 0; overflow: hidden;`.
8. **GenServer state migration** — Use `Map.get/2` not dot access for hot-reloadable state.

### E. Elixir Idiomatic Style (always check)

Review all code for idiomatic Elixir. Apply **Improve** for clear anti-patterns, **Consider** for minor style preferences.

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

#### E.11 Pipe into anonymous functions

Use `then/1` instead of assigning to a variable just to pass into an anonymous function.

```elixir
# ❌ Intermediate variable
result = compute_value(input)
callback.(result)

# ✅ Pipe with then
input
|> compute_value()
|> then(callback)
```

#### E.12 Prefer `Enum.map` + `Enum.reject(nil)` over `Enum.reduce` for filter-map

When building a list by conditionally including transformed items, prefer `Enum.map` + `Enum.reject(&is_nil/1)` or `Enum.flat_map` returning `[]`/`[item]` over `Enum.reduce` with list accumulator reversal.

```elixir
# ❌ Reduce with conditional append
Enum.reduce(items, [], fn item, acc ->
  case transform(item) do
    nil -> acc
    val -> [val | acc]
  end
end)
|> Enum.reverse()

# ✅ flat_map
Enum.flat_map(items, fn item ->
  case transform(item) do
    nil -> []
    val -> [val]
  end
end)
```

#### E.13 String interpolation over concatenation

Prefer `"Hello #{name}"` over `"Hello " <> name` for readability, unless building IO lists.

#### E.14 Avoid `Enum.count` for emptiness checks

Use `Enum.empty?/1`, `match?([_ | _], list)`, or pattern match on `[]` — never `Enum.count(x) == 0` or `length(x) == 0` for large lists.

### F. Contextual Issues (based on related files)

Check for issues the refactoring should address:
- Pre-existing bugs or anti-patterns in the changed files that interact with the refactored code.
- Missing error handling at system boundaries.
- Inconsistencies between the refactored code and patterns established elsewhere in the same module.
- Dead code left behind after refactoring (unused private functions, unreachable clauses).

**Important**: Only flag contextual issues that are *relevant* to the target files. Don't audit unrelated code.

---

## Output Format

After applying fixes, output a summary report:

### When edits were made

```markdown
## Refactor Report

**Files reviewed**: [list]
**Checklist sections applied**: A, B, C, D, E, F

### Changes Applied

| # | File | Line | Severity | Rule | Description |
|---|------|------|----------|------|-------------|
| 1 | `path/to/file.ex` | 42 | Fix | A.2 | Bare rescue → rescue specific exception |
| 2 | `path/to/file.ex` | 87 | Improve | E.1 | if/else → multi-clause function |

### Consider (not auto-fixed)

- **`path/to/file.ex:120`** — [E.10] Function has 6 args, could group into struct. Left as-is because [reason].

### Summary

- **X fixes applied** across Y files
- **Z items noted** for consideration
```

### When `--dry-run`

Same format but under "Proposed Changes" instead of "Changes Applied", and no edits are made.

---

## Guidelines

- **Be concrete**: Always show the before/after for each change.
- **Be proportional**: Don't refactor working code just for style. Focus on clarity, safety, and idiom violations.
- **Respect scope**: Only refactor the target files. Don't expand to unrelated modules.
- **Preserve behavior**: Refactoring must not change observable behavior. If unsure, classify as Consider.
- **Run tests after**: After applying fixes, remind the user to run `mix test` for affected test files.
- **Don't over-refactor**: Three similar lines of code is better than a premature abstraction. Don't extract helpers for one-time operations.
- **Idiomatic Elixir matters**: Flag every Section E violation — these compound into hard-to-read code over time.
