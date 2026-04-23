# Architecture Decision Records

라이브러리의 아키텍처 결정 기록. 번호순 + 날짜순.

| # | Title | Status | Date |
|---|-------|--------|------|
| [0001](./0001-widget-trigger-ux.md) | Widget Trigger UX — Float Default + Headless Mode | Accepted | 2026-04-23 |

## Rules

- 번호는 순차, 재사용 금지
- Status: `Proposed` → `Accepted` → `Superseded by ADR-XXXX`
- 기존 ADR은 수정하지 않음 — 변경은 새 ADR로 supersede (경미한 amend 주석은 허용)

phoenix_replay는 standalone core 라이브러리입니다. Ash-specific 결정 (resource shape, policy, triage 등) 은 [ash_feedback](https://github.com/jhlee111/ash_feedback) wrapper 쪽에 기록됨.
