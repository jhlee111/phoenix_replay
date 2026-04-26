defmodule PhoenixReplay.Ingest.Error do
  @moduledoc false
  # Uniform error shape for ingest-pipeline steps. The ingest controllers
  # pattern-match on `%Error{}` in a single `else` clause to render the
  # JSON response — replacing the heterogeneous `with`/`else` fan-out
  # that the Elixir docs flag as the "complex else clauses in `with`"
  # anti-pattern.

  defstruct status: nil, code: nil, detail: nil, headers: []

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t(),
          detail: term() | nil,
          headers: [{String.t(), String.t()}]
        }

  @doc """
  Builds an error struct.

  ## Options

    * `:detail` — JSON body field appended as `:detail`. When omitted, the
      response body is just `%{"error" => code}`.
    * `:headers` — extra response headers, e.g. `[{"retry-after", "30"}]`.
  """
  def new(status, code, opts \\ []) do
    %__MODULE__{
      status: status,
      code: code,
      detail: Keyword.get(opts, :detail),
      headers: Keyword.get(opts, :headers, [])
    }
  end
end
