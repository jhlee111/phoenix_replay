defmodule PhoenixReplay.Scrub do
  @moduledoc """
  Applies PII scrubbing rules to event payloads before storage.

  Rules come from `config :phoenix_replay, :scrub` (see
  `PhoenixReplay.Config`). Two families of rules apply:

    * `:console` — a list of `Regex.t()` patterns. Every string leaf in
      the event tree is scanned; matches are replaced with `[REDACTED]`.
    * `:query_deny_list` — a list of query-parameter names whose values
      are dropped from captured URLs (in any string that parses as a
      URL with a query string).

  Request / response bodies are **never** captured in v0 regardless of
  scrub config — the rrweb network plugin is configured accordingly on
  the client.

  The default ruleset strips bearer tokens, `api_key=...` patterns, and
  common secret-name query params. Hosts extend or replace these via
  config.
  """

  @redaction "[REDACTED]"

  @default_console_regexes [
    ~r/Bearer\s+[A-Za-z0-9._\-]+/,
    ~r/api[_-]?key[=:"'\s]+[A-Za-z0-9._\-]+/i
  ]

  @default_query_deny_list ~w(token access_token password secret code)

  @doc """
  Scrubs a list of rrweb event maps. Returns the same list with
  string leaves redacted according to the configured rules.
  """
  @spec scrub_batch([map()], keyword()) :: [map()]
  def scrub_batch(batch, opts \\ []) when is_list(batch) do
    rules = merge_rules(opts)
    Enum.map(batch, &scrub_value(&1, rules))
  end

  @doc false
  def scrub_value(value, rules)

  def scrub_value(map, rules) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, scrub_value(v, rules)} end)
  end

  def scrub_value(list, rules) when is_list(list) do
    Enum.map(list, &scrub_value(&1, rules))
  end

  def scrub_value(bin, rules) when is_binary(bin) do
    bin
    |> scrub_query_params(rules.query_deny_list)
    |> apply_regex_scrubs(rules.console)
  end

  def scrub_value(other, _rules), do: other

  defp merge_rules(opts) do
    configured = PhoenixReplay.Config.scrub()

    %{
      console:
        Keyword.get(opts, :console) ||
          Keyword.get(configured, :console, @default_console_regexes),
      query_deny_list:
        Keyword.get(opts, :query_deny_list) ||
          Keyword.get(configured, :query_deny_list, @default_query_deny_list)
    }
  end

  defp apply_regex_scrubs(str, regexes) do
    Enum.reduce(regexes, str, fn regex, acc ->
      Regex.replace(regex, acc, @redaction)
    end)
  end

  defp scrub_query_params(str, []), do: str

  defp scrub_query_params(str, deny_list) do
    # Cheap probe: only parse strings that look like URLs with a query
    # string. Skip the URI round-trip otherwise.
    if String.contains?(str, "?") and String.contains?(str, "=") do
      try do
        uri = URI.parse(str)

        if uri.query do
          new_query =
            uri.query
            |> URI.decode_query()
            |> Map.new(fn {k, v} ->
              if k in deny_list, do: {k, @redaction}, else: {k, v}
            end)
            |> URI.encode_query()

          URI.to_string(%{uri | query: new_query})
        else
          str
        end
      rescue
        _ -> str
      end
    else
      str
    end
  end
end
