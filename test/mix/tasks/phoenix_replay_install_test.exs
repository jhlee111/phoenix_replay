defmodule Mix.Tasks.PhoenixReplay.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "config block patcher" do
    test "inserts session_token_secret, identify, and storage entries on a fresh project" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])

      igniter
      |> assert_has_patch("config/config.exs", """
      | config :phoenix_replay,
      """)
      |> assert_has_patch("config/config.exs", """
      | session_token_secret:
      """)
      |> assert_has_patch("config/config.exs", """
      | identify:
      """)
      |> assert_has_patch("config/config.exs", """
      | storage:
      """)
    end

    test "is idempotent — re-running over its own output produces no further changes" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "phoenix_replay.install", [])

      assert_unchanged(second, "config/config.exs")
    end

    test "leaves an existing :phoenix_replay session_token_secret alone" do
      igniter =
        test_project(
          app_name: :test_app,
          files: %{
            "config/config.exs" => """
            import Config

            config :phoenix_replay, session_token_secret: "ALREADY_SET"
            """
          }
        )
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      content = Rewrite.source!(igniter.rewrite, "config/config.exs") |> Rewrite.Source.get(:content)
      assert content =~ ~s(session_token_secret: "ALREADY_SET")
      refute content =~ "REPLACE_ME_WITH_A_RANDOM_SECRET"
    end
  end

  describe "router patcher" do
    @router_path "lib/test_app_web/router.ex"
    @router_module """
    defmodule TestAppWeb.Router do
      use Phoenix.Router

      pipeline :browser do
        plug :accepts, ["html"]
      end

      scope "/", TestAppWeb do
        pipe_through :browser
      end
    end
    """

    test "adds import + pipelines + scopes on a fresh router" do
      igniter =
        test_project(app_name: :test_app, files: %{@router_path => @router_module})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      content =
        igniter.rewrite
        |> Rewrite.source!(@router_path)
        |> Rewrite.Source.get(:content)

      assert content =~ "import PhoenixReplay.Router"
      assert content =~ "pipeline :feedback_ingest"
      assert content =~ "pipeline :admin_json"
      assert content =~ ~s|feedback_routes("/api/feedback")|
      assert content =~ ~s|admin_routes("/feedback")|
    end

    test "is idempotent — re-running over its own output leaves the router alone" do
      first =
        test_project(app_name: :test_app, files: %{@router_path => @router_module})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "phoenix_replay.install", [])

      assert_unchanged(second, @router_path)
    end
  end

  describe "endpoint patcher" do
    @endpoint_path "lib/test_app_web/endpoint.ex"
    @endpoint_module """
    defmodule TestAppWeb.Endpoint do
      use Phoenix.Endpoint, otp_app: :test_app

      plug Plug.Static,
        at: "/",
        from: :test_app,
        gzip: false,
        only: ~w(assets)

      plug TestAppWeb.Router
    end
    """

    test "adds Plug.Static for /phoenix_replay on a fresh endpoint" do
      igniter =
        test_project(app_name: :test_app, files: %{@endpoint_path => @endpoint_module})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      content =
        igniter.rewrite
        |> Rewrite.source!(@endpoint_path)
        |> Rewrite.Source.get(:content)

      assert content =~ ~s|at: "/phoenix_replay"|
      assert content =~ ":phoenix_replay"
    end

    test "is idempotent — re-running leaves the endpoint alone" do
      first =
        test_project(app_name: :test_app, files: %{@endpoint_path => @endpoint_module})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "phoenix_replay.install", [])
      assert_unchanged(second, @endpoint_path)
    end
  end

  describe "root layout widget injection" do
    @layout_path "lib/test_app_web/components/layouts/root.html.heex"
    @layout_html """
    <!DOCTYPE html>
    <html>
      <head>
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """

    test "injects the widget snippet before </body>" do
      igniter =
        test_project(app_name: :test_app, files: %{@layout_path => @layout_html})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      content =
        igniter.rewrite
        |> Rewrite.source!(@layout_path)
        |> Rewrite.Source.get(:content)

      assert content =~ "phoenix_replay widget"
      assert content =~ "PhoenixReplay.UI.Components.phoenix_replay_widget"
      assert content =~ ":widget_enabled"
      # Snippet appears before the closing tag — order check.
      assert String.split(content, "</body>") |> hd() =~ "phoenix_replay widget"
    end

    test "is idempotent — re-running leaves the layout alone" do
      first =
        test_project(app_name: :test_app, files: %{@layout_path => @layout_html})
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "phoenix_replay.install", [])
      assert_unchanged(second, @layout_path)
    end
  end

  describe "Identify stub generator" do
    test "creates HostApp.Feedback.Identify with fetch_identity/1 + fetch_metadata/1" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      identify_path = "lib/test_app/feedback/identify.ex"

      content =
        igniter.rewrite
        |> Rewrite.source!(identify_path)
        |> Rewrite.Source.get(:content)

      assert content =~ "defmodule TestApp.Feedback.Identify"
      assert content =~ "def fetch_identity"
      assert content =~ "def fetch_metadata"
      assert content =~ ":anonymous"
    end

    test "is idempotent — re-running doesn't re-create the stub" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "phoenix_replay.install", [])
      assert_unchanged(second, "lib/test_app/feedback/identify.ex")
    end
  end

  describe "migration generator" do
    test "creates the create_phoenix_replay_tables migration" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      migration_path =
        igniter.rewrite.sources
        |> Map.keys()
        |> Enum.find(&String.ends_with?(&1, "_create_phoenix_replay_tables.exs"))

      assert migration_path,
             "expected a *_create_phoenix_replay_tables.exs migration to be generated"

      content =
        igniter.rewrite
        |> Rewrite.source!(migration_path)
        |> Rewrite.Source.get(:content)

      assert content =~ "defmodule TestApp.Repo.Migrations.CreatePhoenixReplayTables"
      assert content =~ "create table(:phoenix_replay_feedbacks"
      assert content =~ "create table(:phoenix_replay_events"
      assert content =~ "create table(:phoenix_replay_feedback_comments"
    end

    test "is idempotent — re-running over its own output adds no new migration" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      first_paths = first.rewrite.sources |> Map.keys() |> Enum.sort()

      second =
        first
        |> Igniter.compose_task("phoenix_replay.install", [])
        |> apply_igniter!()

      second_paths = second.rewrite.sources |> Map.keys() |> Enum.sort()

      assert first_paths == second_paths,
             "second run added or removed files: #{inspect(second_paths -- first_paths)}"
    end
  end
end
