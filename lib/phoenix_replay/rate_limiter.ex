defmodule PhoenixReplay.RateLimiter do
  @moduledoc false
  # Fixed-window rate limiter backed by a public ETS table. A single
  # GenServer owns the table and periodically sweeps stale buckets; all
  # hits are lock-free `:ets.update_counter/4` calls from the controllers.
  #
  # Windows are keyed by `{rate_key, bucket_number}` where the bucket
  # number is `div(unix_seconds, window_seconds)`. A burst that lands
  # on a window boundary can allow up to `2 * limit` in rapid succession,
  # which is acceptable for DoS-prevention caps.

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000
  @bucket_ttl_windows 3

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers a hit against `key`; returns `:ok` if under `limit`,
  otherwise `{:error, :rate_limited, retry_after :: pos_integer()}`
  where `retry_after` is seconds until the next window opens.
  """
  @spec hit(term(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def hit(key, limit, window_seconds)
      when is_integer(limit) and limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    now = System.system_time(:second)
    bucket = div(now, window_seconds)
    counter_key = {key, bucket}
    count = :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0})

    if count > limit do
      retry_after = window_seconds - rem(now, window_seconds)
      {:error, :rate_limited, retry_after}
    else
      :ok
    end
  end

  @doc false
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep do
    # Naive bucket sweep: drop any bucket older than `@bucket_ttl_windows`
    # at the largest window we use (actor_rate 60s → 3 min of history is
    # plenty). Keyed `{_, bucket}` where bucket is seconds-derived.
    cutoff = System.system_time(:second) - @bucket_ttl_windows * 60
    cutoff_bucket = div(cutoff, 60)

    :ets.foldl(
      fn {{_key, bucket} = tk, _count}, _acc when bucket < cutoff_bucket ->
           :ets.delete(@table, tk)

         _entry, acc ->
           acc
      end,
      :ok,
      @table
    )
  end
end
