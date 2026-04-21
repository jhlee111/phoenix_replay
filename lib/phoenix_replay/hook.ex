defmodule PhoenixReplay.Hook do
  @moduledoc false
  # Invokes a configured hook (`:identify`, `:metadata`) against a
  # `Plug.Conn.t()`. Hooks can be registered as either an
  # `{module, function, extra_args}` tuple (conn is prepended) or a
  # 1-arity function reference.
  #
  # Returns the hook's raw result; callers decide how to interpret
  # `nil` vs. a return value.

  alias PhoenixReplay.Config

  @spec invoke(:identify | :metadata, Plug.Conn.t()) :: term()
  def invoke(:identify, conn), do: invoke_hook(Config.identify_hook(), conn)
  def invoke(:metadata, conn), do: invoke_hook(Config.metadata_hook(), conn)

  defp invoke_hook(nil, _conn), do: nil

  defp invoke_hook({mod, fun, args}, conn)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, [conn | args])
  end

  defp invoke_hook(fun, conn) when is_function(fun, 1), do: fun.(conn)

  defp invoke_hook(_, _conn), do: nil
end
