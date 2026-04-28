defmodule PhoenixReplay.LiveView.Shape do
  @moduledoc """
  Pure-function shape extractor — reduces any Elixir term to a
  key/type/size representation with no leaf values.

  The output is the safe-by-construction default for snapshot
  payloads. Every Phase 1 snapshot's `assigns_shape` field is the
  result of `extract_assigns/1` over `socket.assigns`.

  See `docs/superpowers/specs/2026-04-28-liveview-snapshot-design.md`
  section "Default extractor".
  """

  @type shape ::
          :nil
          | :boolean
          | :integer
          | :float
          | :atom
          | :pid
          | :reference
          | :function
          | :date
          | :datetime
          | :naive_datetime
          | {:string, [length: non_neg_integer()]}
          | {:binary, [length: non_neg_integer()]}
          | {:list, [length: non_neg_integer()]}
          | {:tuple, [size: non_neg_integer()]}
          | {:map, [keys: [atom() | binary()]]}
          | {:mapset, [size: non_neg_integer()]}
          | {:changeset, keyword()}
          | {:form, keyword()}
          | {:struct, module(), [fields: [atom()]]}
          | {:opaque, atom()}

  @spec extract(term()) :: shape
  def extract(nil), do: :nil
  def extract(b) when is_boolean(b), do: :boolean
  def extract(i) when is_integer(i), do: :integer
  def extract(f) when is_float(f), do: :float

  def extract(s) when is_binary(s) do
    if String.printable?(s) do
      {:string, length: byte_size(s)}
    else
      {:binary, length: byte_size(s)}
    end
  end

  def extract(a) when is_atom(a), do: :atom
  def extract(p) when is_pid(p), do: :pid
  def extract(r) when is_reference(r), do: :reference
  def extract(f) when is_function(f), do: :function

  def extract(l) when is_list(l), do: {:list, length: length(l)}
  def extract(t) when is_tuple(t), do: {:tuple, size: tuple_size(t)}

  def extract(%Date{}), do: :date
  def extract(%DateTime{}), do: :datetime
  def extract(%NaiveDateTime{}), do: :naive_datetime
  def extract(%MapSet{} = ms), do: {:mapset, size: MapSet.size(ms)}

  def extract(%Ecto.Changeset{} = cs) do
    fields =
      cs
      |> Map.get(:types, %{})
      |> Map.keys()
      |> Enum.sort()

    {:changeset, valid?: cs.valid?, fields: fields, error_count: length(cs.errors)}
  end

  def extract(%Phoenix.HTML.Form{} = form) do
    fields =
      case form.data do
        %_{} = struct ->
          struct |> Map.from_struct() |> Map.keys() |> Enum.sort()

        %{} = map ->
          map |> Map.keys() |> Enum.sort()

        _ ->
          []
      end

    {:form, name: to_string(form.name || ""), fields: fields, error_count: length(form.errors)}
  end

  def extract(%mod{} = struct) do
    fields = struct |> Map.from_struct() |> Map.keys() |> Enum.sort()
    {:struct, mod, fields: fields}
  end

  def extract(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.sort()
    {:map, keys: keys}
  end

  def extract(other) do
    class =
      cond do
        is_port(other) -> :port
        true -> :unknown
      end

    {:opaque, class}
  end

  @doc """
  Reduce a `socket.assigns` map (which may include LiveView's
  private `__changed__` and friends, plus our own
  `__phx_replay_session_id__` / `__phx_replay_event_throttle__`) to
  the shape map persisted in the snapshot payload. Drops any key
  whose name starts with `__`.
  """
  @spec extract_assigns(map()) :: map()
  def extract_assigns(assigns) when is_map(assigns) do
    assigns
    |> Map.reject(fn {k, _} ->
      is_atom(k) and String.starts_with?(Atom.to_string(k), "__")
    end)
    |> Map.new(fn {k, v} -> {k, extract(v)} end)
  end
end
