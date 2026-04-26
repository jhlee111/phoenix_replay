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

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.{Hook, Scrub, Storage}
  alias PhoenixReplay.Plug.Identify

  @default_severity "medium"

  def create(conn, params) do
    identity = Identify.fetch(conn) || %{kind: :anonymous}

    with {:ok, description} <- fetch_description(params),
         events when is_list(events) <- Map.get(params, "events", []),
         {:ok, session_id} <- Storage.Dispatch.start_session(identity, DateTime.utc_now()),
         :ok <- maybe_append(session_id, events) do
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
          conn
          |> put_status(:created)
          |> json(%{ok: true, id: fetch_id(feedback)})

        {:error, changeset} ->
          send_error(conn, 422, "submit_failed", inspect(changeset))
      end
    else
      {:error, :missing_description} ->
        send_error(conn, 422, "missing_description")

      {:error, :events_not_list} ->
        send_error(conn, 400, "events_must_be_list")

      {:error, reason} ->
        send_error(conn, 500, "report_failed", inspect(reason))
    end
  end

  defp fetch_description(params) do
    case Map.get(params, "description") do
      d when is_binary(d) and byte_size(d) > 0 -> {:ok, d}
      _ -> {:error, :missing_description}
    end
  end

  # Empty events list is valid — text-only Report Now is supported.
  # Non-empty list is scrubbed and persisted as a single batch.
  defp maybe_append(_session_id, []), do: :ok

  defp maybe_append(session_id, events) when is_list(events) do
    scrubbed = Scrub.scrub_batch(events)

    case Storage.Dispatch.append_events(session_id, 0, scrubbed) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_append(_session_id, _other), do: {:error, :events_not_list}

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
