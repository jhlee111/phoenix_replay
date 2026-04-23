# Plan: Widget Trigger UX — Implementation

**Status**: completed
**Started**: 2026-04-23
**Completed**: 2026-04-23
**ADR**: [0001-widget-trigger-ux](../../decisions/0001-widget-trigger-ux.md)
**Shipped in**: `0a1df5a` (Phase 1) · `eef2496` (Phase 2) · `3296106` (docs)

## Overview

Implement ADR-0001: two-mode widget trigger (float default + headless opt-in), plus `position` preset and CSS custom properties. Goal is that consumers with existing floating UI (chat widgets, dev tools) can either move the button (`position={:bottom_left}`) or disable it entirely (`mode={:headless}`) and wire their own trigger.

Two-phase rollout: Phase 1 is backward-compatible CSS/attr additions; Phase 2 is the JS architecture split. Phase 1 can ship independently if Phase 2 schedule slips.

## Phase 1 — `position` preset + CSS custom properties

**Goal**: ship the 90% fix. `mode={:float}` (default) gains four-corner preset and CSS var override. No JS architecture change yet.

### Changes

**`lib/phoenix_replay/ui/components.ex`** (component def)
- Add attr:
  ```elixir
  attr :position, :atom,
    default: :bottom_right,
    values: [:bottom_right, :bottom_left, :top_right, :top_left],
    doc: "Corner preset for the floating toggle button. Use CSS vars (--phx-replay-toggle-{bottom,right,top,left,z}) for fine-tune."
  ```
- Emit `data-position={@position}` on the `<div data-phoenix-replay>` mount element.

**`priv/static/assets/phoenix_replay.js`**
- In `renderWidget`, read `mountEl.dataset.position` (fallback `"bottom_right"`) and append modifier class when creating the toggle:
  ```js
  const positionClass = `phx-replay-toggle--${position.replace(/_/g, "-")}`;
  // button className = `phx-replay-toggle ${positionClass}`
  ```
- autoMount: read `el.dataset.position` into `cfg.position` passed to `init`.
- Extend `DEFAULTS` with `position: "bottom_right"`.

**`priv/static/assets/phoenix_replay.css`**
- Refactor `.phx-replay-toggle` to use CSS variables with `auto` fallback:
  ```css
  .phx-replay-toggle {
    position: fixed;
    bottom:  var(--phx-replay-toggle-bottom, auto);
    right:   var(--phx-replay-toggle-right,  auto);
    top:     var(--phx-replay-toggle-top,    auto);
    left:    var(--phx-replay-toggle-left,   auto);
    z-index: var(--phx-replay-toggle-z, 1000);
    /* existing visual styles unchanged */
  }
  ```
- Add four modifier classes setting the appropriate corner via vars:
  ```css
  .phx-replay-toggle--bottom-right { --phx-replay-toggle-bottom: 1rem; --phx-replay-toggle-right: 1rem; }
  .phx-replay-toggle--bottom-left  { --phx-replay-toggle-bottom: 1rem; --phx-replay-toggle-left:  1rem; }
  .phx-replay-toggle--top-right    { --phx-replay-toggle-top:    1rem; --phx-replay-toggle-right: 1rem; }
  .phx-replay-toggle--top-left     { --phx-replay-toggle-top:    1rem; --phx-replay-toggle-left:  1rem; }
  ```
