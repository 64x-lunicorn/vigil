defmodule Vigil.OAuth.JanitorTest do
  @moduledoc """
  The janitor's sweep, driven without waiting five minutes for it.

  Both ephemeral tables are asserted by size rather than through the read
  API: an expired entry already reads as absent, so only the table itself
  shows whether the sweep reclaimed it. Unbounded growth is the whole point
  of the CIMD half.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.{Janitor, Store}

  @now 1_700_000_000
  @rate_limits :oauth_rate_limits
  @cimd_cache :oauth_cimd_cache

  setup do
    Vigil.OAuthCase.setup!()
    :ok
  end

  ## Seeding

  # One entry that has expired at @now and one that has not, in each of the
  # four tables the sweep walks.
  defp seed do
    Store.put_code("code-expired", code_attrs(@now))
    Store.put_code("code-live", code_attrs(@now + 60))

    Store.put_token("token-expired", token_attrs(@now))
    Store.put_token("token-live", token_attrs(@now + 3600))

    # A rotated refresh token is marked spent rather than deleted, so it is a
    # row the sweep has to reclaim on its own expiry like any other.
    Store.spend_token("token-spent-expired", token_attrs(@now), @now - 60)
    Store.spend_token("token-spent-live", token_attrs(@now + 3600), @now - 60)

    # sweep_rate_limits/1 drops a window older than 15 minutes.
    Store.record_failure("198.51.100.1", @now - 901)
    Store.record_failure("198.51.100.2", @now)

    # cimd_cache_put/3 stores now + 3600, so a put an hour ago has expired.
    Store.cimd_cache_put("https://stale.example.org/m", doc("stale"), @now - 3600)
    Store.cimd_cache_put("https://fresh.example.org/m", doc("fresh"), @now - 3599)
  end

  defp code_attrs(expires_at) do
    %{
      client_id: "client-1",
      redirect_uri: "https://client.example.org/cb",
      code_challenge: "challenge",
      resource: "https://vault.factory-lab.org/mcp",
      scope: "vault",
      expires_at: expires_at
    }
  end

  defp token_attrs(expires_at) do
    %{aud: "https://vault.factory-lab.org/mcp", scope: "vault", expires_at: expires_at}
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

  test "a sweep drops what expired and keeps what did not, in all four tables" do
    start_janitor(interval: :timer.minutes(5), now: fn -> @now end)
    seed()

    assert keys(Store.all_codes()) == ["code-expired", "code-live"]

    assert keys(Store.all_tokens()) == [
             "token-expired",
             "token-live",
             "token-spent-expired",
             "token-spent-live"
           ]

    assert :ets.info(@rate_limits, :size) == 2
    assert :ets.info(@cimd_cache, :size) == 2

    sweep_now()

    assert keys(Store.all_codes()) == ["code-live"]
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

  test "the sweep reads its instant from the janitor, not from the wall clock" do
    # Everything seeded expires long before real "now", so a janitor holding an
    # instant from before them must keep all of it.
    start_janitor(interval: :timer.minutes(5), now: fn -> @now - 7200 end)
    seed()

    sweep_now()

    assert keys(Store.all_codes()) == ["code-expired", "code-live"]

    assert keys(Store.all_tokens()) == [
             "token-expired",
             "token-live",
             "token-spent-expired",
             "token-spent-live"
           ]

    assert :ets.info(@cimd_cache, :size) == 2
  end

  ## The interval

  test "the janitor sweeps again on its own, at the interval it was given" do
    start_janitor(interval: 10, now: fn -> @now end)

    # A code put *after* the first sweeps have run is still collected, which
    # only holds if the janitor rescheduled rather than swept once.
    Process.sleep(50)
    Store.put_code("code-late", code_attrs(@now))

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

  test "the interval and the instant default to the production values" do
    start_janitor()
    state = :sys.get_state(Janitor)

    assert state.interval == :timer.minutes(5)
    assert_in_delta state.now.(), System.system_time(:second), 2
  end
end
