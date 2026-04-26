defmodule PhoenixReplay.Test.FailingStorage do
  @moduledoc false
  # Test-only Storage adapter whose submit/3 always returns
  # {:error, changeset} so controller error paths can be exercised.
  @behaviour PhoenixReplay.Storage

  use Agent

  defmodule FakeSchema do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :description, :string
    end

    def invalid_changeset do
      %__MODULE__{}
      |> cast(%{}, [:description])
      |> validate_required([:description])
      |> Map.put(:action, :insert)
    end
  end

  def start_link(_opts \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @impl true
  def start_session(_, _), do: {:ok, "failing-session-#{System.unique_integer([:positive])}"}
  @impl true
  def resume_session(_, _), do: {:error, :not_found}
  @impl true
  def append_events(_, _, _), do: :ok
  @impl true
  def submit(_session_id, _params, _identity), do: {:error, FakeSchema.invalid_changeset()}
  @impl true
  def fetch_feedback(_, _), do: {:error, :not_found}
  @impl true
  def fetch_events(_), do: {:ok, []}
  @impl true
  def list(_, _), do: {:ok, %{results: [], count: 0}}
end
