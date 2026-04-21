defmodule PhoenixReplay.Plug.Identify do
  @moduledoc """
  Plug that invokes the configured `identify` hook (see
  `PhoenixReplay.Config`) and stashes the resulting identity under
  `conn.assigns[:phoenix_replay_identity]`.

  Rejects requests with `401` when the hook returns `nil` or is
  unconfigured — `start_session` refuses anonymous replays by default.

  Typically not mounted directly; the `Router.feedback_routes/2` macro
  applies it to every ingest endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @assign_key :phoenix_replay_identity

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case PhoenixReplay.Hook.invoke(:identify, conn) do
      nil ->
        send_unauthorized(conn)

      %{kind: kind} = identity when is_atom(kind) ->
        assign(conn, @assign_key, identity)

      _other ->
        send_unauthorized(conn)
    end
  end

  defp send_unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end

  @doc """
  Returns the identity assigned by this plug, or `nil` if it has not
  run on the current `conn`.
  """
  @spec fetch(Plug.Conn.t()) :: map() | nil
  def fetch(conn), do: Map.get(conn.assigns, @assign_key)
end
