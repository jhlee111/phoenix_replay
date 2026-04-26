defmodule PhoenixReplay.Controller.Helpers do
  @moduledoc false
  # Tiny render-side helpers shared by the ingest controllers (events,
  # submit, report). `import`ed at the top of each controller — not part
  # of the public API.
  #
  # Validation/error rendering lives in `PhoenixReplay.Ingest.Pipeline`;
  # this module is just for the bits that are easier inlined than
  # threaded through the pipeline (response-shape coercion).

  @doc """
  Converts atom keys to strings for JSON-friendly merging. Non-map values
  pass through unchanged.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  def stringify_keys(other), do: other

  @doc """
  Reads `:id` (atom or string key) from a struct or map; returns `nil`
  if neither is present.
  """
  def fetch_id(%{id: id}), do: id
  def fetch_id(%{"id" => id}), do: id
  def fetch_id(_), do: nil
end
