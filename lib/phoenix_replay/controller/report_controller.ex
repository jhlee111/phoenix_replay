defmodule PhoenixReplay.ReportController do
  @moduledoc false
  # POST /report — single-shot ingest for ADR-0006 Path A (Report Now).
  #
  # The widget sits in :passive state with a ring buffer. When the user
  # clicks Report Now, the client uploads {description, severity,
  # events, metadata, jam_link, extras} in one request. The controller
  # mints a synthetic session, persists the events as a single batch
  # (seq=0), and finalizes via submit/3 — all without the long-lived
  # Session GenServer machinery used by the multi-batch :active flow.
  #
  # Intentionally does NOT call Session.start_session — Path A reports
  # are one-shot, not in-flight sessions, so they don't broadcast on
  # the :session_started / :session_closed PubSub topics. Live admin
  # session-watch will not see Path A reports as in-flight sessions
  # (correct: there is no in-flight to watch).

  use Phoenix.Controller, formats: [:json]

  import PhoenixReplay.Controller.Helpers, only: [fetch_id: 1, stringify_keys: 1]

  alias PhoenixReplay.{ChangesetErrors, Config, Hook, Scrub, Storage}
  alias PhoenixReplay.Ingest.{Error, Pipeline}
  alias PhoenixReplay.Plug.Identify

  @default_limits [max_report_bytes: 5_242_880, report_rate_per_minute: 10]
  @default_severity "medium"

  def create(conn, params) do
    ctx = %{
      conn: conn,
      params: params,
      identity: Identify.fetch(conn) || %{kind: :anonymous},
      limits: Keyword.merge(@default_limits, Config.limits())
    }

    with {:ok, ctx} <-
           Pipeline.check_actor_rate(ctx,
             bucket: :report,
             limit_key: :report_rate_per_minute,
             default: 10
           ),
         {:ok, ctx} <-
           Pipeline.check_body_size(ctx, limit_key: :max_report_bytes, default: 5_242_880),
         {:ok, ctx} <- fetch_description(ctx),
         {:ok, ctx} <- fetch_events(ctx),
         {:ok, ctx} <- start_synthetic_session(ctx),
         {:ok, ctx} <- maybe_append_events(ctx),
         {:ok, ctx} <- submit_feedback(ctx) do
      conn
      |> put_status(:created)
      |> json(%{ok: true, id: fetch_id(ctx.feedback)})
    else
      {:error, %Error{} = err} -> Pipeline.respond(conn, err)
    end
  end

  defp fetch_description(%{params: params} = ctx) do
    case Map.get(params, "description") do
      d when is_binary(d) and byte_size(d) > 0 ->
        {:ok, Map.put(ctx, :description, d)}

      _ ->
        {:error, Error.new(422, "missing_description")}
    end
  end

  defp fetch_events(%{params: params} = ctx) do
    case Map.get(params, "events", []) do
      list when is_list(list) -> {:ok, Map.put(ctx, :events, list)}
      _ -> {:error, Error.new(400, "events_must_be_list")}
    end
  end

  defp start_synthetic_session(%{identity: identity} = ctx) do
    case Storage.Dispatch.start_session(identity, DateTime.utc_now()) do
      {:ok, session_id} ->
        {:ok, Map.put(ctx, :session_id, session_id)}

      {:error, reason} ->
        {:error,
         Error.new(500, "report_failed", detail: ChangesetErrors.serialize(reason))}
    end
  end

  # Empty events list is valid — text-only Report Now is supported.
  # Storage.@callback append_events/3 declares :ok | {:error, term()};
  # we honor that contract exactly (no {:ok, _} fallback).
  defp maybe_append_events(%{events: []} = ctx), do: {:ok, ctx}

  defp maybe_append_events(%{events: events, session_id: session_id} = ctx) do
    scrubbed = Scrub.scrub_batch(events)

    case Storage.Dispatch.append_events(session_id, 0, scrubbed) do
      :ok ->
        {:ok, ctx}

      {:error, reason} ->
        {:error,
         Error.new(500, "report_failed", detail: ChangesetErrors.serialize(reason))}
    end
  end

  defp submit_feedback(ctx) do
    %{
      conn: conn,
      params: params,
      identity: identity,
      session_id: session_id,
      description: description
    } = ctx

    host_metadata = Hook.invoke(:metadata, conn) || %{}
    client_metadata = Map.get(params, "metadata", %{})

    merged_metadata =
      client_metadata
      |> stringify_keys()
      |> Map.merge(stringify_keys(host_metadata))

    submit_params = %{
      "description" => description,
      "severity" => Map.get(params, "severity") || @default_severity,
      "metadata" => merged_metadata,
      "jam_link" => Map.get(params, "jam_link"),
      "extras" => stringify_keys(Map.get(params, "extras") || %{})
    }

    case Storage.Dispatch.submit(session_id, submit_params, identity) do
      {:ok, feedback} ->
        {:ok, Map.put(ctx, :feedback, feedback)}

      {:error, changeset} ->
        {:error,
         Error.new(422, "submit_failed", detail: ChangesetErrors.serialize(changeset))}
    end
  end
end
