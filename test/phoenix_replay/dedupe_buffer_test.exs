defmodule PhoenixReplay.DedupeBufferTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.DedupeBuffer

  test "new/0 starts empty" do
    buf = DedupeBuffer.new()
    refute DedupeBuffer.member?(buf, 1)
  end

  test "put + member? round trip" do
    buf = DedupeBuffer.new() |> DedupeBuffer.put(42)
    assert DedupeBuffer.member?(buf, 42)
    refute DedupeBuffer.member?(buf, 7)
  end

  test "evicts oldest when capacity is exceeded" do
    buf = DedupeBuffer.new(3)

    buf =
      buf
      |> DedupeBuffer.put(:a)
      |> DedupeBuffer.put(:b)
      |> DedupeBuffer.put(:c)
      |> DedupeBuffer.put(:d)

    refute DedupeBuffer.member?(buf, :a), "oldest should be evicted"
    assert DedupeBuffer.member?(buf, :b)
    assert DedupeBuffer.member?(buf, :c)
    assert DedupeBuffer.member?(buf, :d)
  end

  test "put is idempotent — re-inserting an existing value is a no-op" do
    buf =
      DedupeBuffer.new(2)
      |> DedupeBuffer.put(:a)
      |> DedupeBuffer.put(:b)
      |> DedupeBuffer.put(:a)
      |> DedupeBuffer.put(:c)

    # :a was the first distinct value; a fourth distinct value (:c)
    # evicts it. :a's "re-put" did NOT shift queue position.
    refute DedupeBuffer.member?(buf, :a)
    assert DedupeBuffer.member?(buf, :b)
    assert DedupeBuffer.member?(buf, :c)
  end
end
