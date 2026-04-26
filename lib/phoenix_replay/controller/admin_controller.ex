defmodule PhoenixReplay.AdminController do
  @moduledoc false
  # Admin-side JSON endpoints for listing feedbacks + fetching the
  # rrweb event stream for playback. Mounted by
  # `PhoenixReplay.Router.admin_routes/2` behind the host's admin auth.
  #
  # These endpoints deliberately do NOT go through `Plug.Identify` —
  # authorization is the host's responsibility (typically by wrapping
  # the scope in an admin-only pipeline).

  use Phoenix.Controller, formats: [:json]

  alias PhoenixReplay.Storage

  def index(conn, params) do
    filters = coerce_filters(params)
    limit = parse_int(params["limit"]) || 50
    offset = parse_int(params["offset"]) || 0

    case Storage.Dispatch.list(filters, limit: limit, offset: offset) do
      {:ok, %{results: results, count: count}} ->
        json(conn, %{
          results: Enum.map(results, &serialize/1),
          count: count,
          limit: limit,
          offset: offset
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "list_failed", detail: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Storage.Dispatch.fetch_feedback(id, []) do
      {:ok, feedback} -> json(conn, %{feedback: serialize(feedback)})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def events(conn, %{"session_id" => session_id}) do
    case Storage.Dispatch.fetch_events(session_id) do
      {:ok, events} ->
        # Disable client cache — replays are immutable but we still want
        # to avoid stale CDN caching in dev / preview.
        conn
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> json(%{session_id: session_id, events: events})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  defp coerce_filters(params) do
    # Literal-keyed extraction. Avoids `String.to_existing_atom/1` on
    # user-supplied keys (Dynamic atom creation anti-pattern). Adding a
    # new filter is one new clause, not a whitelist + atom-conversion
    # pair to keep in sync.
    case params["severity"] do
      s when is_binary(s) -> %{severity: s}
      _ -> %{}
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp serialize(%_{} = row), do: row |> Map.from_struct() |> Map.drop([:__meta__])
  defp serialize(map) when is_map(map), do: map
end
