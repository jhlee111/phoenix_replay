---
name: update-docs
description: Update project documentation after completing work
---

# Update Project Documentation

Gated workflow to keep `docs/` vault organized after completing work. Each gate must pass before proceeding.

## Docs Vault Principles (from `docs/README.md`)

**Trust Hierarchy**: ADRs > `plans/README.md` > `guides/` > `contexts/` (unimplemented only)
**SOT for implemented domains**: Code + ADRs. Not docs files.
**Folder rules**:
- `decisions/` — Architecture decisions (`/adr` skill)
- `plans/README.md` — Project dashboard (status table, priorities, active work)
- `plans/active/` → `plans/completed/` when done
- `guides/` — Operational procedures (mnet-sync, seeding, deployment, etc.)
- `contexts/` — **Unimplemented domain designs only** (archive when implemented)
- `infrastructure/` — **Future investigation docs only** (archive when implemented)
- `archive/` — Everything superseded or implemented

---

## Gate 1: Identify What Changed

Scan the conversation context and recent git activity to determine what was done.

```bash
git diff --stat HEAD~3..HEAD  # or appropriate range
git log --oneline -5
```

Classify the work:
- [ ] **New feature/domain implemented** → status table update needed
- [ ] **Architecture decision made** → ADR needed
- [ ] **Operational procedure changed** → guide update needed
- [ ] **Plan completed** → move active → completed
- [ ] **Domain fully implemented** → context file → archive
- [ ] **Investigation completed & implemented** → infrastructure file → archive or delete
- [ ] **New work started** → plan created in active/

**Ask the user**: "이 작업에서 다음 중 해당하는 것이 있나요?" and present the checklist.
If the user says "just update status" or similar, skip to the relevant gate.

---

## Gate 2: ADR Check

**Question**: Was an architecture or design decision made during this work?

Signs that an ADR is needed:
- Chose between alternative approaches
- Changed how a domain works
- Added a new integration pattern
- Made a data model decision
- Discovered a constraint that shaped implementation

**If yes** → Run `/adr [title]` first, then continue.
**If no** → Proceed.

---

## Gate 3: Dashboard Update (`plans/README.md`)

Read `docs/plans/README.md` and check:

### 3a. Implementation Status Table
- Does a context row need status/test count update?
- Does a new context need to be added?
- Do ADR references need updating?
- Do sync guide links need adding?

### 3b. Active Work Section
- Does the active plans table need updating? (new plan, updated date)

### 3c. Up Next / Priorities
- Has the priority order changed?
- Has an "immediate" item been completed and needs removal?

### 3d. Not Yet Implemented Table
- Was a previously unimplemented domain started? Move from "Not Yet Implemented" to main status table.

**Show the proposed changes** to the user and confirm before applying.

---

## Gate 4: Guide Updates

Check if operational procedures were affected:

| If this changed... | Update this guide |
|---------------------|-------------------|
| MNET sync/import | `guides/mnet-sync/` (domain-specific file + README) |
| Legal/agreements | `guides/legal/agreements.md` |
| Seeding process | `guides/SEEDING.md` |
| Deployment process | `guides/deployment.md` |
| Stripe Terminal | `guides/stripe-terminal.md` |
| Test patterns | `guides/TESTING_GUIDE.md` |

**If no guide exists for the changed procedure**:
- Ask: "이 절차에 대한 가이드를 `guides/`에 만들까요?"
- If yes, create it following the `guides/mnet-sync/README.md` pattern (ADR backlinks, procedures, field mappings)

---

## Gate 5: Plan Lifecycle

### Completed plans
- If a plan in `plans/active/` is done → move to `plans/completed/`
- Ask: "이 active plan들 중 완료된 것이 있나요?" and list active plans

### New plans
- If new significant work is about to start → create in `plans/active/`
- Include: ADR references, scope, phases, related context docs

---

## Gate 6: Archive Check

### Context files
- If a domain in `contexts/` was just fully implemented → move to `archive/contexts/`
- Ask: "이 도메인이 완전히 구현되었나요? 코드+ADR이 SOT?"

### Infrastructure files
- If an investigation in `infrastructure/` led to implementation → archive or delete
- Tax, MNET schema, vendor analysis → verify implementation, then clean up

### Backlog plans
- If a backlog plan was implemented → move to `plans/completed/`

---

## Gate 7: Consistency Check

Final verification:

1. **`plans/README.md` status table** — does it match actual implementation state?
2. **`decisions/README.md` index** — are all ADR files listed?
3. **`docs/README.md` folder descriptions** — still accurate?
4. **No orphan references** — no links to moved/deleted files in remaining docs?

