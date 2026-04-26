defmodule PhoenixReplay.ChangesetErrors do
  @moduledoc false
  # JSON-friendly serializer for `Ecto.Changeset` validation failures.
  #
  # Returned to API clients in 422 response bodies. Keeps internal
  # representations (struct refs, anonymous fns from the changeset's
  # action stack, validation opts) out of the wire payload — the
  # `inspect/1` fallback we used to ship leaked module names and
  # ref-strings that were both noisy and a soft information disclosure.

  @doc """
  Returns a map of `%{field_atom => [error_message_string, ...]}`.

  Falls back to a string representation for any non-changeset input
  so callers can pipe through this serializer unconditionally without
  guarding the input type at every call site.
  """
  @spec serialize(term()) :: %{atom() => [String.t()]} | String.t()
  def serialize(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  def serialize(other) when is_binary(other), do: other
  def serialize(other), do: inspect(other) |> String.trim_leading(":")
end
