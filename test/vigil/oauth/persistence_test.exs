defmodule Vigil.OAuth.PersistenceTest do
  @moduledoc """
  The persistence contract, and the only file in the suite that opens a
  `:dets` file (`docs/design.md`, "OAuth persistence is reached through a
  value").

  Two things are pinned here. The first is the rule the seam is built on:
  every question has to be answered where the adapter is built, because each
  of them guards something — a token's existence, a lockout, an expiry — and
  every plausible answer to a question nobody wired sits on the permissive
  side of the gate it feeds.

  The second is what persistence actually owns, asserted at the seam rather
  than through an endpoint, and asserted against both adapters: that a code is
  single-use, that rotation marks a refresh token spent rather than deleting
  it, that revoking a grant takes down a family, that the consent lockout
  counts per address and expires with its window, that the CIMD cache honours
  its hour, and that a sweep drops exactly what has expired. Two adapters
  drifting apart is the one thing that can go wrong with a second one, which
  is why the contract is tested rather than assumed.
  """
  use ExUnit.Case, async: true

  alias Vigil.OAuth
  alias Vigil.OAuth.{Persistence, Store, Token}
  alias Vigil.OAuthCase

  @now 1_700_000_000

  # The audience the token records below carry. Persistence stores it and
  # gives it back; what it says is nothing this seam decides, so the test
  # states one rather than reading the deployment's.
  @resource "https://vault.factory-lab.org/mcp"

  # The whole contract, with the arity each question is asked at. Written out
  # rather than read off the struct, because a test that derives the list from
  # the thing it checks passes whatever that thing says.
  @questions [
    put_client: 2,
    get_client: 1,
    put_code: 2,
    take_code: 1,
    put_token: 2,
    get_token: 1,
    delete_token: 1,
    revoke_grant: 1,
    rate_limited?: 2,
    record_failure: 2,
    reset_rate_limit: 1,
    cimd_cache_get: 2,
    cimd_cache_put: 3,
    sweep_expired: 1
  ]

  defp every_answer, do: for({question, _arity} <- @questions, do: {question, fn -> :ok end})

  describe "new/1" do
    test "builds a persistence when every question is answered" do
      assert %Persistence{} = Persistence.new(every_answer())
    end

    test "a question left unwired raises where the adapter is built" do
      for {question, _arity} <- @questions do
        missing = Keyword.delete(every_answer(), question)

        assert_raise ArgumentError, ~r/#{question}/, fn -> Persistence.new(missing) end
      end
    end

    test "a field the contract does not declare raises" do
      assert_raise KeyError, fn ->
        Persistence.new(Keyword.put(every_answer(), :put_session, fn -> :ok end))
      end
    end
  end

  ## The two adapters

  # The one `:dets` store the suite still opens, and it is opened here. Its
  # tables are globally named, so this is also the only file that may start it
  # while anything else is running.
  defp dets_tables(_ctx) do
    state_dir =
      Path.join(System.tmp_dir!(), "vigil_oauth_contract_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)
    start_supervised!({Store, state_dir: state_dir})

    {:ok, persistence: Store.over_tables(), state_dir: state_dir}
  end

  defp memory(_ctx), do: {:ok, persistence: Persistence.Memory.new()}

  ## What both adapters are asked

  # A real authorization code, minted by the modules that own the records, so
  # what is written is the shape production writes — `grant_id`, audience and
  # all — rather than a variant this file made up.
  defp mint_code(persistence, now \\ @now), do: OAuthCase.mint_code(persistence, now)

  defp token_attrs(overrides) do
    Map.merge(
      %{
        grant_id: "grant-1",
        aud: @resource,
        scope: OAuth.scope(),
        expires_at: @now + 3600
      },
      Map.new(overrides)
    )
  end

  defp refresh_attrs(overrides) do
    token_attrs(overrides) |> Map.merge(%{type: :refresh, client_id: "client-1"})
  end

  # One body per claim, run against the `:dets` tables and against the
  # in-memory adapter. The two agreeing is what lets every other OAuth test in
  # the suite stay off `:dets`; the two drifting apart is the one thing that
  # could go wrong with a second adapter, so it is tested rather than assumed.
  for {adapter, setup_fun} <- [
        {"the :dets tables", :dets_tables},
        {"in memory", :memory}
      ] do
    describe "#{adapter}" do
      setup(setup_fun)

      test "a registered client is read back as it was written", %{persistence: persistence} do
        assert :ok = persistence.put_client.("client-1", %{name: "App", redirect_uris: []})

        assert {:ok, %{name: "App", redirect_uris: []}} = persistence.get_client.("client-1")
        assert :error = persistence.get_client.("never-registered")
      end

      test "an authorization code is single-use", %{persistence: persistence} do
        code = mint_code(persistence)

        assert {:ok, record} = persistence.take_code.(code)
        assert record.redirect_uri == OAuthCase.redirect_uri()
        assert :error = persistence.take_code.(code)
      end

      test "a token is written, read and deleted", %{persistence: persistence} do
        assert :ok = persistence.put_token.("token-1", token_attrs(%{}))
        assert {:ok, %{aud: aud}} = persistence.get_token.("token-1")
        assert aud == @resource

        assert :ok = persistence.delete_token.("token-1")
        assert :error = persistence.get_token.("token-1")
      end

      # The replay defence of RFC 9700 §4.14.2 rests on this: deleting a
      # rotated refresh token would make a replay indistinguishable from a
      # token that never existed, and the replay is the signal.
      test "a rotated refresh token is marked spent rather than deleted", %{
        persistence: persistence
      } do
        record = refresh_attrs(%{})
        :ok = persistence.put_token.("refresh-1", record)

        Token.spend_refresh(persistence, "refresh-1", record, @now)

        assert {:ok, spent} = persistence.get_token.("refresh-1")
        assert Token.classify(spent) == :spent_refresh
        assert spent.spent_at == @now
        # And the marker does not outlive what it is evidence about: the
        # record keeps its own expiry, so the sweep reclaims it on schedule.
        assert spent.expires_at == record.expires_at
      end

      test "revoking a grant takes down the family minted from it and nothing else", %{
        persistence: persistence
      } do
        :ok = persistence.put_token.("access-1", token_attrs(%{}))
        :ok = persistence.put_token.("refresh-1", refresh_attrs(%{}))
        :ok = persistence.put_token.("other-family", token_attrs(%{grant_id: "grant-2"}))
        :ok = persistence.put_token.("no-family", token_attrs(%{}) |> Map.delete(:grant_id))

        assert :ok = persistence.revoke_grant.("grant-1")

        assert persistence.get_token.("access-1") == :error
        assert persistence.get_token.("refresh-1") == :error
        assert {:ok, _} = persistence.get_token.("other-family")
        assert {:ok, _} = persistence.get_token.("no-family")
      end

      # "Every token whose grant is unknown" is not a family, so one replay
      # must not take down a stranger's token written before grants existed.
      test "a nil grant revokes nothing", %{persistence: persistence} do
        :ok = persistence.put_token.("no-family", token_attrs(%{}) |> Map.delete(:grant_id))

        assert :ok = persistence.revoke_grant.(nil)
        assert {:ok, _} = persistence.get_token.("no-family")
      end

      test "the consent lockout counts wrong passwords per address", %{persistence: persistence} do
        attempts = Persistence.rate_limit_max_attempts()

        for _ <- 1..(attempts - 1) do
          assert :ok = persistence.record_failure.("198.51.100.1", @now)
          refute persistence.rate_limited?.("198.51.100.1", @now)
        end

        assert :ok = persistence.record_failure.("198.51.100.1", @now)
        assert persistence.rate_limited?.("198.51.100.1", @now)

        # Per address: the neighbour has spent nothing.
        refute persistence.rate_limited?.("198.51.100.2", @now)
      end

      test "the consent lockout expires with its window", %{persistence: persistence} do
        window = Persistence.rate_limit_window()

        for _ <- 1..Persistence.rate_limit_max_attempts(),
            do: persistence.record_failure.("ip", @now)

        assert persistence.rate_limited?.("ip", @now + window)
        refute persistence.rate_limited?.("ip", @now + window + 1)
      end

      # A failure arriving after the window ran out opens a new one rather
      # than topping up the old count — otherwise an address locked out once
      # would stay locked out on one attempt an hour, and an address that had
      # ever been locked out could never be locked out again.
      #
      # Asserted by spending the *new* window rather than by reading the old
      # one: an elapsed window already answers "not limited", so `refute`
      # alone passes whether the count rolled over or not.
      test "a failure after the window opens a new one", %{persistence: persistence} do
        attempts = Persistence.rate_limit_max_attempts()
        later = @now + Persistence.rate_limit_window() + 1

        for _ <- 1..attempts, do: persistence.record_failure.("ip", @now)

        assert :ok = persistence.record_failure.("ip", later)
        refute persistence.rate_limited?.("ip", later)

        for _ <- 1..(attempts - 2), do: persistence.record_failure.("ip", later)
        refute persistence.rate_limited?.("ip", later)

        assert :ok = persistence.record_failure.("ip", later)
        assert persistence.rate_limited?.("ip", later)
      end

      test "the right password forgets an address's attempts", %{persistence: persistence} do
        for _ <- 1..Persistence.rate_limit_max_attempts(),
            do: persistence.record_failure.("ip", @now)

        assert persistence.rate_limited?.("ip", @now)

        assert :ok = persistence.reset_rate_limit.("ip")
        refute persistence.rate_limited?.("ip", @now)
      end

      test "the CIMD cache honours its TTL", %{persistence: persistence} do
        ttl = Persistence.cimd_ttl()
        doc = %{client_id: "https://client.example/m", name: "C", redirect_uris: []}

        assert :ok = persistence.cimd_cache_put.("https://client.example/m", doc, @now)

        assert {:ok, ^doc} = persistence.cimd_cache_get.("https://client.example/m", @now)

        assert {:ok, ^doc} =
                 persistence.cimd_cache_get.("https://client.example/m", @now + ttl - 1)

        assert :error = persistence.cimd_cache_get.("https://client.example/m", @now + ttl)
        assert :error = persistence.cimd_cache_get.("https://never.example/m", @now)
      end

      test "a sweep removes exactly what has expired and nothing else", %{
        persistence: persistence
      } do
        ttl = Persistence.cimd_ttl()

        # One entry that has expired at @now and one that has not, in each of
        # the four tables the contract owns. A code lives a minute, so one
        # minted an hour ago is gone and one minted now is not.
        expired_code = mint_code(persistence, @now - 3600)
        live_code = mint_code(persistence, @now)

        :ok = persistence.put_token.("token-expired", token_attrs(%{expires_at: @now}))
        :ok = persistence.put_token.("token-live", token_attrs(%{expires_at: @now + 1}))

        # A spent refresh token is a row like any other: reclaimed on its own
        # expiry, not on the instant it was spent.
        spent = refresh_attrs(%{expires_at: @now}) |> Map.put(:spent_at, @now - 60)
        spent_live = refresh_attrs(%{expires_at: @now + 1}) |> Map.put(:spent_at, @now - 60)
        :ok = persistence.put_token.("spent-expired", spent)
        :ok = persistence.put_token.("spent-live", spent_live)

        # The two ephemeral tables are here for the "and nothing else" half.
        # Reclaiming an elapsed window or a stale cache entry is not
        # observable through the contract — both already read as absent before
        # the sweep runs, and `record_failure` opens a new window over a stale
        # one by itself. Bounding their memory is the production adapter's,
        # asserted against its tables under "the :dets tables alone".
        for _ <- 1..(Persistence.rate_limit_max_attempts() - 1),
            do: persistence.record_failure.("ip-live", @now)

        doc = %{client_id: "c", name: "C", redirect_uris: []}
        :ok = persistence.cimd_cache_put.("https://fresh.example/m", doc, @now - ttl + 1)

        assert :ok = persistence.sweep_expired.(@now)

        assert persistence.take_code.(expired_code) == :error
        assert {:ok, _} = persistence.take_code.(live_code)

        assert persistence.get_token.("token-expired") == :error
        assert {:ok, _} = persistence.get_token.("token-live")
        assert persistence.get_token.("spent-expired") == :error
        assert {:ok, _} = persistence.get_token.("spent-live")

        # A live window keeps the attempts it had: one more failure locks the
        # address out, which it would not if the sweep had taken the row.
        assert :ok = persistence.record_failure.("ip-live", @now)
        assert persistence.rate_limited?.("ip-live", @now)

        assert {:ok, ^doc} = persistence.cimd_cache_get.("https://fresh.example/m", @now)
      end

      # The sweep is the janitor's whole question, and it answers it through
      # the value it was handed. Nothing else in the contract drops a live
      # record on the way past.
      test "a sweep with nothing expired leaves everything standing", %{
        persistence: persistence
      } do
        code = mint_code(persistence)
        :ok = persistence.put_token.("token-live", token_attrs(%{}))

        assert :ok = persistence.sweep_expired.(@now)

        assert {:ok, _} = persistence.take_code.(code)
        assert {:ok, _} = persistence.get_token.("token-live")
      end
    end
  end

  ## What only the :dets tables can be asked

  describe "the :dets tables alone" do
    setup :dets_tables

    # Why there is a `:dets` file at all: the clients, the codes and the
    # tokens outlive the process that opened them. The ephemeral halves — the
    # lockout windows and the CIMD cache — deliberately do not.
    test "a token survives a restart against the same state dir", %{
      persistence: persistence,
      state_dir: state_dir
    } do
      token = Token.issue_out_of_band(persistence, @resource, OAuth.scope(), 3600, @now)

      stop_supervised!(Store)
      start_supervised!({Store, state_dir: state_dir})

      assert {:ok, record} = Store.over_tables().get_token.(token)
      assert record.aud == @resource
    end

    # What the seam cannot see: an elapsed lockout window and a stale cache
    # entry already read as absent, so only the tables themselves show whether
    # the sweep reclaimed them. Unbounded growth is the whole point of
    # sweeping these two — the CIMD cache is keyed on a URL a client supplies.
    test "the sweep reclaims the ephemeral rows rather than only hiding them", %{
      persistence: persistence
    } do
      window = Persistence.rate_limit_window()
      ttl = Persistence.cimd_ttl()
      doc = %{client_id: "c", name: "C", redirect_uris: []}

      :ok = persistence.record_failure.("ip-stale", @now - window - 1)
      :ok = persistence.record_failure.("ip-live", @now)
      :ok = persistence.cimd_cache_put.("https://stale.example/m", doc, @now - ttl)
      :ok = persistence.cimd_cache_put.("https://fresh.example/m", doc, @now - ttl + 1)

      assert :ets.info(:oauth_rate_limits, :size) == 2
      assert :ets.info(:oauth_cimd_cache, :size) == 2

      assert :ok = persistence.sweep_expired.(@now)

      assert :ets.lookup(:oauth_rate_limits, "ip-stale") == []
      assert [{"ip-live", _count, _window}] = :ets.lookup(:oauth_rate_limits, "ip-live")
      assert :ets.lookup(:oauth_cimd_cache, "https://stale.example/m") == []

      assert [{"https://fresh.example/m", _doc, _expires}] =
               :ets.lookup(:oauth_cimd_cache, "https://fresh.example/m")
    end

    test "the files it opens are readable by their owner alone", %{state_dir: state_dir} do
      for file <- ["oauth_clients.dets", "oauth_codes.dets", "oauth_tokens.dets"] do
        assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(state_dir, file))
        assert Bitwise.band(mode, 0o077) == 0
      end
    end
  end

  describe "the :dets adapter" do
    test "answers every question, at the arity it is asked at" do
      adapter = Store.over_tables()

      for {question, arity} <- @questions do
        assert is_function(Map.fetch!(adapter, question), arity),
               "#{question} is not answered at arity #{arity}"
      end
    end
  end

  ## What only the in-memory adapter can be asked

  describe "the in-memory adapter alone" do
    # The same claim as the `:dets` half's, asked the way this adapter can be
    # asked it. Sweeping the two ephemeral tables is invisible through the
    # seam, so without a test on each side of it an adapter could skip the
    # sweep entirely and the contract suite would stay green.
    test "the sweep reclaims the ephemeral rows rather than only hiding them" do
      {persistence, tables} = Persistence.Memory.holding()
      window = Persistence.rate_limit_window()
      ttl = Persistence.cimd_ttl()
      doc = %{client_id: "c", name: "C", redirect_uris: []}

      :ok = persistence.record_failure.("ip-stale", @now - window - 1)
      :ok = persistence.record_failure.("ip-live", @now)
      :ok = persistence.cimd_cache_put.("https://stale.example/m", doc, @now - ttl)
      :ok = persistence.cimd_cache_put.("https://fresh.example/m", doc, @now - ttl + 1)

      assert Persistence.Memory.count(tables, :rate_limits) == 2
      assert Persistence.Memory.count(tables, :cimd_cache) == 2

      assert :ok = persistence.sweep_expired.(@now)

      assert Persistence.Memory.count(tables, :rate_limits) == 1
      assert Persistence.Memory.count(tables, :cimd_cache) == 1
      assert persistence.rate_limited?.("ip-live", @now) == false
      assert {:ok, ^doc} = persistence.cimd_cache_get.("https://fresh.example/m", @now)
    end

    test "answers every question, at the arity it is asked at" do
      adapter = Persistence.Memory.new()

      for {question, arity} <- @questions do
        assert is_function(Map.fetch!(adapter, question), arity),
               "#{question} is not answered at arity #{arity}"
      end
    end

    # There is no state dir to hand it and no process to find: `new/0` takes
    # nothing, and a full round trip works with `Vigil.OAuth.Store` not
    # running and its `:dets` tables not open. That is what lets a test build
    # one per test instead of one per file, and what lets those files run in
    # parallel.
    test "answers with no state dir and no store process" do
      refute Process.whereis(Store)

      persistence = Persistence.Memory.new()

      :ok = persistence.put_token.("token-1", token_attrs(%{}))
      assert {:ok, %{aud: _}} = persistence.get_token.("token-1")
      assert :ok = persistence.sweep_expired.(@now)
    end

    test "two adapters share nothing" do
      first = Persistence.Memory.new()
      second = Persistence.Memory.new()

      :ok = first.put_token.("token-1", token_attrs(%{}))

      assert {:ok, _} = first.get_token.("token-1")
      assert second.get_token.("token-1") == :error
    end
  end
end
