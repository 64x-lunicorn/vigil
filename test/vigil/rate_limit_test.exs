defmodule Vigil.RateLimitTest do
  @moduledoc """
  The rate limiter contract, run against both adapters (`docs/design.md`, "The
  rate limiter is reached through a value").

  Two things are pinned here. The first is the rule the seam is built on: both
  questions have to be answered where the adapter is built, because a
  `limited?` nobody wired answers `false` — which is not a limiter with a
  missing part, it is every caller served unlimited.

  The second is what a limiter actually owes its callers, asserted at the seam
  and against both adapters: that a caller inside its budget is not limited
  and the one over it is, that the window is fixed rather than sliding, that
  budgets are counted per key, and that a sweep reclaims exactly the windows
  the limit check would already ignore. Two adapters drifting apart is the one
  thing that can go wrong with a second one, which is why the contract is
  tested rather than assumed.

  This file is the only one that starts `Vigil.RateLimit`, and it is async
  because it is the only one: the production adapter's table is the node's
  one, owned by a process registered under that module, so a second file
  starting it would clash with this one over the name and over what is in the
  table. Every other file that needs a limiter builds a counting one of its
  own.
  """
  use ExUnit.Case, async: true

  alias Vigil.RateLimit

  @now 1_700_000_000
  @table :vigil_rate_limits

  # The whole contract, with the arity each question is asked at. Written out
  # rather than read off the struct, because a test that derives the list from
  # the thing it checks passes whatever that thing says.
  @questions [limited?: 3, sweep_expired: 1]

  defp every_answer, do: for({question, _arity} <- @questions, do: {question, fn -> :ok end})

  describe "new/1" do
    test "builds a limiter when both questions are answered" do
      assert %RateLimit{} = RateLimit.new(every_answer())
    end

    test "a question left unwired raises where the adapter is built" do
      for {question, _arity} <- @questions do
        missing = Keyword.delete(every_answer(), question)

        assert_raise ArgumentError, ~r/#{question}/, fn -> RateLimit.new(missing) end
      end
    end

    test "a field the contract does not declare raises" do
      assert_raise KeyError, fn ->
        RateLimit.new(Keyword.put(every_answer(), :window_seconds, fn -> :ok end))
      end
    end
  end

  ## The two adapters

  # The node's one named table, owned by the process this starts. No other file
  # starts it, so the table these tests count in is theirs — and the two tests
  # below that need it *gone* can say so.
  defp named_table(_ctx) do
    start_supervised!(RateLimit)
    {:ok, limiter: RateLimit.over_table()}
  end

  defp counting(_ctx), do: {:ok, limiter: RateLimit.Counter.new()}

  ## What both adapters are asked

  for {adapter, setup_fun} <- [
        {"the named table", :named_table},
        {"counting in process", :counting}
      ] do
    describe "#{adapter}" do
      setup(setup_fun)

      test "a request under budget is allowed", %{limiter: limiter} do
        refute limiter.limited?.("key-a", 2, @now)
        refute limiter.limited?.("key-a", 2, @now + 1)
      end

      test "the request that exceeds the budget is refused", %{limiter: limiter} do
        refute limiter.limited?.("key-b", 2, @now)
        refute limiter.limited?.("key-b", 2, @now + 1)
        assert limiter.limited?.("key-b", 2, @now + 2)
      end

      # The window is fixed, not sliding: it begins at the first request and
      # ends a minute later whatever arrives in between, so a refused caller
      # waits out the window rather than the last refusal.
      test "a request after the window has elapsed resets the count instead of being refused",
           %{limiter: limiter} do
        refute limiter.limited?.("key-c", 1, @now)
        assert limiter.limited?.("key-c", 1, @now + 1)
        assert limiter.limited?.("key-c", 1, @now + 60)

        refute limiter.limited?.("key-c", 1, @now + 61)
      end

      test "different keys have independent budgets", %{limiter: limiter} do
        refute limiter.limited?.("key-d1", 1, @now)
        refute limiter.limited?.("key-d2", 1, @now)
        assert limiter.limited?.("key-d1", 1, @now + 1)
        assert limiter.limited?.("key-d2", 1, @now + 1)
      end

      # An elapsed window already reads as absent through `limited?`, so what
      # the sweep took is only visible in what it answers.
      test "a sweep reclaims a window that has elapsed", %{limiter: limiter} do
        refute limiter.limited?.("key-e", 1, @now)

        assert limiter.sweep_expired.(@now + 61) == 1
        assert limiter.sweep_expired.(@now + 61) == 0
      end

      test "a window still inside its minute survives, and its caller stays refused", %{
        limiter: limiter
      } do
        refute limiter.limited?.("key-f", 1, @now)

        # 60s on is the last instant `limited?` still counts the window at, so
        # it is the last instant the sweep must keep it. A sweep that reclaimed
        # here would hand the caller a fresh budget it has not waited out.
        assert limiter.sweep_expired.(@now + 60) == 0
        assert limiter.limited?.("key-f", 1, @now + 60)
      end

      test "a sweep reclaims the elapsed windows and leaves the live ones", %{limiter: limiter} do
        refute limiter.limited?.("key-g-old", 1, @now)
        refute limiter.limited?.("key-g-live", 1, @now + 61)

        assert limiter.sweep_expired.(@now + 61) == 1
        # The live one is untouched: it is still counting, and still refusing.
        assert limiter.limited?.("key-g-live", 1, @now + 61)
      end
    end
  end

  ## What only the production adapter can be asked

  describe "the named table alone" do
    # The table belongs to the limiter's process and is gone while that process
    # is restarting, so a sweep can arrive to no table at all. The janitor that
    # asked must not go down over it — and this guard is this adapter's own,
    # not part of the contract: an adapter with no table to lose has nothing to
    # say about it.
    test "a sweep with the table gone reclaims nothing and takes nobody down" do
      assert :ets.whereis(@table) == :undefined
      assert RateLimit.over_table().sweep_expired.(@now) == 0
    end

    # `limited?` deliberately does not do the same: on the request path a
    # missing table means the limiter is not running, and crashing the request
    # is the honest answer where answering "not limited" would quietly serve
    # every caller unlimited.
    test "a limit check with the table gone crashes rather than serving the caller" do
      assert :ets.whereis(@table) == :undefined

      assert_raise ArgumentError, fn ->
        RateLimit.over_table().limited?.("key-h", 1, @now)
      end
    end
  end

  describe "budget/3" do
    # What counts as a budget is the limiter's question rather than each
    # caller's, so both surfaces ask it the same way. What the deployment
    # configured arrives as an argument, the way every other claim in this
    # file arrives: the budgets under test are stated here, and nothing in an
    # async file writes a budget into global application env to state one.
    #
    # `budget/2` is the read that produces that argument — one
    # `Application.get_env/3` with the default in it, so an unset key arrives
    # here as the default and is judged a budget rather than a
    # misconfiguration. It belongs to the composition root that does the
    # reading, and that is where it is covered: `Vigil.OAuth.EndpointTest`
    # asks `init/1` for the budgets it resolved and names what the deployment
    # configured, without writing any of it.

    test "a positive integer is the budget" do
      assert RateLimit.budget(:rate_limit_rpm, 42, 60) == 42
    end

    test "the default is a budget too, which is how an unset key stays quiet" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert RateLimit.budget(:rate_limit_rpm, 60, 60) == 60
        end)

      # Not `log == ""`: `capture_log` captures the whole node's Logger output,
      # not this process's, so in a parallel suite another file's load line can
      # land inside the block. What the claim is about is this key — an unset
      # budget is not a misconfiguration and must not be reported as one — and
      # the test below asserts the exact opposite for a value that is one.
      refute log =~ "rate_limit_rpm"
    end

    test "a value that is not a budget falls back to the default, loudly" do
      for bad <- [0, -1, nil, "30", 1.5] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert RateLimit.budget(:rate_limit_rpm, bad, 60) == 60
          end)

        # A limit that is quietly not the one you configured is worse than a
        # loud one: the operator has to be able to find out, and the warning
        # names the setting because a deployment configures three of them.
        assert log =~ "rate_limit_rpm"
        assert log =~ "not a positive integer"
      end
    end
  end
end
