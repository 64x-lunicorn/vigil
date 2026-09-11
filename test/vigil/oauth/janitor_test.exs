defmodule Vigil.OAuth.JanitorTest do
  @moduledoc """
  The janitor: what it sweeps, how often, and against which instant — driven
  without waiting five minutes for it.

  *What a sweep removes* is not asserted here any more. Every expiry OAuth
  persistence owns belongs to that seam and
  `test/vigil/oauth/persistence_test.exs` runs the claim against both
  adapters; every window the rate limiter owns belongs to its own seam and
  `test/vigil/rate_limit_test.exs` does the same. What is left is the
  janitor's: that both are asked through the values it was handed, that the
  limiter — the one swept table persistence does not own — is on its list at
  all, that it reschedules, and that it survives the limiter's table being
  gone.

  Still serial, and no longer for anything either seam holds:
  `Vigil.OAuth.Janitor` is registered under its module name and these tests
  drive it.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.{Janitor, Store}
  alias Vigil.OAuthCase
  alias Vigil.RateLimit

  @now 1_700_000_000
  @limiter_windows :vigil_rate_limits

  setup do
    OAuthCase.setup!()
  end

  defp mint_code(persistence, now), do: OAuthCase.mint_code(persistence, now)

  # `:sys.get_state/1` is a call, so it is handled after the `:sweep` info
  # message already in the mailbox — a barrier rather than a sleep.
  defp sweep_now do
    send(Janitor, :sweep)
    :sys.get_state(Janitor)
  end

  defp start_janitor(opts \\ []) do
    start_supervised!({Janitor, opts})
  end

  ## The seam

  test "the sweep goes through the persistence the janitor was handed", %{
    persistence: persistence
  } do
    # Every expiry OAuth persistence owns is swept by asking it, not by naming
    # the module that happens to hold the tables — so a janitor handed another
    # adapter sweeps that one and no other.
    test = self()

    recording = %{persistence | sweep_expired: fn now -> send(test, {:swept, now}) end}

    start_janitor(interval: :timer.minutes(5), now: fn -> @now end, persistence: recording)
    code = mint_code(persistence, @now - 3600)

    sweep_now()

    assert_received {:swept, @now}
    # The recording adapter swept nothing, so the expired code is still there:
    # what production sweeps is untouched by a janitor handed another value.
    assert {:ok, _} = persistence.take_code.(code)
  end

  test "the sweep reads its instant from the janitor, not from the wall clock", %{
    persistence: persistence
  } do
    test = self()
    recording = %{persistence | sweep_expired: fn now -> send(test, {:swept, now}) end}

    start_janitor(interval: :timer.minutes(5), now: fn -> @now - 7200 end, persistence: recording)
    sweep_now()

    assert_received {:swept, swept_at}
    assert swept_at == @now - 7200
  end

  ## The limiter that is not the store's

  test "the rate limiter's elapsed windows are swept through the value too", %{
    persistence: persistence
  } do
    # The limiter is the one swept table OAuth persistence does not own, and it
    # is keyed entirely on what arrives from outside: a client address per
    # authorization-server endpoint, and every access token ever presented at
    # `/mcp`. Refresh rotation mints a new access token about every hour, so
    # without this the table grows forever on ordinary traffic. *Which* windows
    # a sweep takes is the limiter's own claim, run against both its adapters
    # in `Vigil.RateLimitTest`; what is asserted here is that the janitor asks
    # at all, and asks the limiter it was handed rather than a module it names.
    test = self()

    recording = %{
      RateLimit.Counter.new()
      | sweep_expired: fn now -> send(test, {:limiter_swept, now}) end
    }

    start_janitor(
      interval: :timer.minutes(5),
      now: fn -> @now end,
      persistence: persistence,
      limiter: recording
    )

    sweep_now()

    assert_received {:limiter_swept, @now}
  end

  test "a sweep with the limiter restarting has nothing to reclaim and takes nobody down", %{
    persistence: persistence
  } do
    # The production limiter's table is owned by the limiter's process and is
    # gone while that process is restarting. The janitor is a sibling, not a
    # dependant: it must survive that window — which it does because the
    # production adapter answers "nothing reclaimed" rather than raising, a
    # guard that is that adapter's own and no part of the limiter contract.
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end, persistence: persistence)

    assert :ets.whereis(@limiter_windows) == :undefined

    janitor = Process.whereis(Janitor)
    sweep_now()

    assert Process.whereis(Janitor) == janitor
  end

  ## The interval

  test "the janitor sweeps again on its own, at the interval it was given", %{
    persistence: persistence
  } do
    start_janitor(interval: 10, now: fn -> @now end, persistence: persistence)

    # A code put *after* the first sweeps have run is still collected, which
    # only holds if the janitor rescheduled rather than swept once.
    Process.sleep(50)
    code = mint_code(persistence, @now - 3600)

    assert eventually(fn -> persistence.take_code.(code) == :error end)
  end

  defp eventually(condition, deadline \\ 2_000) do
    cond do
      condition.() -> true
      deadline <= 0 -> false
      true -> Process.sleep(10) && eventually(condition, deadline - 10)
    end
  end

  ## The production defaults

  test "the interval, the instant, the persistence and the limiter default to production" do
    start_janitor()
    state = :sys.get_state(Janitor)

    assert state.interval == :timer.minutes(5)
    assert_in_delta state.now.(), System.system_time(:second), 2
    assert state.persistence == Store.over_tables()
    assert state.limiter == RateLimit.over_table()
  end
end
