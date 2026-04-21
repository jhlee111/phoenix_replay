defmodule Mix.Tasks.PhoenixReplay.Install do
  @shortdoc "Copies the PhoenixReplay migration into priv/repo/migrations"

  @moduledoc """
  Copies the PhoenixReplay migration into your application's
  `priv/repo/migrations` directory.

  ## Usage

      mix phoenix_replay.install

  Creates one migration that defines the two tables
  `phoenix_replay_feedbacks` + `phoenix_replay_events`.

  ## Options

    * `--repo` (`-r`) — Ecto repo the migration targets. Defaults to the
      first repo listed under `config :my_app, :ecto_repos`.

  After running this task, apply the migration with:

      mix ecto.migrate
  """

  use Mix.Task

  @template_path "priv/templates/phoenix_replay.install/migrations/create_phoenix_replay_tables.ex"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _} = OptionParser.parse!(args, strict: [repo: :string], aliases: [r: :repo])

    repo = resolve_repo(opts)
    migrations_path = migrations_path(repo)
    timestamp = timestamp()
    module = Module.concat([repo, Migrations, "CreatePhoenixReplayTables"])

    File.mkdir_p!(migrations_path)
    target_file = Path.join(migrations_path, "#{timestamp}_create_phoenix_replay_tables.exs")

    if File.exists?(target_file) do
      Mix.shell().info([:yellow, "* skipping ", :reset, Path.relative_to_cwd(target_file)])
    else
      contents =
        :phoenix_replay
        |> Application.app_dir(@template_path)
        |> File.read!()
        |> EEx.eval_string(assigns: [module: module])

      File.write!(target_file, contents)
      Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(target_file)])
    end

    Mix.shell().info([
      :cyan,
      "\nRun ",
      :reset,
      "mix ecto.migrate",
      :cyan,
      " to apply the migration."
    ])
  end

  defp resolve_repo(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo_str} ->
        Module.concat([repo_str])

      :error ->
        case Mix.Project.config()[:app] do
          nil ->
            Mix.raise(
              "Could not infer Ecto repo; pass --repo MyApp.Repo"
            )

          app ->
            case Application.get_env(app, :ecto_repos, []) do
              [repo | _] ->
                repo

              [] ->
                Mix.raise(
                  "No Ecto repos configured for :#{app}. Pass --repo MyApp.Repo."
                )
            end
        end
    end
  end

  defp migrations_path(repo) do
    priv = repo.config()[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"
    Path.join(priv, "migrations")
  end

  defp timestamp do
    {{y, m, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, h, mi, s])
    |> IO.iodata_to_binary()
  end
end
