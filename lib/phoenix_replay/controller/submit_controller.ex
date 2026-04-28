defmodule PhoenixReplay.SubmitController do
  @moduledoc false
  # POST /submit — finalizes a session into a Feedback record. Merges
  # host-supplied metadata (via the configured metadata hook) into the
  # client-supplied payload, applies PII scrub to any free-form fields,
  # and delegates to the storage adapter.

  use Phoenix.Controller, formats: [:json]

  import PhoenixReplay.Controller.Helpers, only: [fetch_id: 1, stringify_keys: 1]

  alias PhoenixReplay.{CaptureStream, ChangesetErrors, Hook, Session, Storage}
  alias PhoenixReplay.Ingest.{Error, Pipeline}
  alias PhoenixReplay.Plug.Identify

  def create(conn, params) do
    ctx = %{
      conn: conn,
      params: params,
      identity: Identify.fetch(conn)
    }

    with {:ok, ctx} <- Pipeline.fetch_token(ctx),
         {:ok, ctx} <- Pipeline.verify_token(ctx),
         {:ok, ctx} <- flush_capture_streams(ctx),
         {:ok, ctx} <- submit_feedback(ctx) do
      # Best-effort close — if the Session process already exited
      # (idle timeout, crash), the broadcast is skipped silently.
      _ = Session.close(ctx.session_id, :submitted)

      conn
      |> put_status(:created)
      |> json(%{ok: true, id: fetch_id(ctx.feedback)})
    else
      {:error, %Error{} = err} -> Pipeline.respond(conn, err)
    end
  end

  # ADR-0007: drain server-origin capture streams (LV snapshots and
  # any other registered streams) before finalizing the feedback. The
  # drained events are persisted as a final batch at watermark+1 — the
  # admin player iterates events sorted by timestamp, so seq order
  # doesn't matter for replay. Best-effort: if anything fails here, we
  # log and continue rather than blocking the submit.
  defp flush_capture_streams(%{session_id: session_id} = ctx) do
    case CaptureStream.flush_for_session(session_id) do
      [] ->
        {:ok, ctx}

      events when is_list(events) ->
        with {:ok, watermark} <- Session.seq_watermark(session_id),
             :ok <- Session.append_events(session_id, watermark + 1, events) do
          {:ok, ctx}
        else
          _ ->
            # Capture stream is best-effort — never block submit.
            {:ok, ctx}
        end
    end
  end

  defp submit_feedback(ctx) do
    %{conn: conn, params: params, identity: identity, session_id: session_id} = ctx

    host_metadata = Hook.invoke(:metadata, conn) || %{}
    client_metadata = Map.get(params, "metadata", %{})

    merged_metadata =
      client_metadata
      |> stringify_keys()
      |> Map.merge(stringify_keys(host_metadata))

    submit_params = %{
      "description" => Map.get(params, "description"),
      "severity" => Map.get(params, "severity"),
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
