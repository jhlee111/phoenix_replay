defmodule PhoenixReplay.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.ChangesetErrors

  defmodule FakeSchema do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :description, :string
      field :severity, :string
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [:description, :severity])
      |> validate_required([:description])
      |> validate_inclusion(:severity, ~w(low medium high))
    end
  end

  test "serializes a failed changeset to a field => [messages] map" do
    changeset = FakeSchema.changeset(%{"severity" => "urgent"})

    assert %{
             description: ["can't be blank"],
             severity: ["is invalid"]
           } = ChangesetErrors.serialize(changeset)
  end

  test "interpolates validation parameters (count, etc.) into messages" do
    changeset =
      %FakeSchema{}
      |> Ecto.Changeset.cast(%{"description" => "ok", "severity" => "high"}, [
        :description,
        :severity
      ])
      |> Ecto.Changeset.validate_length(:description, min: 5)

    assert %{description: [msg]} = ChangesetErrors.serialize(changeset)
    assert msg =~ "should be at least 5 character"
  end

  test "tolerates a non-changeset value by returning a string fallback" do
    assert ChangesetErrors.serialize(:some_unexpected_term) == "some_unexpected_term"
    assert ChangesetErrors.serialize("already a string") == "already a string"
  end
end
