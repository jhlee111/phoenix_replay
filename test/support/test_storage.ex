defmodule PhoenixReplay.Storage.TestAdapter do
  @moduledoc false
  # In-memory fake `PhoenixReplay.Storage` for unit tests that need
  # the Session GenServer to talk to *something* without standing up
  # a real DB. Backed by an `Agent` keyed by tuples for the few
  # fields the Session layer actually touches.
  #
  # Wire it in a test setup with:
  #
  #     start_supervised!(PhoenixReplay.Storage.TestAdapter)
  #     Application.put_env(:phoenix_replay, :storage,
  #       {PhoenixReplay.Storage.TestAdapter, []})

  @behaviour PhoenixReplay.Storage

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{appends: [], resumes: %{}} end, name: __MODULE__)
  end

  def appends, do: Agent.get(__MODULE__, & &1.appends)

  def reset, do: Agent.update(__MODULE__, fn _ -> %{appends: [], resumes: %{}} end)

  @doc """
  Pre-arm the resume answer for `session_id`. Subsequent
  `resume_session/2` calls return `result` until reset.
  """
  def stub_resume(session_id, result) do
    Agent.update(__MODULE__, &put_in(&1, [:resumes, session_id], result))
  end

  @impl true
  def start_session(_identity, _now) do
    {:ok, "test-session-#{System.unique_integer([:positive])}"}
  end

  @impl true
  def resume_session(session_id, _now) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.resumes, session_id, {:error, :not_found})
    end)
  end

  @impl true
  def append_events(session_id, seq, batch) do
    Agent.get_and_update(__MODULE__, fn state ->
      already? = Enum.any?(state.appends, fn {sid, s, _} -> sid == session_id and s == seq end)

      if already? do
        {{:error, :conflict}, state}
      else
        {:ok, %{state | appends: [{session_id, seq, batch} | state.appends]}}
      end
    end)
  end

  @impl true
  def submit(_session_id, _params, _identity), do: {:ok, %{id: "test-feedback"}}

  @impl true
  def fetch_feedback(_id, _opts), do: {:error, :not_found}

  @impl true
  def fetch_events(_session_id), do: {:ok, []}

  @impl true
  def list(_filters, _pagination), do: {:ok, %{results: [], count: 0}}
end
