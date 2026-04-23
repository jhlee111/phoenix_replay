defmodule PhoenixReplay.SessionSupervisor do
  @moduledoc false
  # DynamicSupervisor that owns one `PhoenixReplay.Session` GenServer
  # per active `session_id`. Spawned on first contact (either at
  # `/session` resume/mint time or `/events` lookup-or-start in the
  # crash-recovery path).
  #
  # Children use `:transient` restart so a normal exit (idle timeout,
  # `Session.close/2`) doesn't get respawned. Crashes do restart;
  # the restarted child has empty in-memory state but the next
  # `/events` POST routes through `Session.lookup_or_start/2` which
  # seeds the watermark from storage.

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a `PhoenixReplay.Session` for `session_id`. Returns
  `{:ok, pid}`. If a process is already registered for `session_id`,
  returns `{:error, {:already_started, pid}}` — callers should fold
  that into the success path.
  """
  @spec start_session(String.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(session_id, identity, opts \\ []) do
    spec = {
      PhoenixReplay.Session,
      [session_id: session_id, identity: identity] ++ opts
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
