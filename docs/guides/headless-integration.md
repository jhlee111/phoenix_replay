# Headless integration

When `mode={:headless}` is passed to `phoenix_replay_widget/1`, the
library renders the panel (modal + form) but not the floating toggle
button. Your application supplies the trigger. This guide shows the
common shapes.

All examples assume the widget is mounted in your root layout:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  mode={:headless}
/>
```

## 1. Header or menu link

The simplest case — a link that opens the panel when clicked. Any
element with `[data-phoenix-replay-trigger]` is wired automatically
via delegated click.

```heex
<nav>
  <a href="#" data-phoenix-replay-trigger>Feedback</a>
</nav>
```

Because the listener is registered at the `document` level, LiveView
patches, dropdown menus that open/close, and dynamically inserted
links all work without extra wiring.

Use semantic markup (`<button>` for actions) when appropriate:

```heex
<li>
  <button type="button" data-phoenix-replay-trigger class="menu-item">
    <.icon name="hero-bug-ant" /> Report an issue
  </button>
</li>
```

## 2. Keyboard shortcut

For power-user or internal-tool scenarios, a global shortcut is often
the right trigger. Bind from your own JS (or a LiveView `handleEvent`)
and call `window.PhoenixReplay.open()`.

```js
// app.js
document.addEventListener("keydown", (e) => {
  const mod = navigator.platform.startsWith("Mac") ? e.metaKey : e.ctrlKey;
  if (mod && e.shiftKey && e.key.toLowerCase() === "f") {
    e.preventDefault();
    window.PhoenixReplay.open();
  }
});
```

Guidance: avoid binding shortcuts that conflict with host-app
shortcuts (e.g., don't hijack `Cmd+K` if your app already uses it for
a command palette).

## 3. Contextual trigger inside a modal or error boundary

When a user hits an error state, a "Report this" prompt right where
the error happens is higher-signal than a floating button they'd have
to remember to click.

```heex
<div :if={@error} class="error-state">
  <p>Something went wrong.</p>
  <button type="button" data-phoenix-replay-trigger class="link">
    Report this to support
  </button>
</div>
```

For programmatic control — e.g., pre-fill the description from the
error context — read the error from your app state, call
`PhoenixReplay.open()`, and populate the textarea manually:

```js
function reportError(summary) {
  const textarea = document.querySelector(
    ".phx-replay-modal-panel textarea[name=description]"
  );
  if (textarea) textarea.value = `Context: ${summary}\n\n`;
  window.PhoenixReplay.open();
}
```

(Pre-filling is best-effort today; a first-class `open({prefill: ...})`
API may land in a future release.)

## 4. Self-hosting library assets

If you bundle JS/CSS through your own pipeline (esbuild, Webpack, Vite,
etc.) and want to avoid the two `<script>` + `<link>` tags the widget
injects, pass `asset_path={nil}`:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  mode={:headless}
  asset_path={nil}
/>
```

This suppresses both the stylesheet link and the library JS script
tag. You become responsible for:

- Serving (or importing) `phoenix_replay.js` so it runs before the
  page settles — typical integration:
  ```js
  // assets/js/app.js
  import "phoenix_replay/priv/static/assets/phoenix_replay.js";
  ```
- Either serving `phoenix_replay.css` yourself, or writing your own
  styles from scratch targeting `.phx-replay-modal`,
  `.phx-replay-modal-panel`, `.phx-replay-actions`, and the form
  controls.

Most hosts don't need this — the default `asset_path="/phoenix_replay"`
with `Plug.Static` is simpler. Opt in only when you have a concrete
reason.

## 5. One-widget-per-page assumption

`window.PhoenixReplay.open()` / `close()` act on the first mounted
widget. Mounting multiple widgets emits a console warning and the
global API operates on whichever one initialized first. If you have a
legitimate multi-widget scenario (e.g., an admin preview pane that
itself needs a feedback widget), let us know — a named-instance API
could land in a future release.

## Reference

- Component attrs: `mode`, `position`, `asset_path`, and all others
  are documented on `PhoenixReplay.UI.Components.phoenix_replay_widget/1`.
- Design rationale: see
  [ADR-0001](../decisions/0001-widget-trigger-ux.md).
