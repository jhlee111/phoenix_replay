defmodule PhoenixReplay.CaptureStream.Registry do
  @moduledoc false
  # Owns the ETS table mapping {session_id, stream_id} → session_pid
  # for CaptureStream's O(1) hot-path lookup. Started in the
  # PhoenixReplay supervision tree before the SessionSupervisor.
  #
  # Read access via :ets.lookup is concurrent-safe with no GenServer
  # roundtrip; writes go through this process for serialization +
  # process monitoring (so a crashed Session pid auto-purges its rows).

  use GenServer

  @table :phoenix_replay_capture_streams

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the session pid responsible for the given stream, or nil."
  @spec lookup(String.t(), String.t()) :: pid() | nil
  def lookup(session_id, stream_id) do
    case :ets.lookup(@table, {session_id, stream_id}) do
      [{_, pid}] -> pid
      [] -> nil
    end
  end

  @doc "Returns all stream_ids registered for a session."
  @spec streams_for_session(String.t()) :: [String.t()]
  def streams_for_session(session_id) do
    @table
    |> :ets.match({{session_id, :"$1"}, :_})
    |> List.flatten()
  end

  @doc """
  Returns one of the pids registered for `session_id`. All entries
  for a given session_id point at the same Session GenServer pid, so
  the choice is arbitrary; nil if no streams are registered.
  """
  @spec session_pid(String.t()) :: pid() | nil
  def session_pid(session_id) do
    case :ets.match(@table, {{session_id, :_}, :"$1"}) |> List.flatten() do
      [pid | _] -> pid
      [] -> nil
    end
  end

  def register(session_id, stream_id, pid) do
    GenServer.call(__MODULE__, {:register, session_id, stream_id, pid})
  end

  def unregister(session_id, stream_id) do
    GenServer.call(__MODULE__, {:unregister, session_id, stream_id})
  end

  def unregister_session(session_id) do
    GenServer.call(__MODULE__, {:unregister_session, session_id})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, session_id, stream_id, pid}, _from, state) do
    :ets.insert(@table, {{session_id, stream_id}, pid})
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.monitors[{session_id, stream_id}], ref)}
  end

  def handle_call({:unregister, session_id, stream_id}, _from, state) do
    :ets.delete(@table, {session_id, stream_id})

    state =
      case Map.pop(state.monitors, {session_id, stream_id}) do
        {nil, m} ->
          %{state | monitors: m}

        {ref, m} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: m}
      end

    {:reply, :ok, state}
  end

  def handle_call({:unregister_session, session_id}, _from, state) do
    streams = streams_for_session(session_id)

    state =
      Enum.reduce(streams, state, fn stream_id, acc ->
        :ets.delete(@table, {session_id, stream_id})

        case Map.pop(acc.monitors, {session_id, stream_id}) do
          {nil, m} ->
            %{acc | monitors: m}

          {ref, m} ->
            Process.demonitor(ref, [:flush])
            %{acc | monitors: m}
        end
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Session crashed — purge all entries pointing at this pid.
    to_delete =
      @table
      |> :ets.match({{:"$1", :"$2"}, pid})
      |> Enum.map(fn [sid, stid] -> {sid, stid} end)

    Enum.each(to_delete, fn key -> :ets.delete(@table, key) end)

    monitors = Map.drop(state.monitors, to_delete)
    {:noreply, %{state | monitors: monitors}}
  end
end
