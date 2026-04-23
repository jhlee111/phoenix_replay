defmodule PhoenixReplay.Storage.Ecto do
  @moduledoc """
  Default storage adapter. Writes:

    * one row into `phoenix_replay_feedbacks` per submission
    * one row per event batch into `phoenix_replay_events`
      (append-only, unique on `(session_id, seq)`)

  Past a configurable size threshold, a background job collapses a
  session's event rows into a single S3 blob and populates
  `events_s3_key` on the parent — see `PhoenixReplay.Storage.S3`.

  ## Configuration

      config :phoenix_replay,
        storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo}

  The `:repo` key is required — the adapter has no way to infer it.

  ## Concurrency

  `append_events/3` is safe to call concurrently for the same
  `session_id`. The unique index on `(session_id, seq)` forces retries
  to collide on duplicate `seq`, which the controller surfaces as
  `{:error, :conflict}`. Inserts with distinct `seq` values never block
  each other.
  """

  @behaviour PhoenixReplay.Storage

  import Ecto.Query, only: [from: 2]

  alias PhoenixReplay.Storage.Ecto.Feedback

  @impl true
  def start_session(identity, now) do
    # The Ecto adapter doesn't persist anything at session start —
    # the feedback row is inserted only on submit. We still mint a
    # fresh session id so the token carries it.
    _ = identity
    _ = now
    {:ok, PhoenixReplay.SessionToken.new_session_id()}
  end

  @impl true
  def resume_session(session_id, now) do
    PhoenixReplay.Storage.Events.resume(
      repo!(),
      session_id,
      PhoenixReplay.Config.session_idle_timeout_ms(),
      now
    )
  end

  @impl true
  def append_events(session_id, seq, batch) do
    PhoenixReplay.Storage.Events.append(repo!(), session_id, seq, batch)
  end

  @impl true
  def submit(session_id, params, identity) do
    repo = repo!()

    attrs = %{
      session_id: session_id,
      description: Map.get(params, "description") || Map.get(params, :description),
      severity: Map.get(params, "severity") || Map.get(params, :severity),
      metadata: Map.get(params, "metadata") || Map.get(params, :metadata) || %{},
      identity: coerce_identity(identity)
    }

    %Feedback{}
    |> Feedback.changeset(attrs)
    |> repo.insert(on_conflict: {:replace, [:description, :severity, :metadata, :updated_at]},
         conflict_target: :session_id)
  end

  @impl true
  def fetch_feedback(id, _opts) do
    repo = repo!()

    case repo.get(Feedback, id) do
      nil -> {:error, :not_found}
      feedback -> {:ok, feedback}
    end
  end

  @impl true
  def fetch_events(session_id) do
    PhoenixReplay.Storage.Events.fetch(repo!(), session_id)
  end

  @impl true
  def list(filters, pagination) do
    repo = repo!()

    limit = Keyword.get(pagination, :limit, 50)
    offset = Keyword.get(pagination, :offset, 0)

    query =
      from(f in Feedback,
        order_by: [desc: f.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query = apply_filters(query, filters)
    results = repo.all(query)

    count_query = apply_filters(from(f in Feedback, select: count(f.id)), filters)
    count = repo.one(count_query)

    {:ok, %{results: results, count: count}}
  end

  defp apply_filters(query, filters) when map_size(filters) == 0, do: query

  defp apply_filters(query, %{severity: severity}) when is_binary(severity) do
    from(f in query, where: f.severity == ^severity)
  end

  defp apply_filters(query, _), do: query

  defp coerce_identity(%{kind: kind} = identity) do
    # Persist identity as a plain map with string keys so JSONB
    # round-trips losslessly. CLAUDE.md atom-vs-string rule.
    %{
      "kind" => to_string(kind),
      "id" => Map.get(identity, :id),
      "attrs" => stringify_keys(Map.get(identity, :attrs, %{}))
    }
  end

  defp coerce_identity(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  defp repo! do
    {_mod, opts} = PhoenixReplay.Config.storage()

    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_atom(repo) ->
        repo

      _ ->
        raise ArgumentError, """
        PhoenixReplay.Storage.Ecto requires a :repo option. Configure it:

            config :phoenix_replay,
              storage: {PhoenixReplay.Storage.Ecto, repo: MyApp.Repo}
        """
    end
  end
end
