defmodule PhoenixReplay.Storage.Dispatch do
  @moduledoc false
  # Thin dispatcher in front of the configured `PhoenixReplay.Storage`
  # adapter. Resolves the adapter from config on every call so tests /
  # runtime switches take effect without restart.

  alias PhoenixReplay.Config

  def start_session(identity, now) do
    adapter().start_session(identity || %{kind: :anonymous}, now)
  end

  def resume_session(session_id, now) do
    adapter().resume_session(session_id, now)
  end

  def append_events(session_id, seq, batch) do
    adapter().append_events(session_id, seq, batch)
  end

  def submit(session_id, params, identity) do
    adapter().submit(session_id, params, identity || %{kind: :anonymous})
  end

  def fetch_feedback(id, opts \\ []), do: adapter().fetch_feedback(id, opts)

  def fetch_events(session_id), do: adapter().fetch_events(session_id)

  def list(filters, pagination), do: adapter().list(filters, pagination)

  defp adapter do
    case Config.storage() do
      {mod, _opts} when is_atom(mod) -> mod
      mod when is_atom(mod) -> mod
      _ -> raise ArgumentError, "config :phoenix_replay, :storage must be {module, opts}"
    end
  end
end
