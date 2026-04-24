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
      |> patch_router()
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

    # --- Router patcher ---------------------------------------------

    defp patch_router(igniter) do
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      if router do
        igniter
        |> ensure_router_import(router)
        |> ensure_pipeline(router, :feedback_ingest, """
        plug :accepts, ["json"]
        plug :fetch_session
        plug :protect_from_forgery
        """)
        |> ensure_pipeline(router, :admin_json, """
        plug :accepts, ["json"]
        plug :fetch_session
        """)
        |> ensure_scope_with_macro(router, "/", :feedback_ingest, :feedback_routes)
        |> ensure_scope_with_macro(router, "/admin", :admin_json, :admin_routes)
      else
        Igniter.add_warning(igniter, """
        No Phoenix router found. Add the following manually to your router:

            import PhoenixReplay.Router

            pipeline :feedback_ingest do
              plug :accepts, ["json"]
              plug :fetch_session
              plug :protect_from_forgery
            end

            pipeline :admin_json do
              plug :accepts, ["json"]
              plug :fetch_session
            end

            scope "/" do
              pipe_through :feedback_ingest
              feedback_routes "/api/feedback"
            end

            scope "/admin" do
              pipe_through :admin_json
              admin_routes "/feedback"
            end
        """)
      end
    end

    defp ensure_router_import(igniter, router) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Code.Common.move_to(zipper, fn z ->
               Igniter.Code.Function.function_call?(z, :import, 1) and
                 Igniter.Code.Function.argument_equals?(z, 0, PhoenixReplay.Router)
             end) do
          {:ok, _} ->
            {:ok, zipper}

          :error ->
            # Place the import right after a `use Phoenix.Router` or
            # `use <WebModule>, :router` call. We scan with a single
            # predicate so both arities match.
            case Igniter.Code.Common.move_to(zipper, &use_router_call?/1) do
              {:ok, use_zipper} ->
                {:ok,
                 Igniter.Code.Common.add_code(
                   use_zipper,
                   "import PhoenixReplay.Router",
                   placement: :after
                 )}

              :error ->
                {:warning,
                 "Could not find a `use ..., :router` (or `use Phoenix.Router`) call in " <>
                   "#{inspect(router)}. Add `import PhoenixReplay.Router` manually."}
            end
        end
      end)
    end

    defp use_router_call?(zipper) do
      cond do
        # `use <WebModule>, :router`
        Igniter.Code.Function.function_call?(zipper, :use, 2) ->
          Igniter.Code.Function.argument_equals?(zipper, 1, :router)

        # `use Phoenix.Router`
        Igniter.Code.Function.function_call?(zipper, :use, 1) ->
          Igniter.Code.Function.argument_equals?(zipper, 0, Phoenix.Router)

        true ->
          false
      end
    end

    defp ensure_pipeline(igniter, router, name, contents) do
      case Igniter.Libs.Phoenix.has_pipeline(igniter, router, name) do
        {igniter, true} ->
          igniter

        {igniter, false} ->
          Igniter.Libs.Phoenix.add_pipeline(igniter, name, contents,
            router: router,
            warn_on_present?: false
          )
      end
    end

    defp ensure_scope_with_macro(igniter, router, route, pipeline, macro_name) do
      # Skip if any `<macro_name>(...)` call exists in the router. The
      # caller passes a function name like `:feedback_routes` — we
      # don't try to verify the route arg matches; if a host already
      # invoked the macro, we trust their wiring.
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Code.Function.move_to_function_call(zipper, macro_name, :any) do
          {:ok, _} ->
            {:ok, zipper}

          _ ->
            scope_block = """
            scope #{inspect(route)} do
              pipe_through #{inspect(pipeline)}
              #{macro_name}(#{inspect(scope_arg_for(macro_name))})
            end
            """

            {:ok, Igniter.Code.Common.add_code(zipper, scope_block, placement: :after)}
        end
      end)
    end

    defp scope_arg_for(:feedback_routes), do: "/api/feedback"
    defp scope_arg_for(:admin_routes), do: "/feedback"
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
