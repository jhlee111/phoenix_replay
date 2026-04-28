defmodule PhoenixReplay.LiveView.ShapeTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.LiveView.Shape

  defmodule SomeUser do
    defstruct [:id, :email, :name, :secret_token]
  end

  describe "extract/1 — default mappings" do
    test "primitives produce type tags without values" do
      assert Shape.extract(nil) == :nil
      assert Shape.extract(true) == :boolean
      assert Shape.extract(false) == :boolean
      assert Shape.extract(42) == :integer
      assert Shape.extract(3.14) == :float
      assert Shape.extract(:any_atom) == :atom
      assert Shape.extract(make_ref()) == :reference
      assert Shape.extract(self()) == :pid
      assert Shape.extract(fn -> :ok end) == :function
    end

    test "binary returns length, not content" do
      assert Shape.extract("hello") == {:string, length: 5}
      assert Shape.extract("") == {:string, length: 0}
      assert Shape.extract(<<0, 1, 2>>) == {:binary, length: 3}
    end

    test "list returns length, not elements" do
      assert Shape.extract([1, 2, 3]) == {:list, length: 3}
      assert Shape.extract([]) == {:list, length: 0}
    end

    test "tuple returns size" do
      assert Shape.extract({:ok, 42}) == {:tuple, size: 2}
      assert Shape.extract({}) == {:tuple, size: 0}
    end

    test "map returns keys, not values" do
      assert Shape.extract(%{a: 1, b: "secret"}) ==
               {:map, keys: [:a, :b]}

      assert Shape.extract(%{}) == {:map, keys: []}
    end

    test "MapSet returns size" do
      assert Shape.extract(MapSet.new([1, 2, 3])) ==
               {:mapset, size: 3}
    end

    test "Date/DateTime/NaiveDateTime collapse to type tags" do
      assert Shape.extract(~D[2026-04-28]) == :date
      assert Shape.extract(~U[2026-04-28 12:00:00Z]) == :datetime
      assert Shape.extract(~N[2026-04-28 12:00:00]) == :naive_datetime
    end

    test "Ecto.Changeset returns valid?, fields, error_count — no values" do
      changeset = %Ecto.Changeset{
        data: %{},
        changes: %{name: "alice", email: "a@b.c"},
        errors: [name: {"too short", []}],
        valid?: false,
        types: %{name: :string, email: :string}
      }

      assert Shape.extract(changeset) ==
               {:changeset, valid?: false, fields: [:email, :name], error_count: 1}
    end

    test "Phoenix.HTML.Form returns name + fields + error_count" do
      form = %Phoenix.HTML.Form{
        source: %Ecto.Changeset{errors: []},
        name: "user",
        data: %{name: "alice", email: "a@b"},
        params: %{},
        errors: [],
        impl: nil,
        id: "user",
        index: nil,
        action: nil,
        options: [],
        hidden: []
      }

      assert Shape.extract(form) ==
               {:form, name: "user", fields: [:email, :name], error_count: 0}
    end

    test "user struct returns module + fields, no values" do
      u = %SomeUser{id: 1, email: "a@b", name: "alice", secret_token: "REDACTED"}

      assert Shape.extract(u) ==
               {:struct, __MODULE__.SomeUser, fields: [:email, :id, :name, :secret_token]}
    end

    test "unknown opaque values fall through to :opaque" do
      port = Port.list() |> List.first()

      if port do
        assert match?({:opaque, _}, Shape.extract(port))
      end
    end
  end

  describe "extract/1 — PII safety property" do
    test "leaf string never leaks" do
      secret = "P@SSWORD-#{System.unique_integer([:positive])}"
      out = Shape.extract(%{user: %{token: secret, name: secret}})
      out_bin = :erlang.term_to_binary(out)
      secret_bin = :erlang.term_to_binary(secret)
      tail = binary_part(secret_bin, 5, byte_size(secret_bin) - 5)

      refute :binary.match(out_bin, tail) != :nomatch,
             "shape output contained the raw secret string — PII leak"
    end

    test "leaf integer never leaks (other than as length/size hints)" do
      sentinel = 9_999_999
      out = Shape.extract(%{count: sentinel, user: %{age: sentinel}})

      refute :binary.match(:erlang.term_to_binary(out), :erlang.term_to_binary(sentinel)) !=
               :nomatch,
             "shape output contained the sentinel integer — PII leak"
    end

    test "atom values never leak (only keys, never values)" do
      out = Shape.extract(%{role: :super_secret_admin_role})
      atoms = collect_atoms(out)

      refute :super_secret_admin_role in atoms,
             "shape output contained the value atom — PII leak"
    end
  end

  describe "extract_assigns/1" do
    test "drops Phoenix.LiveView private __ keys" do
      assigns = %{
        __changed__: %{count: true},
        __phx_replay_session_id__: "session-123",
        count: 5,
        user: %{id: 1}
      }

      out = Shape.extract_assigns(assigns)

      refute Map.has_key?(out, :__changed__)
      refute Map.has_key?(out, :__phx_replay_session_id__)
      assert out[:count] == :integer
      assert out[:user] == {:map, keys: [:id]}
    end
  end

  defp collect_atoms(term) when is_atom(term), do: [term]
  defp collect_atoms(term) when is_list(term), do: Enum.flat_map(term, &collect_atoms/1)

  defp collect_atoms(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&collect_atoms/1)

  defp collect_atoms(term) when is_map(term),
    do: term |> Map.to_list() |> Enum.flat_map(&collect_atoms/1)

  defp collect_atoms(_), do: []
end
