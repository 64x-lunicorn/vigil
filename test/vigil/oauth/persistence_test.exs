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
  counts per key, atomically, and expires with its window, that the CIMD cache honours
  its hour, and that a sweep drops exactly what has expired. Two adapters
  drifting apart is the one thing that can go wrong with a second one, which
  is why the contract is tested rather than assumed.
  """
  use ExUnit.Case, async: true

  alias Vigil.OAuth
  alias Vigil.OAuth.{Client, Flow, Persistence, Store, Token}
  alias Vigil.OAuthCase

  @now 1_700_000_000

  # A window for the consent attempts below. Its length is the caller's to
  # choose; this is the one `Vigil.OAuth.Flow` counts an address in.
  @window 900

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
    count_clients: 0,
    list_clients: 0,
    delete_client: 1,
    put_code: 2,
    take_code: 1,
    put_token: 2,
    get_token: 1,
    delete_token: 1,
    revoke_grant: 1,
    list_tokens: 0,
    revoke_all: 0,
    take_attempt: 3,
    return_attempt: 1,
    forget_attempts: 1,
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

      test "the clients are counted, and a rewrite is not a second client", %{
        persistence: persistence
      } do
        assert persistence.count_clients.() == 0

        :ok = persistence.put_client.("client-1", %{name: "App", redirect_uris: []})
        :ok = persistence.put_client.("client-2", %{name: "App", redirect_uris: []})
        :ok = persistence.put_client.("client-1", %{name: "Renamed", redirect_uris: []})

        assert persistence.count_clients.() == 2
      end

      # A registration is free to anyone the rate limit lets through, so one
      # that never went on to an authorization is the table's only unbounded
      # growth. The sweep drops those once their window is up — and nothing
      # else: not a client that was handed a code, not one still inside its
      # window, and not one written before the record said which it was.
      test "a sweep drops the clients that received no code in time, and only those", %{
        persistence: persistence
      } do
        window = Client.unused_ttl()
        uris = [OAuthCase.redirect_uri()]

        unused = Client.register(persistence, "Unused", uris, @now - window)
        fresh = Client.register(persistence, "Fresh", uris, @now - window + 1)
        used = Client.register(persistence, "Used", uris, @now - window)
        :ok = Client.authorized(persistence, used.client_id, @now - window + 60)

        :ok =
          persistence.put_client.("legacy", %{
            name: "Legacy",
            redirect_uris: uris,
            issued_at: @now - 10 * window
          })

        assert :ok = persistence.sweep_expired.(@now)

        assert :error = persistence.get_client.(unused.client_id)
        assert {:ok, _} = persistence.get_client.(fresh.client_id)
        assert {:ok, _} = persistence.get_client.(used.client_id)
        assert {:ok, _} = persistence.get_client.("legacy")
        assert persistence.count_clients.() == 3
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

      # What an operator lists grants from: the records, and never a value or
      # a digest a caller could present — the store keeps no value, and the
      # digest stays inside the adapter.
      test "every token record is listed, and only its record", %{persistence: persistence} do
        :ok = persistence.put_token.("access-1", token_attrs(%{}))
        :ok = persistence.put_token.("refresh-1", refresh_attrs(%{}))

        listed = persistence.list_tokens.()

        assert Enum.sort_by(listed, &Map.has_key?(&1, :type)) ==
                 [token_attrs(%{}), refresh_attrs(%{})]

        refute inspect(listed) =~ "access-1"
        refute inspect(listed) =~ "refresh-1"
        refute inspect(listed) =~ "sha256"
      end

      test "the clients are listed by their id", %{persistence: persistence} do
        :ok = persistence.put_client.("client-1", %{name: "One", redirect_uris: []})
        :ok = persistence.put_client.("client-2", %{name: "Two", redirect_uris: []})

        assert Enum.sort(persistence.list_clients.()) == [
                 {"client-1", %{name: "One", redirect_uris: []}},
                 {"client-2", %{name: "Two", redirect_uris: []}}
               ]
      end

      # A code outstanding for a deleted client would still redeem: redemption
      # checks the code, not the client.
      test "deleting a client takes its record and its codes, and nothing else", %{
        persistence: persistence
      } do
        # Each code is minted for a client of its own; reading one back and
        # writing it again is how the test learns whose it is.
        [{code, client_id}, {other, other_client}] =
          for _ <- 1..2 do
            code = mint_code(persistence)
            {:ok, attrs} = persistence.take_code.(code)
            :ok = persistence.put_code.(code, attrs)
            {code, attrs.client_id}
          end

        :ok = persistence.put_token.("refresh-1", refresh_attrs(%{client_id: client_id}))

        assert :ok = persistence.delete_client.(client_id)

        assert :error = persistence.get_client.(client_id)
        assert :error = persistence.take_code.(code)
        assert {:ok, _} = persistence.get_client.(other_client)
        assert {:ok, _} = persistence.take_code.(other)
        # Tokens are revoked by grant, above the seam, not here.
        assert {:ok, _} = persistence.get_token.("refresh-1")

        assert :ok = persistence.delete_client.("never-registered")
      end

      test "revoking everything takes every token and code, and leaves the clients", %{
        persistence: persistence
      } do
        code = mint_code(persistence)
        :ok = persistence.put_token.("access-1", token_attrs(%{}))
        :ok = persistence.put_token.("refresh-1", refresh_attrs(%{}))
        :ok = persistence.put_token.("other-family", token_attrs(%{grant_id: "grant-2"}))
        :ok = persistence.put_token.("no-family", token_attrs(%{}) |> Map.delete(:grant_id))

        assert :ok = persistence.revoke_all.()

        assert persistence.list_tokens.() == []
        assert :error = persistence.get_token.("no-family")
        assert :error = persistence.take_code.(code)
        assert persistence.count_clients.() == 1
      end

      # "Every token whose grant is unknown" is not a family, so one replay
      # must not take down a stranger's token written before grants existed.
      test "a nil grant revokes nothing", %{persistence: persistence} do
        :ok = persistence.put_token.("no-family", token_attrs(%{}) |> Map.delete(:grant_id))

        assert :ok = persistence.revoke_grant.(nil)
        assert {:ok, _} = persistence.get_token.("no-family")
      end

      test "consent attempts are counted per key", %{persistence: persistence} do
        for n <- 1..5, do: assert(persistence.take_attempt.("198.51.100.1", @window, @now) == n)

        # Per key: the neighbour has spent nothing.
        assert persistence.take_attempt.("198.51.100.2", @window, @now) == 1
      end

      # Every caller at once is answered a count of its own. A count read and
      # then written back hands two callers the same one, and a budget checked
      # against it lets both through on one free slot.
      test "parallel attempts are each answered a count of their own", %{
        persistence: persistence
      } do
        for n <- 1..20 do
          counts =
            Vigil.AtOnce.run(100, fn -> persistence.take_attempt.({:key, n}, @window, @now) end)

          assert Enum.sort(counts) == Enum.to_list(1..100)
        end
      end

      test "a window lasts the length it was opened with", %{persistence: persistence} do
        for _ <- 1..3, do: persistence.take_attempt.("ip", @window, @now)

        assert persistence.take_attempt.("ip", @window, @now + @window) == 4
        assert persistence.take_attempt.("ip", @window, @now + 2 * @window + 1) == 1

        # Two keys, two lengths: the hour-long one outlives the short one.
        assert persistence.take_attempt.("short", 10, @now) == 1
        assert persistence.take_attempt.("long", 3600, @now) == 1
        assert persistence.take_attempt.("short", 10, @now + 11) == 1
        assert persistence.take_attempt.("long", 3600, @now + 11) == 2
      end

      # An attempt after the window ran out opens a new one rather than
      # topping up the old count — otherwise an address locked out once would
      # stay locked out on one attempt an hour.
      test "an attempt after the window opens a new one", %{persistence: persistence} do
        later = @now + @window + 1

        for _ <- 1..5, do: persistence.take_attempt.("ip", @window, @now)

        assert persistence.take_attempt.("ip", @window, later) == 1
        assert persistence.take_attempt.("ip", @window, later + @window) == 2
      end

      test "an attempt given back is no longer counted, and never below zero", %{
        persistence: persistence
      } do
        for _ <- 1..3, do: persistence.take_attempt.("ip", @window, @now)

        assert :ok = persistence.return_attempt.("ip")
        assert persistence.take_attempt.("ip", @window, @now) == 3

        for _ <- 1..5, do: assert(:ok = persistence.return_attempt.("ip"))
        assert persistence.take_attempt.("ip", @window, @now) == 1

        assert :ok = persistence.return_attempt.("never-counted")
      end

      test "forgetting a key's attempts starts it over", %{persistence: persistence} do
        for _ <- 1..5, do: persistence.take_attempt.("ip", @window, @now)

        assert :ok = persistence.forget_attempts.("ip")
        assert persistence.take_attempt.("ip", @window, @now) == 1
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
        # the sweep runs, and `take_attempt` opens a new window over a stale
        # one by itself. Bounding their memory is the production adapter's,
        # asserted against its tables under "the :dets tables alone".
        for _ <- 1..4, do: persistence.take_attempt.("ip-live", @window, @now)

        doc = %{client_id: "c", name: "C", redirect_uris: []}
        :ok = persistence.cimd_cache_put.("https://fresh.example/m", doc, @now - ttl + 1)

        assert :ok = persistence.sweep_expired.(@now)

        assert persistence.take_code.(expired_code) == :error
        assert {:ok, _} = persistence.take_code.(live_code)

        assert persistence.get_token.("token-expired") == :error
        assert {:ok, _} = persistence.get_token.("token-live")
        assert persistence.get_token.("spent-expired") == :error
        assert {:ok, _} = persistence.get_token.("spent-live")

        # A live window keeps the attempts it had, which it would not if the
        # sweep had taken the row.
        assert persistence.take_attempt.("ip-live", @window, @now) == 5

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
      ttl = Persistence.cimd_ttl()
      doc = %{client_id: "c", name: "C", redirect_uris: []}

      1 = persistence.take_attempt.("ip-stale", @window, @now - @window - 1)
      1 = persistence.take_attempt.("ip-live", @window, @now)
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

    # A copy of the state dir — a backup, a container snapshot — must hold
    # nothing a caller could present. So the claim is made against what is
    # stored: every row of every table, and the bytes of every file.
    test "no code or token it was handed is kept as itself", %{
      persistence: persistence,
      state_dir: state_dir
    } do
      code = mint_code(persistence)
      {:ok, record} = persistence.take_code.(code)
      pair = Token.issue_pair(persistence, record, @now)
      pending = mint_code(persistence)
      seeded = Token.issue_out_of_band(persistence, @resource, OAuth.scope(), 3600, @now)

      values = [code, pending, pair.access_token, pair.refresh_token, seeded]

      stored =
        for table <- [:oauth_clients, :oauth_codes, :oauth_tokens],
            row <- :dets.foldl(fn row, acc -> [row | acc] end, [], table),
            do: :erlang.term_to_binary(row)

      files =
        for file <- ["oauth_clients.dets", "oauth_codes.dets", "oauth_tokens.dets"],
            do: File.read!(Path.join(state_dir, file))

      for value <- values, bytes <- stored ++ files do
        refute String.contains?(bytes, value)
      end

      # Kept under the digest instead, and found by the value all the same.
      assert [{{:sha256, _}, _}] = :dets.lookup(:oauth_codes, Token.digest(pending))
      assert {:ok, _} = persistence.get_token.(pair.access_token)
    end

    test "the files it opens are readable by their owner alone", %{state_dir: state_dir} do
      for file <- ["oauth_clients.dets", "oauth_codes.dets", "oauth_tokens.dets"] do
        assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(state_dir, file))
        assert Bitwise.band(mode, 0o077) == 0
      end
    end
  end

  describe "the :dets tables, when a write does not persist" do
    setup :dets_tables

    # A full disk and the `:dets` size limit both make `:dets.insert/2`
    # answer `{:error, reason}`. A table reopened read-only answers the same
    # way, which is how this makes one happen: the store is stopped, and the
    # named tables its adapter writes to are reopened under the same names
    # with nothing but read access.
    setup %{persistence: persistence, state_dir: state_dir} do
      :ok = persistence.put_token.("refresh-1", refresh_attrs(%{}))

      stop_supervised!(Store)

      for {table, file} <- [oauth_codes: "oauth_codes.dets", oauth_tokens: "oauth_tokens.dets"] do
        path = String.to_charlist(Path.join(state_dir, file))
        {:ok, ^table} = :dets.open_file(table, file: path, access: :read, type: :set)
        on_exit(fn -> :dets.close(table) end)
      end

      :ok
    end

    test "a write answers the error rather than :ok", %{persistence: persistence} do
      assert {:error, _} = persistence.put_token.("token-1", token_attrs(%{}))
      assert {:error, _} = persistence.put_code.("code-1", %{expires_at: @now + 60})
    end

    test "the token endpoint answers temporarily_unavailable, and the refresh token stays live",
         %{persistence: persistence} do
      assert Flow.grant(
               persistence,
               %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => "refresh-1",
                 "client_id" => "client-1"
               },
               @now
             ) == {:error, 503, "temporarily_unavailable"}

      # Not spent: the client's retry is a retry, not a replay that would
      # revoke its grant.
      assert {:ok, _} = Token.fetch_refresh(persistence, "refresh-1")
    end

    test "a minted token is refused rather than handed out", %{persistence: persistence} do
      assert_raise Persistence.Unavailable, fn ->
        Token.issue_out_of_band(persistence, @resource, OAuth.scope(), 3600, @now)
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
      ttl = Persistence.cimd_ttl()
      doc = %{client_id: "c", name: "C", redirect_uris: []}

      1 = persistence.take_attempt.("ip-stale", @window, @now - @window - 1)
      1 = persistence.take_attempt.("ip-live", @window, @now)
      :ok = persistence.cimd_cache_put.("https://stale.example/m", doc, @now - ttl)
      :ok = persistence.cimd_cache_put.("https://fresh.example/m", doc, @now - ttl + 1)

      assert Persistence.Memory.count(tables, :rate_limits) == 2
      assert Persistence.Memory.count(tables, :cimd_cache) == 2

      assert :ok = persistence.sweep_expired.(@now)

      assert Persistence.Memory.count(tables, :rate_limits) == 1
      assert Persistence.Memory.count(tables, :cimd_cache) == 1
      assert persistence.take_attempt.("ip-live", @window, @now) == 2
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
