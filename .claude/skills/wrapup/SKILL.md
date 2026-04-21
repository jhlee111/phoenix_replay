---
name: wrapup
description: Systematically close a coding session — commit check, memory update, plan sync, docs, handoff summary
---

# Session Wrap-up

Long session closure checklist. Run each gate sequentially. Do not skip gates.

---

## Gate 1: Git Status

```bash
git status
git diff --stat HEAD
```

Categorize uncommitted changes into logical groups and ask the user:

> "커밋 안 된 변경이 N개 있습니다. 지금 커밋할까요? (논리 그룹별로 나눠서)"

If yes → commit by logical groups before proceeding. If no → note which files are intentionally uncommitted.

---

## Gate 2: Memory Update (lightweight only)

Memory is for Claude's cross-session context — NOT for tracking project progress. That belongs in `docs/plans/active/` (Gate 3).

Check existing memory:

```bash
cat /Users/johndev/.claude/projects/-Users-johndev-Dev-gs-net/memory/MEMORY.md
```

**What to save in memory:**
- **Feedback** (`feedback-*.md`) — process rules, corrections, confirmed approaches
- **Project context** (`project-*.md`) — non-obvious facts, constraints, stakeholder decisions
- **References** (`reference-*.md`) — pointers to external systems

**What NOT to save in memory:**
- ❌ Detailed "what was done / what's next" — that's Gate 3 (Plan Sync)
- ❌ Handoff files duplicating plan content — use 1-line pointer to plan file instead
- ❌ Implementation status, phase completion — that's the plan file

**Handoff files** (`*-handoff.md`): If one exists and the plan is the canonical source, simplify it to a 1-2 line pointer:
```markdown
---
name: example-handoff
description: Pointer to active plan
type: project
---
See [docs/plans/active/example.md] — Phase 2 in progress, Phase 3 next.
```

Add any new files to MEMORY.md index.

---

## Gate 3: Plan Sync (PRIMARY — this is where "다음 할 일" lives)

This is the canonical record of project progress. `/pickup` reads this in the morning.

```bash
ls docs/plans/active/
```

For each plan touched this session:
1. **Update the plan file** — mark completed phases, update "Next" section with specific next step
2. **Update `docs/plans/README.md`** dashboard — sync the Active Work table (focus, updated date)
3. **If a plan is fully done** → move to `docs/plans/completed/` (ask user first)
4. **If a new workstream started** → create plan in `docs/plans/active/`, add to README dashboard

The plan file's "Next" section is what `/pickup` will recommend tomorrow. Make it actionable:
- ✅ "Phase 2: implement RefundLine resource with tier-based scopes"
- ❌ "Continue working on refunds"

---

## Gate 4: CLAUDE.md Review

Scan this session's conversation for:
- New patterns that should be rules (gotchas, conventions, things that caused bugs)
- Rules already in CLAUDE.md that were updated or refined

If there are new rules: add them to the appropriate section in `CLAUDE.md`. Keep them concise — one rule, one example max.

---

## Gate 5: Update Docs & ADR Status

**ADR Status Check**: Scan `docs/decisions/README.md` for ADRs touched this session. If an ADR was created as "Proposed" and the decision was implemented and verified → change status to "Accepted" (in both the ADR file and the README index). Use `/adr accept N`.

**Doc Updates**: Run `/update-docs` if any of the following changed this session:
- Public-facing module behavior (actions, API, LiveView routes)
- Architecture (new resource, new domain, new extension)
- ADR needed (significant decision was made)

Skip doc updates if session was only refactoring, bug fixes, or infra/tooling with no behavior change.

---

## Gate 6: Handoff Summary

Print a concise session summary for the user:

```
## 이번 세션 요약

### 완료
- [bullet per completed item]

### 열린 항목
- [bullet per open/blocked item with location of plan/issue]

### 다음 세션 시작점
- [the single most important thing to do next]
```

Keep it under 15 lines. The user reads this — make it scannable.
