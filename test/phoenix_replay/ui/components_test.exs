defmodule PhoenixReplay.UI.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixReplay.UI.Components

  describe "admin components" do
    test "phoenix_replay_admin_assets emits stylesheets + player hook" do
      html = render_component(&phoenix_replay_admin_assets/1, [])

      assert html =~ "phoenix_replay_admin.css"
      assert html =~ "player_hook.js"
      assert html =~ "rrweb-player@"
    end

    test "phoenix_replay_admin_assets can disable player assets" do
      html =
        render_component(&phoenix_replay_admin_assets/1, player_src: nil, player_style_src: nil)

      refute html =~ "rrweb-player"
      assert html =~ "player_hook.js"
    end

    test "feedback_list renders empty state when entries is []" do
      html = render_component(&feedback_list/1, entries: [])
      assert html =~ "No feedback yet"
    end

    test "feedback_list renders one row per entry with click bindings" do
      entries = [
        %{
          id: "fbk_1",
          severity: "high",
          description: "broken",
          session_id: "sess_x",
          identity: %{"kind" => "user", "id" => "u1", "attrs" => %{"email" => "a@b.com"}},
          inserted_at: ~U[2026-04-21 04:15:00Z]
        }
      ]

      html = render_component(&feedback_list/1, entries: entries)
      assert html =~ "broken"
      assert html =~ "a@b.com"
      assert html =~ ~s(phx-click="select_feedback")
      assert html =~ ~s(phx-value-id="fbk_1")
      assert html =~ "severity-high"
    end

    test "feedback_detail shows description, metadata, and replay player" do
      entry = %{
        id: "fbk_1",
        severity: "low",
        description: "something off",
        session_id: "sess_abc",
        identity: %{"kind" => "user", "id" => "u", "attrs" => %{"email" => "x@y"}},
        metadata: %{"interface" => "admin", "user_agent" => "curl"},
        inserted_at: ~U[2026-04-21 04:15:00Z]
      }

      html =
        render_component(&feedback_detail/1,
          entry: entry,
          events_url: "/admin/feedback/events/sess_abc"
        )

      assert html =~ "something off"
      assert html =~ "admin"
      assert html =~ "curl"
      assert html =~ "data-phoenix-replay-player"
      assert html =~ "data-events-url=\"/admin/feedback/events/sess_abc\""
    end

    test "feedback_detail hides the player when hide_player is true" do
      entry = %{id: "x", description: "d", metadata: %{}, identity: %{}}

      html =
        render_component(&feedback_detail/1,
          entry: entry,
          events_url: "/x",
          hide_player: true
        )

      refute html =~ "data-phoenix-replay-player"
    end

    test "replay_player emits mount div with events_url" do
      html = render_component(&replay_player/1, events_url: "/admin/feedback/events/abc")
      assert html =~ "data-phoenix-replay-player"
      assert html =~ "data-events-url=\"/admin/feedback/events/abc\""
      assert html =~ ~s(phx-update="ignore")
    end
  end

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

    test "position defaults to bottom_right" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-position="bottom_right")
    end

    test "position preset flows to data-position attr" do
      for preset <- [:bottom_left, :top_right, :top_left] do
        html =
          render_component(&phoenix_replay_widget/1,
            base_path: "/x",
            csrf_token: "x",
            position: preset
          )

        assert html =~ ~s(data-position="#{preset}")
      end
    end

    test "mode defaults to float" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-mode="float")
    end

    test "mode={:headless} flows to data-mode attr" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          mode: :headless
        )

      assert html =~ ~s(data-mode="headless")
    end

    test "show_severity defaults to false" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-show-severity="false")
    end

    test "show_severity={true} flows to data-show-severity attr" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          show_severity: true
        )

      assert html =~ ~s(data-show-severity="true")
    end

    test "allow_paths defaults to both paths CSV" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-allow-paths="report_now,record_and_report")
    end

    test "allow_paths can be restricted to a single path" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          allow_paths: [:report_now]
        )

      assert html =~ ~s(data-allow-paths="report_now")
    end

    test "buffer_window_seconds defaults to 60" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x"
        )

      assert html =~ ~s(data-buffer-window-seconds="60")
    end

    test "buffer_window_seconds is host-tunable" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          buffer_window_seconds: 120
        )

      assert html =~ ~s(data-buffer-window-seconds="120")
    end

    test "asset_path={nil} suppresses stylesheet and script tags" do
      html =
        render_component(&phoenix_replay_widget/1,
          base_path: "/x",
          csrf_token: "x",
          asset_path: nil
        )

      refute html =~ "phoenix_replay.css"
      refute html =~ "phoenix_replay.js"
      # mount div still present — host is expected to self-host library JS
      assert html =~ ~s(data-phoenix-replay)
    end
  end
end
