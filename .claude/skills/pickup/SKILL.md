---
name: pickup
description: Morning briefing — where we left off, what to work on today. Fast, compact report from canonical sources.
---

# Pickup — Start My Day

Fast morning scan. Output a single compact report (≤20 lines). No interactive gates — just read, summarize, recommend.

## Data Sources (in priority order)

### 1. Interrupted Work (must check first)

```bash
git status -s
git stash list
```

If uncommitted changes or stashes exist → flag as 🔴 at top of report.

### 2. Recent Activity

```bash
git log --oneline --since="yesterday 6am" --author="jhlee"
```

If no commits since yesterday, expand to 3 days. Summarize in 1-2 lines (not the full log).

### 3. Active Plans (canonical source)

Read `docs/plans/README.md` — specifically the **Active Work** table and **Up Next** sections.

This is the single source of truth for priorities. Do NOT read all 13 active plan files — only reference them if the user asks for detail.

### 4. Open Bugs

```bash
gh issue list --label bug --state open --limit 5
```

If any open bugs exist, list them. Bugs take priority over feature work.

### 5. Recently Updated GitHub Issues (optional)

```bash
gh issue list --state open --limit 5 --sort updated
```

Only include if there are recent (last 3 days) updates worth noting.

## Output Format

```
## 프로젝트 현황 — YYYY-MM-DD

[🔴 중단된 작업 — only if uncommitted/stashed work exists]
- file list or description

### 최근 작업
- 1-2 line summary of recent commits

### 활성 작업 (docs/plans/active/)
| Plan | 현재 상태 | 다음 단계 |
|------|----------|----------|
| ... | ... | ... |
(from README.md Active Work table — max 5 rows)

### 추천 시작점
1. [가장 우선순위 높은 작업] — 근거
2. [차순위] — 근거 (optional)

### 열린 버그
- #N: description (if any)
```

## Rules

- **15-20 lines max** for the default report. Brevity is the point.
- **Do NOT read memory handoff files** — plans/active/ is canonical. Memory is for Claude's internal context, not for the pickup report.
- **Do NOT read individual plan files** unless the user asks "이거 자세히 알려줘".
- **Do NOT create tasks** — this is a read-only scan.
- **Do NOT start working** — present the report and wait for the user to choose.
- **Recommend based on docs/plans/README.md "Up Next"** section priorities, adjusted by:
  - Bugs first (if any)
  - Interrupted work second (if any)
  - Then the stated priority order
