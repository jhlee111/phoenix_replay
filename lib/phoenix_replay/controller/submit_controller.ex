defmodule PhoenixReplay.SubmitController do
  @moduledoc false
  # POST /submit — finalizes a session into a Feedback record. Merges
  # host-supplied metadata (via the configured metadata hook) into the
  # client-supplied payload, applies PII scrub to any free-form fields,
  # and delegates to the storage adapter.

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Hook, SessionToken, Storage}
  alias PhoenixReplay.Plug.Identify

  @token_header "x-phoenix-replay-session"

  def create(conn, params) do
    identity = Identify.fetch(conn)

    with {:ok, token} <- fetch_token(conn),
         {:ok, session_id} <- SessionToken.verify(token, identity) do
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
        "jam_link" => Map.get(params, "jam_link")
      }

      case Storage.Dispatch.submit(session_id, submit_params, identity) do
        {:ok, feedback} ->
          conn
          |> put_status(:created)
          |> json(%{ok: true, id: fetch_id(feedback)})

        {:error, changeset} ->
          send_error(conn, 422, "submit_failed", inspect(changeset))
      end
    else
      {:error, :missing_token} -> send_error(conn, 401, "missing_session_token")
      {:error, :expired} -> send_error(conn, 410, "session_expired")
      {:error, :invalid} -> send_error(conn, 401, "invalid_session_token")
      {:error, :identity_mismatch} -> send_error(conn, 401, "identity_mismatch")
      {:error, :no_secret} -> send_error(conn, 503, "not_configured")
    end
  end

  defp fetch_token(conn) do
    case get_req_header(conn, @token_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp fetch_id(%{id: id}), do: id
  defp fetch_id(%{"id" => id}), do: id
  defp fetch_id(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  defp send_error(conn, status, code, detail \\ nil) do
    body = if detail, do: %{error: code, detail: detail}, else: %{error: code}

    conn
    |> put_status(status)
    |> json(body)
    |> halt()
  end
end
