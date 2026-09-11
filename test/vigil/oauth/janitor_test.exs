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

  Every janitor here is started unregistered and driven by pid. The name is
  the janitor's fifth argument for that reason: registered under its module it
  is the node's one janitor, and a file that drives that one can only be the
  node's one file driving it.
  """

  use ExUnit.Case, async: true

  alias Vigil.OAuth.{Janitor, Store}
  alias Vigil.OAuthCase
  alias Vigil.RateLimit

  @now 1_700_000_000

  setup do
    OAuthCase.setup!()
  end

  defp mint_code(persistence, now), do: OAuthCase.mint_code(persistence, now)

  # `:sys.get_state/1` is a call, so it is handled after the `:sweep` info
  # message already in the mailbox — a barrier rather than a sleep.
  defp sweep_now(janitor) do
    send(janitor, :sweep)
    :sys.get_state(janitor)
  end

  # Unregistered, so the janitor this test drives is this test's own and
  # nothing else on the node can reach it.
  defp start_janitor(opts \\ []) do
    start_supervised!({Janitor, Keyword.put_new(opts, :name, nil)})
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

    janitor =
      start_janitor(interval: :timer.minutes(5), now: fn -> @now end, persistence: recording)

    code = mint_code(persistence, @now - 3600)

    sweep_now(janitor)

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

    janitor =
      start_janitor(
        interval: :timer.minutes(5),
        now: fn -> @now - 7200 end,
        persistence: recording
      )

    sweep_now(janitor)

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

    janitor =
      start_janitor(
        interval: :timer.minutes(5),
        now: fn -> @now end,
        persistence: persistence,
        limiter: recording
      )

    sweep_now(janitor)

    assert_received {:limiter_swept, @now}
  end

  test "a sweep that reclaims nothing is not an error and leaves the janitor running", %{
    persistence: persistence
  } do
    # The production limiter's table is owned by the limiter's process and is
    # gone while that process is restarting. The janitor is a sibling, not a
    # dependant: it must survive that window. What reaches it is whatever the
    # value answers — the production adapter answers "nothing reclaimed"
    # rather than raising, a guard that is that adapter's own, no part of the
    # limiter contract, and asserted where it lives, in `Vigil.RateLimitTest`.
    # The janitor's half is this: an empty sweep is not an error, and the
    # janitor that asked for it is still there afterwards.
    empty = RateLimit.Counter.new()
    assert empty.sweep_expired.(@now) == 0

    janitor =
      start_janitor(
        interval: :timer.minutes(5),
        now: fn -> @now end,
        persistence: persistence,
        limiter: empty
      )

    sweep_now(janitor)

    assert Process.alive?(janitor)
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
    state = start_janitor() |> :sys.get_state()

    assert state.interval == :timer.minutes(5)
    assert_in_delta state.now.(), System.system_time(:second), 2
    assert state.persistence == Store.over_tables()
    assert state.limiter == RateLimit.over_table()
  end
end