Run:
```bash
# Check for broken internal links to moved files
grep -r "MASTER_PLAN\|contexts/core/members\|contexts/business/inventory" docs/ --include="*.md" -l | grep -v archive/
```

Fix any broken references found.

---

## Gate 8: Moduledoc & Description Consistency

Check if `@moduledoc`, `@doc`, and Ash attribute `description` strings are consistent with the changes made. This catches stale terminology after architectural changes (e.g., renaming engines, removing dependencies, changing template syntax).

### What to scan

For each domain touched by the work, grep for outdated terms in `lib/` files:

```bash
# Example: after removing a dependency or changing an approach
grep -rn "OldTerm\|old_pattern" lib/gs_net/<domain>/ --include="*.ex" | grep -v "test\|_build"
```

### Common staleness patterns

| If this changed... | Grep for stale terms |
|---------------------|---------------------|
| Template engine replaced | Old engine name in moduledocs, attribute descriptions |
| Dependency removed | Old dep name in comments, @doc strings |
| Rendering pipeline changed | Old pipeline terminology (e.g., "HTML rendering" after switch to PDF-only) |
| Action/function renamed | Old function name in @doc cross-references |
| Data format changed | Old format name in attribute descriptions (e.g., "Liquid template" → "Typst markup") |

### What to update

- `@moduledoc` blocks that describe the old approach
- `@doc` strings referencing removed functions or old workflows
- Ash attribute `description` strings (shown in API docs and AshAi tool schemas)
- Code comments describing removed behavior

### What NOT to update here

- **AshAi tool descriptions** (`tools do` blocks in domain modules) — these need careful, granular control. Use a dedicated AshAi skill instead.
- **Test descriptions** — update only if misleading, not for style
- **Functional code** — this gate is docs-only

### Process

1. Identify the key terms that changed (e.g., "Liquid" → "Typst", "HTML" → "PDF")
2. Grep across the affected domain's `lib/` files
3. Show findings to the user with proposed changes
4. Apply approved changes (docs-only, no functional code)

---

## Gate 9: CLAUDE.md Check

If any of these changed, update `CLAUDE.md`:
- New gotcha or development rule discovered
- Key file location changed
- Database rule changed
- ADR count changed (currently 69개)

### CLAUDE.md Writing Style

**Keep CLAUDE.md light — one-line rules with links to detailed guides.**

- Each rule section: bullet-point instructions (1 line each) that LLM can act on immediately
- If a rule needs code examples or detailed explanation → create `docs/guides/<topic>.md`
- End the section with `Full guide: \`docs/guides/<topic>.md\``
- LLM reads CLAUDE.md first for quick rules, follows link for implementation details

```markdown
### Section Title

- Rule 1 — one-line actionable instruction
- Rule 2 — one-line actionable instruction
- Rule 3 — one-line actionable instruction

Full guide: `docs/guides/<topic>.md`
```

**Don't bloat CLAUDE.md** — it should be concise rules and pointers, not detailed docs.

---

## Gate 10: Memory Cleanup

Review `MEMORY.md` and individual memory files for staleness. Memory is session-to-session context — not a permanent archive.

### 10a. Completed handoffs → Delete

Handoff files (`*-handoff.md`) where all TODOs are done and no remaining work exists:
- Feature fully implemented + tests passing + no open issues → **delete the file**
- The implementation itself (code + ADR + guide) is the permanent record, not the memory

### 10b. Superseded entries → Delete

Memory entries explicitly marked as superseded or replaced by newer entries:
- Check for `(Superseded by ...)` notes in MEMORY.md
- If a newer handoff covers the same scope → delete the older one

### 10c. Active handoffs → Update

For handoff files that are still active (have remaining TODOs):
- Update the description to reflect current state
- Move completed items out of "TODOs" into "Done"
- Ensure "How to apply" section points to the right next step

### 10d. MEMORY.md structure

- No duplicate section headers (e.g., two `## Active Projects`)
- Entries in the correct section (completed work → `## Completed (archived)` or delete)
- Each line under 150 chars
- Total file under 200 lines (truncation risk beyond this)

### 10e. New memories from this session

Check if anything from this session should be saved:
- New feedback from user (corrections, preferences)
- Non-obvious design decisions not captured in ADRs
- External references discovered

**Ask the user**: "이번 세션에서 기억해야 할 피드백이나 결정이 있나요?"

---

## Summary

After all gates pass, report:
- What was updated (files changed)
- What was archived/moved
- What was created
- Any items deferred for later

**Commit docs changes separately** from code changes when possible, with message format:
```
docs: [brief description of what was updated]
```
