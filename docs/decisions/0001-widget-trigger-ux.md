# ADR-0001: Widget Trigger UX — Float Default + Headless Mode

**Status:** Accepted
**Date:** 2026-04-23
**Accepted:** 2026-04-23 (three open questions resolved — see *Resolved items* below)

## Context

현재 `PhoenixReplay.UI.Components.phoenix_replay_widget/1`은 `.phx-replay-toggle` 버튼을 `position: fixed; bottom: 1rem; right: 1rem;`로 하드코딩하여 **항상 우하단 플로팅 버튼**으로 렌더합니다. 컴포넌트 attr에 위치 옵션도, 트리거를 외부에서 붙이는 방법도 없습니다.

실사용에서 이 기본값은 다른 floating UI와 충돌합니다:

- **기존 채팅 위젯이 있는 앱** — Intercom / Crisp / 자체 AI 채팅 등이 이미 우하단을 점유. 피드백 버튼이 그 위에 겹침.
- **개발 환경** — LiveView debugger pill이 같은 영역에 뜨며, 둘 다 즉시 사용 불가.
- **공개 SaaS 일반** — 대부분 웹앱이 우하단을 Intercom / Crisp / 채팅에 이미 할당.

Consumer가 할 수 있는 현재 유일한 회피책은 CSS로 `.phx-replay-toggle` 클래스를 오버라이드하는 것인데, 이는:

1. 라이브러리 내부 클래스 이름을 public API처럼 쓰도록 강요
2. 라이브러리가 클래스 이름을 바꾸는 순간 consumer 코드가 조용히 깨짐
3. "플로팅 버튼을 없애고 내 기존 UI로 여는" 유즈케이스는 아예 불가능 — JS 진입점이 노출되지 않음

트리거 UX를 정리할 필요가 생겼습니다.

## Decision

Widget에 **두 개의 모드**를 제공합니다. `mode` attr 미지정 시 `:float` (backward-compatible).

### 1. `mode={:float}` (기본, zero-config 경험 유지)

라이브러리가 우하단 플로팅 버튼을 렌더. 위치는 **`position` preset attr**과 **CSS custom properties** 두 층으로 조정:

```elixir
attr :position, :atom,
  default: :bottom_right,
  values: [:bottom_right, :bottom_left, :top_right, :top_left]
```

```css
.phx-replay-toggle {
  bottom: var(--phx-replay-toggle-bottom, 1rem);
  right:  var(--phx-replay-toggle-right,  1rem);
  top:    var(--phx-replay-toggle-top,    auto);
  left:   var(--phx-replay-toggle-left,   auto);
  z-index: var(--phx-replay-toggle-z, 1000);
}
```

- `position` preset이 네 모서리의 90% 케이스 커버
- CSS var는 fine-tune escape hatch (예: "live debugger 위 1cm만")
- consumer는 내부 클래스를 오버라이드할 필요 없음

### 2. `mode={:headless}`

라이브러리는 **패널 + 녹화 JS만** 로드하고 버튼을 렌더하지 않음. Consumer가 자신의 UI에 트리거를 배치:

- **HTML hook** — 아무 요소에 `data-phoenix-replay-trigger` 부여 → 클릭 시 패널 오픈
  ```html
  <button data-phoenix-replay-trigger>Report a bug</button>
  ```
- **JS API** — `window.PhoenixReplay.open()` / `window.PhoenixReplay.close()`
  - 자체 dropdown menu item, 키보드 shortcut (Cmd+Shift+F), contextual trigger 등 모든 UX 지원

두 모드 모두 동일한 패널/녹화/제출 파이프라인 사용. 녹화 진행/업로드 상태는 라이브러리의 in-panel UI가 처리하므로 트리거는 상태에 관여하지 않음.

CSS는 기본 로드 — panel 스타일이 두 모드 모두에 필요하기 때문. 자체 디자인 시스템으로 panel까지 완전 커스텀 스타일링하려는 consumer는 `asset_path={nil}`로 라이브러리 CSS 링크를 생략 가능.

## Why this shape

### Float은 남겨둔다
초기 통합의 강점은 "root layout 한 줄 드롭으로 작동하는 것". Headless만 있으면 consumer가 JS/HTML 트리거 세팅부터 해야 하고 README가 두 배로 길어진다.

### Headless는 필연적이다
Float만 제공하는 라이브러리에서 consumer가 결국 하는 행동은: `.phx-replay-toggle { display: none }` + 자체 버튼 + 내부 이벤트 이름을 찾아 쓰기 시작. 모든 consumer가 각자 재발명하고, 라이브러리가 클래스/이벤트 이름을 바꾸는 순간 깨진다. 공식적으로 headless를 지원하면 이 경로가 API가 된다.

### 왜 `class` passthrough / slot 패턴이 아닌가
위젯은 내부 상태(열림/닫힘, 녹화 중, 업로드 중)를 버튼 스타일로 반영한다. 외부 버튼이 이 상태를 시각화하려면 상태 이벤트를 구독해야 하고, API 표면이 훨씬 커진다. Headless에서는 consumer가 **패널을 여는 행위**만 담당하고 상태 시각화는 panel 내부에서 처리하므로 API가 최소로 유지됨.

### 왜 preset + CSS var 조합인가
Radix / shadcn-ui 계열에서 검증된 패턴. Preset은 타입 안전하고 docs가 짧고, CSS var는 디자인 시스템의 기존 토큰에 자연스럽게 섞인다. 한쪽만 있으면:
- preset만 → 경직됨 (모서리 고정, fine-tune 불가)
- CSS var만 → 발견성 낮음 (CSS 파일을 뒤져야 앎)

