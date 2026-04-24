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
end
