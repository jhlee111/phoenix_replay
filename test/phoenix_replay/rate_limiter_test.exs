defmodule PhoenixReplay.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "allows hits under the limit" do
    for _ <- 1..5 do
      assert :ok = RateLimiter.hit({:test, :under}, 5, 60)
    end
  end

  test "rejects past the limit with retry_after" do
    for _ <- 1..3, do: :ok = RateLimiter.hit({:test, :cap}, 3, 60)

    assert {:error, :rate_limited, retry} = RateLimiter.hit({:test, :cap}, 3, 60)
    assert retry > 0 and retry <= 60
  end

  test "distinct keys have independent counters" do
    for _ <- 1..2, do: :ok = RateLimiter.hit({:test, :a}, 2, 60)
    assert {:error, :rate_limited, _} = RateLimiter.hit({:test, :a}, 2, 60)
    # Different key — fresh budget.
    assert :ok = RateLimiter.hit({:test, :b}, 2, 60)
  end
end
