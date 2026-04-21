---
name: devlog
description: Record a development session summary in the project devlog
argument-hint: "[optional topic override]"
disable-model-invocation: true
---

# Development Log

Record what was accomplished in a development session. This creates the **project's memory** — not Claude's memory (that's MEMORY.md), but a human-readable record of what happened and why.

## Storage

- Devlog entries go in `docs/devlog/YYYY-MM.md` (one file per month)
- Each entry is a date-headed section within the monthly file

## Process

When invoked (`/devlog`):

1. **Gather context automatically** — do NOT ask the user what happened. Instead:
   - Run `git log --oneline --since="6am" --author` to find today's commits
   - Run `git diff --stat HEAD~5` to understand scope of recent changes
   - Review the current conversation for decisions made, problems solved, and discoveries
   - Check if any ADRs were created today

2. **Create/append the entry** in `docs/devlog/YYYY-MM.md`:
   - If the file doesn't exist, create it with a `# Development Log — YYYY-MM` header
   - Append a new section for today's date

3. **Write the entry** using this format:

```markdown
## YYYY-MM-DD

### [Primary Topic]
- What was done (1-3 bullets, concise)
- Key decision or discovery
- See: [link to ADR, doc, or file if relevant]

### [Secondary Topic] (if applicable)
- ...
```

4. **Keep it brief** — 3-10 lines per topic. This is a log, not a report.

## What to Include

- Features implemented or bugs fixed
- Architecture decisions made (link to ADR if created)
- Problems discovered and how they were resolved
- Refactoring done and why
- New patterns established
- Research findings that affected the project

## What NOT to Include

- Step-by-step implementation details (that's in git history)
- Full code snippets (link to files instead)
- Speculative future plans (that's backlog)
- Routine maintenance (dependency updates, formatting)

## Example Entry

```markdown
## 2026-02-21

### MNET Income Data — Business Day Resolution
- Discovered `tbCenterIncomeTotal` only has data through last business day (unlike `tbFinalTotal` which is real-time)
- Added `Mnet.run_date/1` using `mng.tbRunCalendar` to resolve any date to its business day
- See: ADR-0003, `docs/infrastructure/mnet-running-status.md` §14

### AI System Prompt Refactoring
- Split monolithic `build_system_prompt/2` into 7 composable functions
- Added Data Resolution Strategy section to guide LLM on schema exploration
- See: `lib/gs_net/ai/chat.ex`
```
