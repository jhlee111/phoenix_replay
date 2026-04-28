defmodule PhoenixReplay.LiveView.Registry do
  @moduledoc false
  # Per-LV-process map: transport_pid → session_id.
  #
  # Populated by PhoenixReplay.LiveView.Snapshots.on_mount/4 when the
  # host's Plug.Session has surfaced the phx_replay_session_id cookie
  # (see PhoenixReplay.Plug.SessionLink, Task 7.5). attach_hook
  # callbacks in the same LV process consult lookup/0 to identify the
  # session without re-parsing connect params.

  @registry __MODULE__

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    Supervisor.child_spec(
      Registry.child_spec(keys: :unique, name: @registry),
      id: @registry
    )
  end

  @doc """
  Register the current process under `session_id`. Idempotent: a
  second call from the same process replaces the prior entry.
  """
  @spec register(String.t()) :: :ok
  def register(session_id) when is_binary(session_id) do
    case Registry.register(@registry, self(), session_id) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        Registry.update_value(@registry, self(), fn _ -> session_id end)
        :ok
    end
  end

  @doc "Look up the session_id for the given pid (defaults to self)."
  @spec lookup(pid()) :: {:ok, String.t()} | :error
  def lookup(pid \\ self()) do
    case Registry.lookup(@registry, pid) do
      [{^pid, session_id}] -> {:ok, session_id}
      [] -> :error
    end
  end
end
