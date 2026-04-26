defmodule PhoenixReplay.EventsController do
  @moduledoc false
  # POST /events — appends a single batch of rrweb events to an open
  # session. Enforces token validity + rate limits + body-size cap +
  # scrub, then delegates to the storage adapter.

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Config, Scrub, Session}
  alias PhoenixReplay.Ingest.{Error, Pipeline}
  alias PhoenixReplay.Plug.Identify

  @default_limits [
    max_batch_bytes: 1_048_576,
    batch_rate_per_minute: 30,
    actor_rate_per_minute: 300
  ]

  def append(conn, params) do
    ctx = %{
      conn: conn,
      params: params,
      identity: Identify.fetch(conn),
      limits: Keyword.merge(@default_limits, Config.limits())
    }

    with {:ok, ctx} <-
           Pipeline.check_actor_rate(ctx,
             bucket: :actor,
             limit_key: :actor_rate_per_minute,
             default: 300
           ),
         {:ok, ctx} <- Pipeline.fetch_token(ctx),
         {:ok, ctx} <- Pipeline.verify_token(ctx),
         {:ok, ctx} <-
           Pipeline.check_session_rate(ctx,
             limit_key: :batch_rate_per_minute,
             default: 30
           ),
         {:ok, ctx} <-
           Pipeline.check_body_size(ctx, limit_key: :max_batch_bytes, default: 1_048_576),
         {:ok, ctx} <- parse_payload(ctx),
         {:ok, ctx} <- lookup_or_start_session(ctx),
         {:ok, ctx} <- append_events(ctx) do
      json(conn, %{ok: true, seq: ctx.seq})
    else
      {:error, %Error{} = err} -> Pipeline.respond(conn, err)
    end
  end

  defp parse_payload(%{params: params} = ctx) do
    case params do
      %{"seq" => seq, "events" => events} when is_integer(seq) and is_list(events) ->
        {:ok, ctx |> Map.put(:seq, seq) |> Map.put(:batch, events)}

      _ ->
        {:error, Error.new(400, "invalid_payload")}
    end
  end

  defp lookup_or_start_session(%{session_id: session_id, identity: identity} = ctx) do
    case Session.lookup_or_start(session_id, identity) do
      {:ok, _pid} -> {:ok, ctx}
      {:error, :no_session} -> {:error, Error.new(410, "session_expired")}
      {:error, other} -> {:error, Error.new(500, "append_failed", detail: inspect(other))}
    end
  end

  defp append_events(%{session_id: session_id, seq: seq, batch: batch} = ctx) do
    scrubbed = Scrub.scrub_batch(batch)

    case Session.append_events(session_id, seq, scrubbed) do
      :ok -> {:ok, ctx}
      {:error, :conflict} -> {:error, Error.new(409, "seq_conflict")}
      {:error, :no_session} -> {:error, Error.new(410, "session_expired")}
      {:error, other} -> {:error, Error.new(500, "append_failed", detail: inspect(other))}
    end
  end
end
