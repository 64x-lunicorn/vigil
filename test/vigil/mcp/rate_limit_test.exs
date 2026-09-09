defmodule Vigil.MCP.RateLimitTest do
  # Vigil.MCP.RateLimit is a named singleton also started by ServerTest, so
  # this stays async: false to avoid a name collision with it.
  use ExUnit.Case, async: false

  alias Vigil.MCP.RateLimit

  setup do
    start_supervised!(RateLimit)
    :ok
  end

  test "a request under budget is allowed" do
    now = 1_700_000_000
    refute RateLimit.limited?("key-a", 2, now)
    refute RateLimit.limited?("key-a", 2, now + 1)
  end

  test "the request that exceeds the budget is refused" do
    now = 1_700_000_000
    refute RateLimit.limited?("key-b", 2, now)
    refute RateLimit.limited?("key-b", 2, now + 1)
    assert RateLimit.limited?("key-b", 2, now + 2)
  end

  test "a request arriving after the window has elapsed resets the count instead of being refused" do
    now = 1_700_000_000
    refute RateLimit.limited?("key-c", 1, now)
    assert RateLimit.limited?("key-c", 1, now + 1)

    # 61s later — one second past the fixed 60s window — resets rather than
    # staying refused. This branch was unreachable before the caller could
    # inject `now`: the only production caller dropped the instant.
    refute RateLimit.limited?("key-c", 1, now + 61)
  end

  test "different keys have independent budgets" do
    now = 1_700_000_000
    refute RateLimit.limited?("key-d1", 1, now)
    refute RateLimit.limited?("key-d2", 1, now)
    assert RateLimit.limited?("key-d1", 1, now + 1)
    assert RateLimit.limited?("key-d2", 1, now + 1)
  end
end
