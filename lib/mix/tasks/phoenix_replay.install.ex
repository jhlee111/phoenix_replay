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
      |> patch_endpoint()
      |> inject_widget_into_root_layout()
      |> generate_identify_stub()
      |> generate_migration()
      |> Igniter.add_notice("""

      phoenix_replay install complete. Two TODOs to finish before booting:

        1. config/config.exs: replace REPLACE_ME_WITH_A_RANDOM_SECRET with a
           real `:session_token_secret` (e.g. `System.fetch_env!(...)`).
        2. lib/<app>/feedback/identify.ex: implement `fetch_identity/1`
           against your auth (default returns `:anonymous`).

      Then run `mix ecto.migrate` and flip `widget_enabled: true` in
      config to start capturing.
      """)
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

    # --- Endpoint patcher -------------------------------------------

    defp patch_endpoint(igniter) do
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter)

      if endpoint do
        Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
          if phoenix_replay_static_present?(zipper) do
            {:ok, zipper}
          else
            # Place the new Plug.Static immediately after `use
            # Phoenix.Endpoint`. Order vs. the host's existing
            # `Plug.Static, at: "/"` doesn't matter for routing
            # (different `at:` prefix) but earlier-in-pipeline plays
            # well with admin tools that probe early.
            case Igniter.Code.Common.move_to(zipper, &use_phoenix_endpoint?/1) do
              {:ok, use_zipper} ->
                {:ok,
                 Igniter.Code.Common.add_code(
                   use_zipper,
                   ~s|plug Plug.Static, at: "/phoenix_replay", from: {:phoenix_replay, "priv/static/assets"}|,
                   placement: :after
                 )}

              :error ->
                {:warning,
                 "Could not find `use Phoenix.Endpoint` in #{inspect(endpoint)}. " <>
                   "Add the Plug.Static line manually."}
            end
          end
        end)
      else
        Igniter.add_warning(igniter, """
        No Phoenix endpoint found. Add the following to your endpoint module:

            plug Plug.Static,
              at: "/phoenix_replay",
              from: {:phoenix_replay, "priv/static/assets"}
        """)
      end
    end

    defp phoenix_replay_static_present?(zipper) do
      case Igniter.Code.Common.move_to(zipper, fn z ->
             Igniter.Code.Function.function_call?(z, :plug, 2) and
               Igniter.Code.Function.argument_equals?(z, 0, Plug.Static) and
               static_args_match_phoenix_replay?(z)
           end) do
        {:ok, _} -> true
        _ -> false
      end
    end

    defp static_args_match_phoenix_replay?(zipper) do
      case Igniter.Code.Function.move_to_nth_argument(zipper, 1) do
        {:ok, arg_zipper} ->
          arg_zipper
          |> Sourceror.Zipper.node()
          |> Macro.to_string()
          |> String.contains?(":phoenix_replay")

        _ ->
          false
      end
    end

    defp use_phoenix_endpoint?(zipper) do
      Igniter.Code.Function.function_call?(zipper, :use, 2) and
        Igniter.Code.Function.argument_equals?(zipper, 0, Phoenix.Endpoint)
    end

    # --- Root layout widget injection -------------------------------

    @widget_marker "<%!-- phoenix_replay widget --%>"
    @widget_snippet """
    <%!-- phoenix_replay widget --%>
    <%= if Application.get_env(:phoenix_replay, :widget_enabled, false) do %>
      <PhoenixReplay.UI.Components.phoenix_replay_widget
        base_path="/api/feedback"
        csrf_token={get_csrf_token()}
      />
    <% end %>
    """

    # --- Identify stub ----------------------------------------------

    defp generate_identify_stub(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      host_module = host_module_alias(app_name)
      identify_module = Module.concat([host_module, "Feedback", "Identify"])

      case Igniter.Project.Module.module_exists(igniter, identify_module) do
        {true, igniter} -> igniter
        {false, igniter} -> create_identify_stub(igniter, identify_module)
      end
    end

    defp create_identify_stub(igniter, identify_module) do
      Igniter.Project.Module.create_module(igniter, identify_module, """
      @moduledoc \"\"\"
      Stub identity + metadata callback for phoenix_replay.

      `phoenix_replay` calls `fetch_identity/1` on every `POST /session`
      to resolve the acting user (or anonymous) and `fetch_metadata/1`
      on `POST /submit` to attach host context to the feedback row.
      Both receive the `Plug.Conn` and return what the callbacks expect.

      Replace the bodies below with real lookups against your auth /
      tenancy / session.
      \"\"\"

      @doc \"\"\"
      Resolve the acting identity for a session token request. Return
      either a map shaped
      `%{kind: :user | :api_key | :anonymous, id: String.t() | nil, attrs: map()}`
      or `nil` to reject the request with 401.
      \"\"\"
      @spec fetch_identity(Plug.Conn.t()) :: map() | nil
      def fetch_identity(_conn) do
        # TODO: replace with a real lookup. Common shapes:
        #
        #   case MyApp.Auth.current_user(conn) do
        #     %User{} = u -> %{kind: :user, id: to_string(u.id), attrs: %{email: u.email}}
        #     nil         -> %{kind: :anonymous, id: nil, attrs: %{}}
        #   end
        %{kind: :anonymous, id: nil, attrs: %{}}
      end

      @doc \"\"\"
      Return host metadata to attach to a feedback submission. Must be
      a map with string keys so JSONB serialization round-trips
      cleanly.
      \"\"\"
      @spec fetch_metadata(Plug.Conn.t()) :: map()
      def fetch_metadata(_conn) do
        # TODO: enrich with build SHA, environment, request id, etc.
        %{}
      end
      """)
    end

    # --- Migration copy ---------------------------------------------

    defp generate_migration(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      host_module = host_module_alias(app_name)
      repo_module = Module.concat([host_module, "Repo"])
      migrations_dir = "priv/repo/migrations"
      target_filename = "create_phoenix_replay_tables.exs"

      existing_path =
        igniter.rewrite.sources
        |> Map.keys()
        |> Enum.find(&String.ends_with?(&1, "_" <> target_filename))

      cond do
        existing_path && timestamped_under?(existing_path, migrations_dir) ->
          igniter

        File.exists?(migrations_dir) and migration_already_on_disk?(migrations_dir, target_filename) ->
          igniter

        true ->
          timestamp = migration_timestamp()
          target_path = Path.join(migrations_dir, "#{timestamp}_#{target_filename}")
          migration_module = Module.concat([repo_module, Migrations, "CreatePhoenixReplayTables"])

          template_path =
            :phoenix_replay
            |> Application.app_dir(
              "priv/templates/phoenix_replay.install/migrations/create_phoenix_replay_tables.ex"
            )

          contents =
            template_path
            |> File.read!()
            |> EEx.eval_string(assigns: [module: migration_module])

          Igniter.create_new_file(igniter, target_path, contents)
      end
    end

    defp timestamped_under?(path, dir) do
      String.starts_with?(path, dir <> "/") and
        Regex.match?(~r/^\d{14}_/, Path.basename(path))
    end

    defp migration_already_on_disk?(dir, target_filename) do
      case File.ls(dir) do
        {:ok, files} ->
          Enum.any?(files, &String.ends_with?(&1, "_" <> target_filename))

        _ ->
          false
      end
    end

    defp migration_timestamp do
      {{y, m, d}, {h, mi, s}} = :calendar.universal_time()

      :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, h, mi, s])
      |> IO.iodata_to_binary()
    end

    defp inject_widget_into_root_layout(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      web_module_under = "#{app_name}_web"
      layout_path = Path.join(["lib", web_module_under, "components/layouts/root.html.heex"])

      cond do
        Igniter.exists?(igniter, layout_path) ->
          igniter = Igniter.include_glob(igniter, layout_path)
          source = Rewrite.source!(igniter.rewrite, layout_path)
          content = Rewrite.Source.get(source, :content)

          cond do
            String.contains?(content, @widget_marker) ->
              igniter

            String.contains?(content, "</body>") ->
              new_content =
                String.replace(content, "</body>", @widget_snippet <> "</body>", global: false)

              new_source = Rewrite.Source.update(source, :content, new_content)
              %{igniter | rewrite: Rewrite.update!(igniter.rewrite, new_source)}

            true ->
              Igniter.add_notice(igniter, """
              Could not find a `</body>` tag in #{layout_path}. Paste the widget
              snippet manually before your closing </body>:

              #{@widget_snippet}

              Then enable it in config:

                  config :phoenix_replay, widget_enabled: true
              """)
          end

        true ->
          Igniter.add_notice(igniter, """
          Could not find #{layout_path}. The phoenix_replay widget needs to live in
          your root layout. Paste this snippet before </body>:

          #{@widget_snippet}

          Then enable it in config:

              config :phoenix_replay, widget_enabled: true
          """)
      end
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
