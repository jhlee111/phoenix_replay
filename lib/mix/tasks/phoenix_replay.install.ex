if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.PhoenixReplay.Install do
    @example "mix igniter.install phoenix_replay"
    @shortdoc "Installs phoenix_replay into a Phoenix project"

    @moduledoc """
    Installs `phoenix_replay` into a Phoenix project.

    ## Recommended

        #{@example}

    Igniter adds `phoenix_replay` to your deps, fetches it, and runs
    this installer. After this task completes, fill in the two
    `# TODO:` comments in `config/config.exs` (`session_token_secret`
    and the `identify` callback module) and run `mix ecto.migrate`.

    ## What it does

      1. Inserts a `:phoenix_replay` config block in `config/config.exs`
         with sensible defaults plus TODO markers for the two values
         you must fill in.

    More patchers (router, endpoint, root layout, identity stub,
    migration copy) land in the next phases of ADR-5f.

    ## Manual install

    If you've already added `{:phoenix_replay, ...}` to your `mix.exs`
    yourself:

        mix phoenix_replay.install
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_replay,
        example: @example,
        schema: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_phoenix_replay()
    end

    defp configure_phoenix_replay(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)

      igniter
      |> ensure_config(
        :session_token_secret,
        quote do
          # TODO: replace with a real secret from environment, e.g.
          # System.fetch_env!("PHOENIX_REPLAY_TOKEN_SALT")
          "REPLACE_ME_WITH_A_RANDOM_SECRET"
        end
      )
      |> ensure_config(
        :identify,
        quote do
          # TODO: implement and configure the identity callback. Receives
          # the Plug.Conn and must return a map shaped
          # `%{kind: :user | :api_key | :anonymous, id: String.t() | nil,
          #    attrs: map()}` or `nil` to reject the session with 401.
          {unquote(host_module_alias(app_name)).Feedback.Identify, :fetch_identity, []}
        end
      )
      |> ensure_config(
        :storage,
        quote do
          {PhoenixReplay.Storage.Ecto,
           [repo: unquote(host_module_alias(app_name)).Repo]}
        end
      )
    end

    defp ensure_config(igniter, key, value_ast) do
      if Igniter.Project.Config.configures_key?(
           igniter,
           "config.exs",
           :phoenix_replay,
           key
         ) do
        igniter
      else
        Igniter.Project.Config.configure(
          igniter,
          "config.exs",
          :phoenix_replay,
          [key],
          {:code, value_ast}
        )
      end
    end

    defp host_module_alias(app_name) do
      app_name
      |> Atom.to_string()
      |> Macro.camelize()
      |> List.wrap()
      |> Module.concat()
    end
  end
else
  defmodule Mix.Tasks.PhoenixReplay.Install do
    @shortdoc "Installs phoenix_replay (requires igniter)"

    @moduledoc """
    Installs phoenix_replay into your project.

    Requires Igniter. Add `{:igniter, "~> 0.7"}` to your deps and run
    `mix deps.get`, then re-run this task. Or use the recommended one-
    shot:

        mix igniter.install phoenix_replay
    """

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task `phoenix_replay.install` requires Igniter for automatic
      configuration. Install it with:

          {:igniter, "~> 0.7"}

      and re-run, or use the one-shot:

          mix igniter.install phoenix_replay

      See https://hexdocs.pm/igniter for details.
      """)

      exit({:shutdown, 1})
    end
  end
end
