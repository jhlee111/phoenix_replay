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

  alias PhoenixReplay.{ChangesetErrors, Config, Hook, RateLimiter, Scrub, Storage}
  alias PhoenixReplay.Plug.Identify

  @default_limits [max_report_bytes: 5_242_880, report_rate_per_minute: 10]
  @default_severity "medium"

  def create(conn, params) do
    identity = Identify.fetch(conn) || %{kind: :anonymous}
    limits = Keyword.merge(@default_limits, Config.limits())

    with :ok <- check_actor_rate(identity, limits),
         :ok <- check_body_size(conn, limits),
         {:ok, description} <- fetch_description(params),
         {:ok, events} <- fetch_events(params),
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
          send_error(conn, 422, "submit_failed", ChangesetErrors.serialize(changeset))
      end
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_error(429, "rate_limited")

      {:error, :body_too_large} ->
        send_error(conn, 413, "body_too_large")

      {:error, :missing_description} ->
        send_error(conn, 422, "missing_description")

      {:error, :events_not_list} ->
        send_error(conn, 400, "events_must_be_list")

      {:error, reason} ->
        send_error(conn, 500, "report_failed", ChangesetErrors.serialize(reason))
    end
  end

  defp fetch_description(params) do
    case Map.get(params, "description") do
      d when is_binary(d) and byte_size(d) > 0 -> {:ok, d}
      _ -> {:error, :missing_description}
    end
  end

  defp fetch_events(params) do
    case Map.get(params, "events", []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :events_not_list}
    end
  end

  # Empty events list is valid — text-only Report Now is supported.
  # Non-empty list is scrubbed and persisted as a single batch.
  # Storage.@callback append_events/3 declares :ok | {:error, term()};
  # we honor that contract exactly (no {:ok, _} fallback).
  defp maybe_append(_session_id, []), do: :ok

  defp maybe_append(session_id, events) when is_list(events) do
    scrubbed = Scrub.scrub_batch(events)
    Storage.Dispatch.append_events(session_id, 0, scrubbed)
  end

  defp fetch_id(%{id: id}), do: id
  defp fetch_id(%{"id" => id}), do: id
  defp fetch_id(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  # Distinct key from EventsController's {:actor, _} bucket so Path A
  # /report and Path B /events have independent quotas. A user actively
  # reproducing a bug (Path B) shouldn't burn their /report budget on
  # event flushes, and vice versa.
  defp check_actor_rate(identity, limits) do
    limit = Keyword.get(limits, :report_rate_per_minute, 10)
    key = {:report, identity[:id] || identity[:kind] || :anonymous}
    RateLimiter.hit(key, limit, 60)
  end

  # Mirrors EventsController.check_body_size/2 — content-length-only
  # check (cheap, runs before body parsing). The key difference is the
  # config knob: :max_report_bytes (Path A's single-shot bound) vs.
  # :max_batch_bytes (per-flush bound on /events).
  defp check_body_size(conn, limits) do
    max = Keyword.get(limits, :max_report_bytes, 5_242_880)

    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {n, _} when n <= max -> :ok
          {_, _} -> {:error, :body_too_large}
          :error -> :ok
        end

      _ ->
        :ok
    end
  end

  defp send_error(conn, status, code, detail \\ nil) do
    body = if detail, do: %{error: code, detail: detail}, else: %{error: code}

    conn
    |> put_status(status)
    |> json(body)
    |> halt()
  end
end
