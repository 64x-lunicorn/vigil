defmodule Vigil.OAuth.JanitorTest do
  @moduledoc """
  The janitor's sweep, driven without waiting five minutes for it.

  The ephemeral tables are asserted by size rather than through the read API:
  an expired entry already reads as absent, so only the table itself shows
  whether the sweep reclaimed it. Unbounded growth is the whole point of the
  CIMD cache and of `Vigil.RateLimit`'s windows.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.{Code, Flow, Janitor, Store, Token}
  alias Vigil.RateLimit

  @now 1_700_000_000
  @rate_limits :oauth_rate_limits
  @cimd_cache :oauth_cimd_cache
  @limiter_windows :vigil_rate_limits

  setup do
    Vigil.OAuthCase.setup!()
  end

  ## Seeding

  # One entry that has expired at @now and one that has not, in each of the
  # four tables OAuth persistence owns. `Vigil.RateLimit`'s table is the fifth
  # the sweep walks and is seeded by the tests that cover it.
  defp seed(persistence) do
    codes = %{expired: mint_code(persistence, @now - 3600), live: mint_code(persistence, @now)}

    Store.put_token("token-expired", token_attrs(@now))
    Store.put_token("token-live", token_attrs(@now + 3600))

    # A rotated refresh token is marked spent rather than deleted, so it is a
    # row the sweep has to reclaim on its own expiry like any other. Only a
    # refresh record can be spent, so these are refresh-shaped.
    Token.spend_refresh(persistence, "token-spent-expired", refresh_attrs(@now), @now - 60)
    Token.spend_refresh(persistence, "token-spent-live", refresh_attrs(@now + 3600), @now - 60)

    # sweep_rate_limits/1 drops a window older than 15 minutes.
    Store.record_failure("198.51.100.1", @now - 901)
    Store.record_failure("198.51.100.2", @now)

    # cimd_cache_put/3 stores now + 3600, so a put an hour ago has expired.
    Store.cimd_cache_put("https://stale.example.org/m", doc("stale"), @now - 3600)
    Store.cimd_cache_put("https://fresh.example.org/m", doc("fresh"), @now - 3599)

    codes
  end

  # A real authorization code, minted by the module that owns the record
  # (Vigil.OAuth.Code) at the instant given — so what the sweep walks is the
  # shape production writes, `grant_id` and all, rather than a variant this
  # file made up. A code lives a minute, so one minted an hour ago has expired
  # at @now and one minted at @now has not.
  defp mint_code(persistence, now) do
    {:ok, %{client_id: client_id}} =
      Flow.register(persistence, %{"redirect_uris" => ["https://client.example.org/cb"]})

    {:ok, ctx} =
      Flow.authorize_request(persistence, %{
        "client_id" => client_id,
        "redirect_uri" => "https://client.example.org/cb",
        "response_type" => "code",
        "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method" => "S256"
      })

    Code.issue(persistence, ctx, now)
  end

  defp token_attrs(expires_at) do
    %{aud: "https://vault.factory-lab.org/mcp", scope: "vault", expires_at: expires_at}
  end

  defp refresh_attrs(expires_at) do
    token_attrs(expires_at)
    |> Map.merge(%{type: :refresh, client_id: "client-1", grant_id: "grant-1"})
  end

  defp doc(name) do
    %{client_id: name, name: name, redirect_uris: ["https://client.example.org/cb"]}
  end

  defp keys(entries), do: entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  # `:sys.get_state/1` is a call, so it is handled after the `:sweep` info
  # message already in the mailbox — a barrier rather than a sleep.
  defp sweep_now do
    send(Janitor, :sweep)
    :sys.get_state(Janitor)
  end

  defp start_janitor(opts \\ []) do
    start_supervised!({Janitor, opts})
  end

  ## One sweep, driven

  test "a sweep drops what expired and keeps what did not, in all four tables", %{
    persistence: persistence
  } do
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end)
    codes = seed(persistence)

    assert keys(Store.all_codes()) == Enum.sort([codes.expired, codes.live])

    assert keys(Store.all_tokens()) == [
             "token-expired",
             "token-live",
             "token-spent-expired",
             "token-spent-live"
           ]

    assert :ets.info(@rate_limits, :size) == 2
    assert :ets.info(@cimd_cache, :size) == 2

    sweep_now()

    assert keys(Store.all_codes()) == [codes.live]
    assert keys(Store.all_tokens()) == ["token-live", "token-spent-live"]

    assert :ets.lookup(@rate_limits, "198.51.100.1") == []
    assert [{"198.51.100.2", _count, _window}] = :ets.lookup(@rate_limits, "198.51.100.2")

    assert :ets.lookup(@cimd_cache, "https://stale.example.org/m") == []

    assert [{"https://fresh.example.org/m", _doc, _expires}] =
             :ets.lookup(@cimd_cache, "https://fresh.example.org/m")
  end

  test "the CIMD cache is swept at all" do
    # The table is keyed on the client_id URL a client supplies and is filled
    # from GET /oauth/authorize, so it grows on input from outside. The
    # per-address limit on that endpoint bounds the rate; only this sweep
    # bounds the total.
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end)

    for i <- 1..50 do
      Store.cimd_cache_put("https://client-#{i}.example.org/m", doc("c#{i}"), @now - 3600)
    end

    assert :ets.info(@cimd_cache, :size) == 50

    sweep_now()

    assert :ets.info(@cimd_cache, :size) == 0
  end

  test "the sweep reads its instant from the janitor, not from the wall clock", %{
    persistence: persistence
  } do
    # Everything seeded expires long before real "now", so a janitor holding an
    # instant from before them must keep all of it.
    start_janitor(interval: :timer.minutes(5), now: fn -> @now - 7200 end)
    codes = seed(persistence)

    sweep_now()

    assert keys(Store.all_codes()) == Enum.sort([codes.expired, codes.live])

    assert keys(Store.all_tokens()) == [
             "token-expired",
             "token-live",
             "token-spent-expired",
             "token-spent-live"
           ]

    assert :ets.info(@cimd_cache, :size) == 2
  end

  ## The limiter that is not the store's

  test "the request limiter's elapsed windows are swept too" do
    # `Vigil.RateLimit` is the one swept table `Vigil.OAuth.Store` does not
    # own, and it is keyed entirely on what arrives from outside: a client
    # address per authorization-server endpoint, and every access token ever
    # presented at `/mcp`. Refresh rotation mints a new access token about
    # every hour, so without this the table grows forever on ordinary traffic.
    # The live window is here to be left alone: a sweep that took it would
    # hand its caller a budget it has not waited out. `Vigil.RateLimitTest`
    # pins that boundary to the second.
    start_supervised!(RateLimit)
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end)

    refute RateLimit.limited?({:oauth, :authorize, "198.51.100.3"}, 60, @now - 61)
    refute RateLimit.limited?("access-token-rotated-away", 60, @now - 61)
    refute RateLimit.limited?("access-token-in-use", 60, @now)

    assert :ets.info(@limiter_windows, :size) == 3

    sweep_now()

    assert :ets.info(@limiter_windows, :size) == 1

    assert [{"access-token-in-use", _count, _window}] =
             :ets.lookup(@limiter_windows, "access-token-in-use")
  end

  test "a sweep with the limiter restarting has nothing to reclaim and takes nobody down" do
    # The limiter's table is owned by the limiter's process, so between that
    # process dying and its supervisor restarting it there is no table. The
    # janitor is a sibling, not a dependant: it must survive that window.
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end)

    assert :ets.whereis(@limiter_windows) == :undefined

    janitor = Process.whereis(Janitor)
    sweep_now()

    assert Process.whereis(Janitor) == janitor
  end

  ## The interval

  test "the janitor sweeps again on its own, at the interval it was given", %{
    persistence: persistence
  } do
    start_janitor(interval: 10, now: fn -> @now end)

    # A code put *after* the first sweeps have run is still collected, which
    # only holds if the janitor rescheduled rather than swept once.
    Process.sleep(50)
    mint_code(persistence, @now - 3600)

    assert eventually(fn -> keys(Store.all_codes()) == [] end)
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

  ## The seam

  test "the sweep goes through the persistence the janitor was handed", %{
    persistence: persistence
  } do
    # Every expiry OAuth persistence owns is swept by asking it, not by naming
    # the module that happens to hold the tables — so a janitor handed another
    # adapter sweeps that one. Handing it one that only records is the whole
    # claim: what production sweeps is untouched here.
    test = self()

    recording = %{persistence | sweep_expired: fn now -> send(test, {:swept, now}) end}

    start_janitor(interval: :timer.minutes(5), now: fn -> @now end, persistence: recording)
    codes = seed(persistence)

    sweep_now()

    assert_received {:swept, @now}
    assert keys(Store.all_codes()) == Enum.sort([codes.expired, codes.live])
  end
end
