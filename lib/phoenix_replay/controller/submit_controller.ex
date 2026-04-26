defmodule PhoenixReplay.SubmitController do
  @moduledoc false
  # POST /submit — finalizes a session into a Feedback record. Merges
  # host-supplied metadata (via the configured metadata hook) into the
  # client-supplied payload, applies PII scrub to any free-form fields,
  # and delegates to the storage adapter.

  use Phoenix.Controller, formats: [:json]

  import PhoenixReplay.Controller.Helpers, only: [fetch_id: 1, stringify_keys: 1]

  alias PhoenixReplay.{ChangesetErrors, Hook, Session, Storage}
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
