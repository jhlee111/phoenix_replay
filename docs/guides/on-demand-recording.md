# On-demand recording

By default, `phoenix_replay_widget` starts capturing rrweb events the
moment the widget mounts (`recording={:continuous}`). Users get
retroactive reporting — they see a bug, click the toggle, describe
what happened, and the preceding events are already on disk.

`recording={:on_demand}` inverts that contract: the recorder stays
idle until the user explicitly asks for it. Nothing is captured
until a Start click happens, and the session handshake itself is
deferred. Sessions that never lead to a reproduction create no
server state.

This guide covers when to reach for which, the two flows (`:float`
and `:headless`) end-to-end, and the smaller scope notes that tend
to surprise consumers.

## When to use which

| | `:continuous` | `:on_demand` |
|---|---|---|
| Captures events from page load | yes | no — only after Start |
| Session handshake fires at | widget mount | Start click / `startRecording()` |
| Retroactive "I already saw it" reports | yes | no |
| Runtime overhead when idle | rrweb instrumentation + flush timer | none |
| Typical consumer stance on privacy/consent | implicit, disclosed in privacy policy | explicit per-session, opt-in |

Pick `:continuous` when the product's value proposition depends on
catching bugs the user can't reproduce on demand — most internal
tools and staging environments. Pick `:on_demand` when consent must
be explicit per session (regulated verticals, customer-facing beta
programs) or when the baseline rrweb cost is itself unacceptable
(very large apps, constrained devices). `:on_demand` can always be
upgraded to `:continuous` later; the opposite direction is a
privacy-policy change.

## `:float` flow

The float toggle is the zero-glue path. Pass `recording={:on_demand}`
and the library orchestrates the rest:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  recording={:on_demand}
/>
```

User journey:

1. Page mounts. Toggle is visible, recorder is idle, no `/session`
   request has fired.
2. User clicks the toggle → panel opens on the **Start reproduction**
   screen with a short explanation.
3. User clicks **Start** → `/session` handshake fires, rrweb begins
   capturing, the panel closes, the toggle is replaced by a
   **Recording…** pill with a Stop button.
4. User reproduces the issue.
5. User clicks **Stop** in the pill → recorder halts, buffer flushes,
   panel reopens on the submit form.
6. User fills the form and submits → report persists, session
   closes, panel disappears, toggle returns to the idle state.

If the Start click fails (e.g., `/session` returns 401/403/500), the
panel flips to an error screen with a **Retry** button — Start
consent must not be silently ignored.

### Positioning the pill

The pill defaults to the same corner as the toggle. If the toggle
is bottom-right, the pill appears bottom-right. Override
independently via CSS custom properties on `.phx-replay-pill` (or any
ancestor):

```css
.phx-replay-pill {
  --phx-replay-pill-bottom: 5rem; /* float above a footer bar */
}
```

Or override the toggle's corner to move the pill with it:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  recording={:on_demand}
  position={:top_right}
/>
```

The `--phx-replay-pill-*` family (`bottom`, `right`, `top`, `left`,
`z`) mirrors the toggle's `--phx-replay-toggle-*` family so hosts can
keep them in lock-step or split them apart.

## `:headless` flow

When you want to drive the Start/Stop UX yourself — a custom consent
modal, an admin-only panel, a keyboard shortcut — use `:headless`
plus `:on_demand`. The library's submit form is still available;
you just own everything before it.

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  mode={:headless}
  recording={:on_demand}
/>
```

Two integration shapes:

### 1. Library-rendered Start CTA

Call `window.PhoenixReplay.open()` from anywhere — a menu item, a
keyboard shortcut, a trigger element. While recording is idle, the
panel opens on the Start screen; once recording has started, the
same `open()` call routes to the submit form.

```heex
<button type="button" data-phoenix-replay-trigger>
  Report a bug
</button>
```

The user sees the same Start → Stop → Submit flow as `:float`; the
only missing piece is the pill, which is `:float`-only. Render your
own recording indicator if you want one.

### 2. Fully custom Start UX

For a custom consent modal or a one-tap workflow, bypass the panel's
Start screen by calling `window.PhoenixReplay.startRecording()`
before (or instead of) `open()`. Recording begins without any
library UI; when you call `stopRecording()`, the panel opens on the
submit form so the user lands in the library's report flow:

```js
async function beginCustomReproduction() {
  try {
    await window.PhoenixReplay.startRecording();
    showHostIndicator(); // your own recording pill, banner, etc.
  } catch (err) {
    showHostError(err);
  }
}

async function endCustomReproduction() {
  hideHostIndicator();
  await window.PhoenixReplay.stopRecording();
  // Library panel is now open on the submit form.
}
```

`startRecording()` returns a promise that rejects on `/session`
failure so your UI can surface the error however you like — the
library's error screen only fires for the library's own Start button.

## Multi-tab scope

On-demand recording is tab-local. Each tab is its own idle/active
state; calling `startRecording()` in tab A does not start recording
in tab B. This matches how `:continuous` widgets behave (each tab
mints its own session) and keeps the library's behavior predictable
without server-side coordination.

If you need cross-tab coordination — e.g., "when the user starts a
reproduction in one tab, show the recording indicator in all other
tabs" — layer `BroadcastChannel` on top of the JS API. The library
doesn't ship this because the right UX is consumer-specific (should
other tabs auto-start? just show an indicator? block new sessions?).

## Related

- [ADR-0002: On-demand recording](../decisions/0002-on-demand-recording.md)
- [Headless integration](headless-integration.md) — non-recording
  knobs for `:headless` mode
