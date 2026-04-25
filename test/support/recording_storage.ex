defmodule PhoenixReplay.Test.RecordingStorage do
  @moduledoc false
  # Test-only Storage adapter that records the most recent `submit/3`
  # call so assertions can inspect what the controller forwarded.
  @behaviour PhoenixReplay.Storage

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc "Returns the `{session_id, params, identity}` tuple from the most recent submit/3 call."
  def last_submit, do: Agent.get(__MODULE__, & &1)

  @impl true
  def start_session(_identity, _now),
    do: {:ok, "test-session-#{System.unique_integer([:positive])}"}

  @impl true
  def resume_session(_session_id, _now), do: {:error, :not_found}

  @impl true
  def append_events(_session_id, _seq, _batch), do: :ok

  @impl true
  def submit(session_id, params, identity) do
    Agent.update(__MODULE__, fn _ -> {session_id, params, identity} end)
    {:ok, %{id: "fbk-test"}}
  end

  @impl true
  def fetch_feedback(_id, _opts), do: {:error, :not_found}

  @impl true
  def fetch_events(_session_id), do: {:ok, []}

  @impl true
  def list(_filters, _pagination), do: {:ok, %{results: [], count: 0}}
end
