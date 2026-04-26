defmodule PhoenixReplay.DedupeBuffer do
  @moduledoc false
  # Sliding-window dedup buffer used by `PhoenixReplay.Session` to
  # absorb duplicate `seq` values that bypass the storage adapter's
  # uniqueness check (e.g. client retries after a flaky network).
  #
  # Pure data structure — no process, no message passing. Stays inside
  # the calling Session's state so dedup is per-session and dies with
  # the process. Insertion order via `:queue`, O(1) membership via
  # `MapSet`, eviction kicks in when length exceeds `:capacity`.

  defstruct queue: :queue.new(), set: MapSet.new(), capacity: 50

  @type t :: %__MODULE__{
          queue: :queue.queue(term()),
          set: MapSet.t(),
          capacity: pos_integer()
        }

  @doc """
  Returns a new buffer with the given capacity (default 50).
  """
  @spec new(pos_integer()) :: t()
  def new(capacity \\ 50) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity}
  end

  @doc """
  True when `value` is in the buffer's recent-window. O(1).
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{set: set}, value), do: MapSet.member?(set, value)

  @doc """
  Inserts `value` into the buffer. Idempotent — re-inserting an
  existing value is a no-op (avoids the queue/set drift that would
  otherwise evict a still-present value when the duplicate is
  later dropped). If the buffer is at capacity, the oldest distinct
  value is evicted before insertion.
  """
  @spec put(t(), term()) :: t()
  def put(%__MODULE__{set: set} = buf, value) do
    if MapSet.member?(set, value) do
      buf
    else
      put_new(buf, value)
    end
  end

  defp put_new(%__MODULE__{queue: queue, set: set, capacity: capacity} = buf, value) do
    queue = :queue.in(value, queue)
    set = MapSet.put(set, value)

    if :queue.len(queue) > capacity do
      {{:value, dropped}, queue2} = :queue.out(queue)
      %{buf | queue: queue2, set: MapSet.delete(set, dropped)}
    else
      %{buf | queue: queue, set: set}
    end
  end
end
