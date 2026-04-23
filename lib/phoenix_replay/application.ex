defmodule PhoenixReplay.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PhoenixReplay.RateLimiter,
        {Registry, keys: :unique, name: PhoenixReplay.SessionRegistry},
        PhoenixReplay.SessionSupervisor
      ] ++ pubsub_child()

    opts = [strategy: :one_for_one, name: PhoenixReplay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Hosts that already run a `Phoenix.PubSub` instance (every Phoenix
  # app does) point us at it via `config :phoenix_replay, :pubsub,
  # MyApp.PubSub`. When unset, start our own under the library
  # supervisor so the Session GenServer's broadcasts have somewhere
  # to land. ADR-0003 OQ4.
  defp pubsub_child do
    case Application.get_env(:phoenix_replay, :pubsub) do
      nil -> [{Phoenix.PubSub, name: PhoenixReplay.PubSub}]
      _name -> []
    end
  end
end