- Consumer override lane (document, don't code): set vars on `.phx-replay-toggle` or any ancestor.

### Tests

- **Component render test** — render `<.phoenix_replay_widget position={:bottom_left} />`, assert `data-position="bottom_left"` on mount div. One case per preset + default.
- **CSS vars regression** — visual/CSS check: no direct assertion tooling in Elixir, so rely on hand verification in dummy test app (record in plan checklist).

### DoD

- [ ] `position` attr exists with four presets + default
- [ ] All four presets render correctly in demo/dummy host (hand-checked in browser)
- [ ] CSS vars override works: set `--phx-replay-toggle-bottom: 5rem` in consumer CSS → button moves
- [ ] Default behavior unchanged when `position` omitted
- [ ] Component test covers attr → data-attr pass-through
- [ ] CHANGELOG unreleased entry

### Non-goals

- No change to `renderWidget` structure. No panel/toggle split.
- No JS API exposure (`open`/`close` not yet public).

## Phase 2 — `mode={:headless}` + JS API

**Goal**: decouple trigger from panel. Consumer-provided triggers via `data-phoenix-replay-trigger` or `window.PhoenixReplay.open()`/`close()`.

### JS architecture refactor

Current `renderWidget(mountEl, client, cfg)` creates button + modal in one closure. Split:

```
renderPanel(mountEl, client, cfg) → { open, close, destroy }
  - creates modal DOM + form + submit handler
  - returns control API

renderToggle(mountEl, cfg, panelApi)
  - creates toggle button
  - wires click → panelApi.open
  - only called when cfg.mode === "float"
```

Expose `window.PhoenixReplay.open()` / `close()` that delegate to the first (or only) registered panel instance. For multi-mount edge case (rare), log a warning and operate on the first; don't add named-instance API in v0.

### Changes

**`lib/phoenix_replay/ui/components.ex`**
- Add attr:
  ```elixir
  attr :mode, :atom,
    default: :float,
    values: [:float, :headless],
    doc: "`:float` renders the toggle button. `:headless` renders only the panel; consumer triggers it via [data-phoenix-replay-trigger] or window.PhoenixReplay.open()."
  ```
- Emit `data-mode={@mode}` on mount div.
- Document `asset_path={nil}` opt-out for CSS (no code change; the existing `:if={@asset_path}` pattern already handles it — verify).

**`priv/static/assets/phoenix_replay.js`**
- Split `renderWidget` → `renderPanel` + `renderToggle` as above.
- In `createClient`, return `{ start, report, flush, panel }` where `panel` is the `renderPanel` result (after `init` mounts).
- Registry:
  ```js
  const instances = new Map(); // mountEl → panelApi
  ```
- Global API:
  ```js
  PhoenixReplay.open  = () => firstInstance()?.open();
  PhoenixReplay.close = () => firstInstance()?.close();
  ```
- `autoMount`: read `el.dataset.mode`, pass to `init`. Skip `renderToggle` when `"headless"`.
- Document-level delegated click listener (once, at library load):
  ```js
  document.addEventListener("click", (e) => {
    const trigger = e.target.closest("[data-phoenix-replay-trigger]");
    if (trigger) { e.preventDefault(); PhoenixReplay.open(); }
  });
  ```
  Delegation (not per-element listener) so dynamically-added triggers work without re-binding.

**`priv/static/assets/phoenix_replay.css`**
- No change. Toggle CSS becomes dead weight in headless mode (~30 lines, acceptable per ADR).

### Tests

- **Component render**:
  - `mode={:headless}` emits `data-mode="headless"`
  - `mode={:float}` (default) emits `data-mode="float"`
- **JS integration smoke** (dummy host):
  - float mode: toggle button exists, clicking opens panel
  - headless mode: no toggle button, `PhoenixReplay.open()` opens panel
  - `<button data-phoenix-replay-trigger>` click opens panel (works in both modes)
  - `PhoenixReplay.close()` closes panel
  - multi-mount: console warning emitted; first instance wins
- **Backward compat**: existing consumer (no `mode` attr) behaves identically to pre-change.

### Testing infrastructure check

The library currently has no JS unit test infrastructure (bare `priv/static/assets/*.js`, no bundler). Options:
1. **Integration only** — spin up dummy host in `test/support`, use `Wallaby` or `PhoenixTest`-style browser driver. Heavier but catches real behavior.
2. **Plain-Node unit** — add `vitest` or `mocha` to test pure JS functions (ring buffer, registry). Doesn't cover DOM wiring.
3. **Hand-verified smoke** — manual checklist in demo app during review.

**Recommendation**: (3) for Phase 2 shipping, (1) added in a separate follow-up plan if the JS surface grows. Don't block this plan on JS test infra.

### DoD

- [ ] `mode` attr exists, two values, defaults to `:float`
- [ ] `renderWidget` split into `renderPanel` + `renderToggle`
- [ ] `mode={:headless}` renders no toggle button
- [ ] `window.PhoenixReplay.open()`/`close()` work in both modes
- [ ] `[data-phoenix-replay-trigger]` click opens panel (event delegation)
- [ ] `asset_path={nil}` suppresses CSS link (verify existing code path)
- [ ] Backward compat: widget without `mode` attr identical to pre-change
- [ ] Manual smoke matrix passed on dummy host (checklist above)
- [ ] CHANGELOG unreleased entry extended

### Non-goals

- Panel state events (`replay:opened` / `replay:closed`) — deferred
- Multi-instance named API (`PhoenixReplay.open("admin-panel")`) — deferred
- Keyboard shortcut helpers — consumer wires via `window.PhoenixReplay.open()`
- Contextual trigger (right-click menu) — separate ADR if needed
- CSS file split (toggle.css / panel.css) — deferred

## Documentation (after Phase 2 DoD)

- [ ] Component `@doc` updated for `mode`, `position`, CSS vars, `asset_path: nil` opt-out
- [ ] Top-level `README.md` — add `Positioning` section (preset + CSS var) and `Headless mode` section (linking guide)
- [ ] New `docs/guides/headless-integration.md` — worked examples:
  - Custom dropdown menu item
  - Keyboard shortcut (Cmd+Shift+F)
  - Header "Feedback" link
  - Notes on `asset_path: nil` for consumers with full custom styling
- [ ] `CHANGELOG.md` unreleased section lists all public API additions

## Risks & rollback

| Risk | Mitigation |
|---|---|
| Phase 1 CSS change inadvertently alters default visual | CSS var fallback = `auto`, combined with modifier class `--bottom-right` setting same values as before → pixel-identical default. Verify in browser. |
| Phase 2 event delegation conflicts with host click handlers | `closest("[data-phoenix-replay-trigger]")` scoped to declared triggers. No globals intercepted. |
| Consumer depending on internal `.phx-replay-toggle` CSS override | If modifier class shifted specificity, overrides might stop working. ADR already positions internal class as non-public, but call out in CHANGELOG. |
| Global `window.PhoenixReplay.open/close` as public contract | From Phase 2 onward these are breaking-change protected. Note explicitly. |

Rollback: `git revert` each phase's commits. No migrations, no storage touches. Consumers on Phase 1 keep working; Phase 2 revert restores the pre-split JS.

## Follow-ups (separate plans/ADRs)

- **ADR-0002 candidate**: on-demand recording mode (Jam-style "start reproduction")
- **ADR-0003 candidate**: microphone narration
- **Plan**: JS test infrastructure if surface keeps growing
- **Plan**: panel state events (`replay:opened` / `replay:closed`) if a consumer requests
