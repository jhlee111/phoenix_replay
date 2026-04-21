---
name: plan-status
description: Manage plan lifecycle — list plans, mark completed/abandoned, move between directories
argument-hint: "[list | complete | abandon | activate] [plan-name]"
disable-model-invocation: true
---

# Plan Status Management

Manage the lifecycle of design docs and implementation plans in `docs/plans/`.

## Directory Structure

```
docs/plans/
├── active/      # Currently being implemented
├── completed/   # Successfully implemented (kept for reference)
├── backlog/     # Future work, not yet started
└── abandoned/   # Decided not to implement (with reason)
```

## Commands

### `/plan-status` or `/plan-status list`

List all plans organized by status. For each plan show: filename, title (from first heading), and date.

### `/plan-status complete [name-fragment]`

Move a plan (and its paired design doc) from `active/` to `completed/`.

1. Find matching files in `active/` by name fragment (fuzzy match OK)
2. Move both `-design.md` and `-plan.md` if they exist as a pair
3. Report what was moved

### `/plan-status abandon [name-fragment]`

Move a plan from `active/` to `abandoned/`.

1. Find matching files
2. Ask the user for a one-line reason
3. Add a `> **Abandoned**: [reason] (YYYY-MM-DD)` line at the top of the file
4. Move to `abandoned/`

### `/plan-status activate [name-fragment]`

Move a plan from `backlog/` to `active/` (starting implementation).

### `/plan-status cleanup`

Scan for any plan files still in the root `docs/plans/` directory (not in a subdirectory) and interactively sort them into the correct lifecycle folder.

## Notes

- Plans created by `superpowers:writing-plans` land in `docs/plans/` root by default. This skill helps sort them.
- Design docs (`-design.md`) and implementation plans (`-plan.md`) are always moved together as a pair.
- The `backlog/` directory uses `backlog-*.md` naming (no date prefix) since timing is unknown.
