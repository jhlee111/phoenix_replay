defmodule PhoenixReplay.UI.FeedbackLive do
  @moduledoc """
  Optional zero-config admin LiveView. Hosts opt in via
  `feedback_routes path, admin_live: true`.

  Embeds `PhoenixReplay.UI.Components.feedback_list/1` +
  `feedback_detail/1`. Hosts that want custom admin UX should ignore
  this module and compose the components themselves.
  """

  # Implementation lands in Phase 3.
end
