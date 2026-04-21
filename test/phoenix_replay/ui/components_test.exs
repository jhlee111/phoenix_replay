defmodule PhoenixReplay.UI.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixReplay.UI.Components

  describe "phoenix_replay_widget/1" do
    test "renders mount div with required data attributes" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/api/feedback",
          csrf_token: "test-token-abc"
        )

      assert html =~ ~s(data-phoenix-replay)
      assert html =~ ~s(data-base-path="/api/feedback")
      assert html =~ ~s(data-csrf-token="test-token-abc")
      assert html =~ ~s(data-widget-text="Report issue")
    end

    test "includes the stylesheet and client JS" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/api/feedback",
          csrf_token: "x"
        )

      assert html =~ ~s(<link rel="stylesheet" href="/phoenix_replay/phoenix_replay.css")
      assert html =~ ~s(src="/phoenix_replay/phoenix_replay.js")
    end

    test "includes rrweb + console plugin scripts by default (CDN)" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ "unpkg.com/rrweb@2.0.0-alpha.18/dist/rrweb.umd.cjs"
      assert html =~ "rrweb-plugin-console-record"
      # Network plugin is not shipped as a default — no separate npm package
      # at this rrweb version. Hosts can opt in via `rrweb_network_src`.
      refute html =~ "rrweb-plugin-network-record"
    end

    test "network plugin script emitted when rrweb_network_src is passed" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          rrweb_network_src: "/assets/my-network-plugin.js"
        )

      assert html =~ ~s(src="/assets/my-network-plugin.js")
    end

    test "rrweb scripts can be disabled by passing nil sources" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          rrweb_src: nil,
          rrweb_console_src: nil,
          rrweb_network_src: nil
        )

      refute html =~ "rrweb"
      # Core widget JS still present
      assert html =~ "phoenix_replay.js"
    end

    test "widget_text and asset_path are customizable" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/api/feedback",
          csrf_token: "x",
          widget_text: "Send feedback",
          asset_path: "/assets/phx_replay"
        )

      assert html =~ ~s(data-widget-text="Send feedback")
      assert html =~ ~s(href="/assets/phx_replay/phoenix_replay.css")
      assert html =~ ~s(src="/assets/phx_replay/phoenix_replay.js")
    end
  end
end
