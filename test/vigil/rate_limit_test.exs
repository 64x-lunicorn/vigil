defmodule Vigil.RateLimitTest do
  # Vigil.RateLimit is a named singleton also started by ServerTest, so
  # this stays async: false to avoid a name collision with it.
  use ExUnit.Case, async: false

  alias Vigil.RateLimit

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

  describe "budget/2" do
    # Both surfaces read their budget from application config, so what counts
    # as a budget is the limiter's question rather than each caller's.
    setup do
      on_exit(fn -> Application.delete_env(:vigil, :test_budget) end)
      :ok
    end

    test "a positive integer is the budget" do
      Application.put_env(:vigil, :test_budget, 42)
      assert RateLimit.budget(:test_budget, 60) == 42
    end

    test "an unset key falls back to the default without complaining" do
      log =
        ExUnit.CaptureLog.capture_log(fn -> assert RateLimit.budget(:test_budget, 60) == 60 end)

      assert log == ""
    end

    test "a value that is not a budget falls back to the default, loudly" do
      for bad <- [0, -1, nil, "30", 1.5] do
        Application.put_env(:vigil, :test_budget, bad)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert RateLimit.budget(:test_budget, 60) == 60
          end)

        # A limit that is quietly not the one you configured is worse than a
        # loud one: the operator has to be able to find out.
        assert log =~ "test_budget"
        assert log =~ "not a positive integer"
      end
    end
  end

  test "different keys have independent budgets" do
    now = 1_700_000_000
    refute RateLimit.limited?("key-d1", 1, now)
    refute RateLimit.limited?("key-d2", 1, now)
    assert RateLimit.limited?("key-d1", 1, now + 1)
    assert RateLimit.limited?("key-d2", 1, now + 1)
  end

  describe "sweep_expired/1" do
    # An elapsed window already reads as absent through `limited?/3`, so only
    # the table itself shows whether the row was reclaimed.
    @table :vigil_rate_limits

    test "a window that has elapsed is reclaimed" do
      now = 1_700_000_000
      refute RateLimit.limited?("key-e", 1, now)
      assert [{"key-e", 1, ^now}] = :ets.lookup(@table, "key-e")

      assert RateLimit.sweep_expired(now + 61) == 1
      assert :ets.lookup(@table, "key-e") == []
    end

    test "a window still inside its minute survives, and its caller stays refused" do
      now = 1_700_000_000
      refute RateLimit.limited?("key-f", 1, now)

      # 60s on is the last instant `limited?/3` still counts the window at, so
      # it is the last instant the sweep must keep it. A sweep that reclaimed
      # here would hand the caller a fresh budget it has not waited out.
      assert RateLimit.sweep_expired(now + 60) == 0
      assert RateLimit.limited?("key-f", 1, now + 60)
    end

    test "a sweep reclaims the elapsed windows and leaves the live ones" do
      now = 1_700_000_000
      refute RateLimit.limited?("key-g-old", 1, now)
      refute RateLimit.limited?("key-g-live", 1, now + 61)

      assert RateLimit.sweep_expired(now + 61) == 1
      assert :ets.lookup(@table, "key-g-old") == []
      assert [{"key-g-live", 1, _}] = :ets.lookup(@table, "key-g-live")
    end
  end
end
