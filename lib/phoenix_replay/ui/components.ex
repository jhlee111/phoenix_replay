defmodule PhoenixReplay.UI.Components do
  @moduledoc """
  Stateless `Phoenix.Component` functions for embedding feedback UI in
  a host admin LiveView.

    * `feedback_list/1` — paginated table of feedback entries.
    * `feedback_detail/1` — single-entry detail panel with metadata,
      console/network tabs, and replay player.
    * `replay_player/1` — thin wrapper around the `rrweb-player` web
      component; requires the `player_hook.js` LiveView hook.

  Also exposes `phoenix_replay_widget/1` — the floating "Report Issue"
  button + modal that clients embed in their root layout.

  Tailwind-friendly class hooks are exposed via CSS custom properties
  so hosts can theme the widget without forking the templates.
  """

  # Implementation lands in Phase 3.
end
