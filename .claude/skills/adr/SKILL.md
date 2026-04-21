---
name: adr
description: Create or manage Architecture Decision Records (ADRs) in docs/decisions/
argument-hint: "[title] or list or accept/deprecate/supersede [number]"
---

# Architecture Decision Records

Record significant architecture and design decisions for the GsNet project.

## Storage

- ADRs live in `docs/decisions/`
- Format: `NNNN-kebab-case-title.md` (zero-padded 4-digit sequence)
- Index: `docs/decisions/README.md` (auto-maintained)

## Commands

### Create a new ADR: `/adr [title]`

1. Find the next sequence number by scanning `docs/decisions/` for existing `NNNN-*.md` files
2. Create the ADR using the template below
3. Fill in **Context** based on the current conversation and recent work
4. Fill in **Decision** based on what was decided
5. Fill in **Consequences** with positive, negative, and neutral impacts
6. Update `docs/decisions/README.md` index
7. Report the created file path

### List ADRs: `/adr list`

Read `docs/decisions/README.md` and display the index table.

### Change status: `/adr accept|deprecate|supersede [number]`

- `accept N` — Change status from Proposed to **Accepted**
- `deprecate N` — Change status to **Deprecated**, add deprecation reason
- `supersede N by M` — Change N's status to **Superseded by ADR-M**, add link

Update both the ADR file and the index.

## Template

Use this exact template when creating new ADRs:

```markdown
# ADR-NNNN: [Title]

**Date**: YYYY-MM-DD
**Status**: Proposed

## Context

[What is the issue? What forces are at play? 2-5 sentences.]

## Decision

[What did we decide? Be specific about the approach chosen. 2-5 sentences.]

## Alternatives Considered

[Optional. Other approaches that were evaluated and why they were rejected. Bullet list.]

## Consequences

**Positive:**
- [benefit 1]

**Negative:**
- [tradeoff 1]

**Notes:**
- [Any neutral observations, migration notes, or future considerations]
```

## Index Format (docs/decisions/README.md)

```markdown
# Architecture Decision Records

| # | Title | Status | Date |
|---|-------|--------|------|
| [0001](./0001-example.md) | Example Decision | Accepted | 2026-02-21 |
```

## When to Write ADRs

| Timing | Trigger | Example |
|--------|---------|---------|
| **During brainstorming/design** | Choosing between alternatives | Clerk vs AshAuth vs Auth0 |
| **During implementation** | Discovering an unexpected pattern or constraint | RunCalendar business day resolution |
| **During PR/review** | A review changes the approach | Switching from polling to WebSocket |

**Key principle**: Write the ADR **when the decision is made**, not later. Alternatives Considered is most valuable when the analysis is fresh.

## Guidelines

- Write ADRs in **English** (code and architecture terms don't translate well)
- Keep them concise — this isn't a design doc, it's a decision record
- The Context should explain **why** the decision was needed, not rehash the whole project
- Link to related files: `See: lib/gs_net/legacy/mnet.ex`, `See: ADR-0002`
- One decision per ADR. If a decision has sub-decisions, those are separate ADRs
- Don't write ADRs for trivial choices (library version bumps, formatting, etc.)
- DO write ADRs for: technology choices, architectural patterns, data model decisions, breaking changes, security decisions
