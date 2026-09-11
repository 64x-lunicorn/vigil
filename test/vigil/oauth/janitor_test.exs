defmodule Vigil.OAuth.JanitorTest do
  @moduledoc """
  The janitor: what it sweeps, how often, and against which instant — driven
  without waiting five minutes for it.

  *What a sweep removes* is not asserted here any more. Every expiry OAuth
  persistence owns belongs to the seam, and
  `test/vigil/oauth/persistence_test.exs` runs that claim against both
  adapters. What is left is the janitor's own: that it asks through the value
  it was handed, that `Vigil.RateLimit`'s table — the one swept table
  persistence does not own — is on its list, that it reschedules, and that it
  survives the limiter being gone.

  Still serial, and no longer for anything to do with persistence:
  `Vigil.OAuth.Janitor` and `Vigil.RateLimit` are both registered under their
  module names, and these tests drive both.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.{Client, Code, Flow, Janitor, Store}
  alias Vigil.RateLimit

  @now 1_700_000_000
  @redirect_uri "https://client.example.org/cb"
  @limiter_windows :vigil_rate_limits

  setup do
    Vigil.OAuthCase.setup!()
  end

  # A real authorization code, minted by the module that owns the record at
  # the instant given. A code lives a minute, so one minted an hour ago has
  # expired at @now and one minted at @now has not.
  defp mint_code(persistence, now) do
    client = Client.register(persistence, "Client", [@redirect_uri], now)

    {:ok, ctx} =
      Flow.authorize_request(persistence, %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method" => "S256"
      })

    Code.issue(persistence, ctx, now)
  end

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

  test "the request limiter's elapsed windows are swept too", %{persistence: persistence} do
    # `Vigil.RateLimit` is the one swept table OAuth persistence does not own,
    # and it is keyed entirely on what arrives from outside: a client address
    # per authorization-server endpoint, and every access token ever presented
    # at `/mcp`. Refresh rotation mints a new access token about every hour, so
    # without this the table grows forever on ordinary traffic. The live window
    # is here to be left alone: a sweep that took it would hand its caller a
    # budget it has not waited out. `Vigil.RateLimitTest` pins that boundary to
    # the second.
    start_supervised!(RateLimit)
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end, persistence: persistence)

    refute RateLimit.limited?({:oauth, :authorize, "198.51.100.3"}, 60, @now - 61)
    refute RateLimit.limited?("access-token-rotated-away", 60, @now - 61)
    refute RateLimit.limited?("access-token-in-use", 60, @now)

    assert :ets.info(@limiter_windows, :size) == 3

    sweep_now()

    assert :ets.info(@limiter_windows, :size) == 1

    assert [{"access-token-in-use", _count, _window}] =
             :ets.lookup(@limiter_windows, "access-token-in-use")
  end

  test "a sweep with the limiter restarting has nothing to reclaim and takes nobody down", %{
    persistence: persistence
  } do
    # The limiter's table is owned by the limiter's process, so between that
    # process dying and its supervisor restarting it there is no table. The
    # janitor is a sibling, not a dependant: it must survive that window.
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

  test "the interval, the instant and the persistence default to the production values" do
    start_janitor()
    state = :sys.get_state(Janitor)

    assert state.interval == :timer.minutes(5)
    assert_in_delta state.now.(), System.system_time(:second), 2
    assert state.persistence == Store.over_tables()
  end
end