### 왜 `position: :custom` 같은 escape 값을 안 넣는가
CSS var가 이미 그 역할을 한다. `:custom`을 넣으면 "그 다음엔 뭘 설정해야 하지?"가 attr 영역을 떠나 CSS로 가는데, 차라리 처음부터 CSS var로 일원화가 깔끔.

## Alternatives rejected

- **현상 유지 (float only, 하드코딩 위치)** — 충돌 문제 지속. Consumer가 내부 클래스 오버라이드로 우회 → 라이브러리 리팩터 시 조용히 깨짐.
- **`position` attr만 추가 (CSS var 없음)** — 90% 커버되지만 fine-tune은 여전히 내부 클래스 오버라이드 필요.
- **CSS var만 추가 (attr 없음)** — 가장 유연하지만 "버튼 위치 바꾸려면 CSS 파일 수정해야 한다"는 인식 장벽. Elixir/LiveView만 쓰는 팀에 불편.
- **Slot / render-prop 패턴 (consumer가 버튼 JSX-스타일로 render)** — 최대 유연성이지만 내부 상태 노출 API 필요. 위에서 설명한 복잡도.
- **자동 충돌 감지 (다른 floating 요소를 피해 배치)** — 너무 magical. 디버깅 불가.
- **키보드 shortcut 기본 활성화** — discoverability 낮고, 공개 앱에 부적합. Headless 모드에서 consumer가 직접 바인딩 가능하므로 라이브러리가 기본 제공할 이유 없음.

## Consequences

### Positive

- Consumer가 internal class를 건드리지 않고 80% 커스터마이징 가능 (preset) + 나머지 20%는 CSS var로 안전하게 처리
- 자체 디자인 시스템을 가진 consumer는 headless 모드로 완전히 자기 UX에 통합
- "기존 채팅 버튼과 충돌" 케이스가 설정 한 줄로 해결
- 라이브러리 내부 클래스 이름이 public API에서 제외되어, 향후 클래스 리네임/리팩터 안전
- Headless 모드가 공식 API로 계약화되면서, 키보드 shortcut / contextual trigger / header 링크 같은 응용이 라이브러리 변경 없이 consumer 영역에서 성장 가능

### Negative

- API 표면 증가: `mode`, `position` attr, CSS var 이름 다섯 개, JS API (`open`/`close`), HTML hook (`data-phoenix-replay-trigger`) — 문서 섹션 추가 필요
- Headless 모드의 JS API (`PhoenixReplay.open()` 등)는 consumer 코드가 호출하는 순간 외부 계약이 되므로, 이름/시그니처 변경은 breaking change
- 두 모드의 integration test 스모크 둘 다 유지해야 함

### Neutral

- Backward-compatible: 기존 consumer는 `mode` 미지정 → `:float` 기본값 → 지금과 동일한 동작
- CSS var는 설정하지 않으면 기존 하드코딩과 동일한 기본값

## Scope

**In scope (이 ADR):**
- `mode :: :float | :headless` attr
- `position :: :bottom_right | :bottom_left | :top_right | :top_left` preset attr
- CSS custom properties (`--phx-replay-toggle-{bottom,right,top,left,z}`)
- `data-phoenix-replay-trigger` HTML hook
- `window.PhoenixReplay.open()` / `close()` JS API

**Out of scope (후속 ADR 후보):**
- 키보드 shortcut 기본 바인딩 (headless 모드에서 consumer가 자유롭게 설정 가능)
- Contextual trigger (특정 요소에 대한 "이것에 대한 피드백" 우클릭 메뉴)
- 모바일 제스처 (shake-to-report 등)
- Panel 상태 구독 이벤트 (`replay:opened`, `replay:closed`) — 외부 관찰자용. 필요 시 별도 ADR.

## Resolved items (decided on acceptance, 2026-04-23)

- **JS API 네임스페이스** — **Flat** (`window.PhoenixReplay.open()` / `close()`). 기존 `PhoenixReplay.init()` / `autoMount()`와 일관. 향후 player / admin API가 추가되면 그쪽을 별도 namespace(`PhoenixReplay.player.*`)로 분리하고, widget 트리거 API는 flat 유지.
- **CSS var 이름 prefix** — **`--phx-replay-toggle-*`**. Phoenix 생태계 `phx-*` 관행과 일관하며, 클래스 이름(`.phx-replay-toggle`)과 1:1 매칭되어 발견성이 높음. 더 짧은 `--replay-*`는 generic 단어라 외부 라이브러리와 충돌 위험.
- **Headless 모드 CSS 로드** — **기본 로드 + `asset_path={nil}` opt-out**. Panel 스타일은 두 모드 공통으로 필요. Toggle CSS의 dead weight(~30줄)는 무시 가능한 수준. 완전 자체 스타일링이 필요한 파워 유저는 `asset_path={nil}`로 CSS 링크 자체를 생략 (기존 attr 재활용). 파일 분리(toggle.css / panel.css)는 요구가 확인될 때까지 out of scope.

## References

- [Radix UI](https://www.radix-ui.com/) — headless component pattern 참고
- [shadcn-ui](https://ui.shadcn.com/) — preset + CSS var 조합 참고
- Linear / Sentry / Vercel dashboard — 키보드 shortcut 기반 feedback trigger 사례 (headless로 consumer가 구현 가능)
