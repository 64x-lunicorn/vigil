defmodule Vigil.OAuth.StoreCompatibilityTest do
  @moduledoc """
  Records written by the previous version, read by this one.

  The authorization server's state survives a deploy: `update.sh` switches the
  release and leaves the state dir alone (`scripts/test/update_test.sh`). So
  the first thing the new code does is open `.dets` files the *old* code wrote,
  and every client that was connected before the deploy authenticates with a
  token that was minted before it. There is no migration step and no version
  marker in those files — the only thing standing between a changed record
  shape and "Claude cannot connect any more" is that somebody thought about it.

  `test/fixtures/oauth_store_pre_seam/` is a store written at ccc42a6, the
  commit before the OAuth persistence seam was drawn (#135) — the change most
  able to have broken this. `generate.exs` beside it says how to regenerate the
  fixture, or freeze a newer "previous version" when the deployed one moves on.

  The test does not carry the token strings: it discovers them from the
  fixture's files, which keeps a ten-year bearer token out of the repository.
  That it has to reach into `:dets` to do so is the same reach the rest of the
  suite makes at the tables, and deliberate — the persistence contract has no
  "list", because nothing in `lib/` needs one.

  **Keys became digests (#193), and the fixture is migrated, not
  invalidated.** The fixture keys every code and token by its raw value; this
  version keeps them under `Vigil.OAuth.Token.digest/1`. `Vigil.OAuth.Store`
  rekeys every binary key to its digest when it opens the tables, and
  compacts the file so the old values are gone from the bytes too. Nothing is
  asked of the operator and no client has to authorize again: the raw values
  are read out of the fixture *before* the store opens it, and every claim
  below is that a value minted by the old code still works after the store
  has rekeyed it. Invalidating was the alternative, and would have cost every
  connected client a consent round for what is a four-line fold.
  """
  # The Store is a named singleton, and this one is opened against its own
  # state dir rather than OAuthCase's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vigil.OAuth.{Store, Token}

  @fixture Path.expand("../../fixtures/oauth_store_pre_seam", __DIR__)

  # The audience the fixture's tokens were minted with, fixed the way the
  # instant below is: what the `.dets` files on disk already say, not what
  # this deployment configures. Reading the deployment's here would check a
  # recording against something that was never used to make it.
  @resource "https://vault.factory-lab.org/mcp"

  # The instant the fixture was minted at, plus a day: inside the ten-year
  # lifetime those tokens were issued with, and fixed so the test does not
  # start failing on a date.
  @issued_at 1_767_225_600
  @now @issued_at + 86_400

  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "vigil_oauth_compat_#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)

    for file <- Path.wildcard(Path.join(@fixture, "*.dets")) do
      File.cp!(file, Path.join(state_dir, Path.basename(file)))
    end

    # What the old code wrote, raw values and all — read before the store
    # opens the files, because opening them is what rekeys them.
    legacy = %{
      tokens: legacy_rows(state_dir, "oauth_tokens.dets"),
      codes: legacy_rows(state_dir, "oauth_codes.dets")
    }

    previous = Application.get_env(:vigil, :resource)
    Application.put_env(:vigil, :resource, @resource)

    on_exit(fn ->
      Application.put_env(:vigil, :resource, previous)
      File.rm_rf(state_dir)
    end)

    {_pid, log} = boot(state_dir)

    %{persistence: Store.over_tables(), legacy: legacy, state_dir: state_dir, boot_log: log}
  end

  # Starts the store and answers what it logged.
  defp boot(state_dir),
    do: with_log(fn -> start_supervised!({Store, state_dir: state_dir}) end)

  # A fixture file's rows as the previous version wrote them, opened read-only
  # under a name of its own so the store's named tables are not touched.
  defp legacy_rows(state_dir, filename) do
    path = String.to_charlist(Path.join(state_dir, filename))
    {:ok, table} = :dets.open_file(make_ref(), file: path, access: :read, type: :set)
    rows = :dets.foldl(fn row, acc -> [row | acc] end, [], table)
    :ok = :dets.close(table)
    rows
  end

  defp rows(table), do: :dets.foldl(fn row, acc -> [row | acc] end, [], table)

  # The long-lived token `verify()` and first access are handed: no :type, and
  # still alive at @now. Named precisely because the fixture also holds the
  # hour-long access token of the redeemed pair, which has the same scope and
  # has expired by then.
  defp out_of_band_token(%{tokens: tokens}, scope) do
    {token, _attrs} =
      Enum.find(tokens, fn {_token, attrs} ->
        attrs.scope == scope and not Map.has_key?(attrs, :type) and attrs.expires_at > @now
      end)

    token
  end

  # The refresh record, found by the field that makes it one.
  defp refresh_record(%{tokens: tokens}) do
    Enum.find(tokens, fn {_token, attrs} -> Map.get(attrs, :type) == :refresh end)
  end

  test "the fixture opens at all — three tables, written by the old code", %{legacy: legacy} do
    # Two out-of-band tokens, plus the access/refresh pair a redemption made.
    assert length(legacy.tokens) == 4
    assert :dets.info(:oauth_tokens, :size) == 4
    assert :dets.info(:oauth_clients, :size) == 1
    # One authorization code, minted and left unredeemed.
    assert length(legacy.codes) == 1
    assert :dets.info(:oauth_codes, :size) == 1
  end

  describe "the first boot rekeys the old state" do
    test "every code and token is kept under its digest, attrs untouched", %{legacy: legacy} do
      for {table, rows} <- [oauth_tokens: legacy.tokens, oauth_codes: legacy.codes] do
        expected = Map.new(rows, fn {value, attrs} -> {Token.digest(value), attrs} end)

        assert Map.new(rows(table)) == expected
      end
    end

    # Deleting a `:dets` row leaves its bytes in the file, so the claim is
    # made against the files themselves rather than against the tables.
    test "no value the old code wrote is left in the files", %{
      legacy: legacy,
      state_dir: state_dir
    } do
      for {filename, rows} <- [
            {"oauth_tokens.dets", legacy.tokens},
            {"oauth_codes.dets", legacy.codes}
          ] do
        bytes = File.read!(Path.join(state_dir, filename))

        for {value, _attrs} <- rows do
          refute String.contains?(bytes, value), "a raw value is still in #{filename}"
        end
      end
    end

    # What the operator sees in the journal: how many rows moved, and never
    # a value — those were bearer credentials.
    test "the boot says what it rekeyed, by count", %{legacy: legacy, boot_log: log} do
      assert log =~ "rekeyed 4 oauth_tokens rows to their digests"
      assert log =~ "rekeyed 1 oauth_codes rows to their digests"

      for {value, _attrs} <- legacy.tokens ++ legacy.codes do
        refute log =~ value
      end
    end

    test "a second boot finds nothing left to rekey", %{legacy: legacy, state_dir: state_dir} do
      before = %{tokens: rows(:oauth_tokens), codes: rows(:oauth_codes)}

      stop_supervised!(Store)
      {_pid, log} = boot(state_dir)
      refute log =~ "rekeyed"

      assert %{tokens: rows(:oauth_tokens), codes: rows(:oauth_codes)} == before

      assert Token.validate_access(
               Store.over_tables(),
               out_of_band_token(legacy, "vault"),
               @resource,
               @now
             ) == {:ok, "vault"}
    end
  end

  test "an access token minted by the previous version still authenticates", %{
    persistence: persistence,
    legacy: legacy
  } do
    token = out_of_band_token(legacy, "vault")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault"}
  end

  test "a read-only token keeps the scope it was issued with", %{
    persistence: persistence,
    legacy: legacy
  } do
    token = out_of_band_token(legacy, "vault:read")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault:read"}
  end

  test "a token is still refused for a resource it was not issued for", %{
    persistence: persistence,
    legacy: legacy
  } do
    token = out_of_band_token(legacy, "vault")

    assert Token.validate_access(persistence, token, "https://elsewhere.example/mcp", @now) ==
             :error
  end

  test "the old token record still carries every field the reader asks of it", %{
    persistence: persistence,
    legacy: legacy
  } do
    {:ok, record} = persistence.get_token.(out_of_band_token(legacy, "vault"))

    assert record.aud == @resource
    assert record.scope == "vault"
    assert record.expires_at > @now
    # Present and set: a nil grant revokes nothing, so a record that lost it
    # would silently opt out of the RFC 9700 replay defence.
    assert is_binary(record.grant_id)
  end

  test "a client registered by the previous version still resolves", %{persistence: persistence} do
    [{client_id, _attrs}] = rows(:oauth_clients)

    {:ok, attrs} = persistence.get_client.(client_id)

    assert attrs.name == "Frozen fixture client"
    assert attrs.redirect_uris == ["https://claude.ai/api/mcp/auth_callback"]
  end

  describe "the refresh token, which is what strands a client when it breaks" do
    # An access token lives an hour. Every client connected before a deploy is
    # therefore rotating within the hour after it, against a refresh record the
    # old code wrote — and out-of-band tokens, which carry none of these
    # fields, cannot stand in for that.
    test "is still recognised as a refresh token", %{
      persistence: persistence,
      legacy: legacy
    } do
      {token, _} = refresh_record(legacy)

      assert {:ok, data} = Token.fetch_refresh(persistence, token)
      assert data.scope == "vault"
      assert data.aud == @resource
      assert is_binary(data.client_id)
      assert is_binary(data.grant_id)
    end

    test "is refused when presented as an access token", %{
      persistence: persistence,
      legacy: legacy
    } do
      {token, _} = refresh_record(legacy)

      assert Token.validate_access(persistence, token, @resource, @now) == :error
    end

    test "still rotates, and the pair it produces stays in its grant", %{
      persistence: persistence,
      legacy: legacy
    } do
      {token, attrs} = refresh_record(legacy)
      {:ok, data} = Token.fetch_refresh(persistence, token)

      pair = Token.issue_pair(persistence, data, @now)

      assert {:ok, "vault"} =
               Token.validate_access(persistence, pair.access_token, @resource, @now)

      {:ok, rotated} = persistence.get_token.(pair.refresh_token)
      assert rotated.grant_id == attrs.grant_id
    end

    test "is marked spent rather than deleted, so a replay is still visible", %{
      persistence: persistence,
      legacy: legacy
    } do
      {token, _} = refresh_record(legacy)
      {:ok, data} = Token.fetch_refresh(persistence, token)

      :ok = Token.spend_refresh(persistence, token, data, @now)

      assert {:ok, spent} = persistence.get_token.(token)
      assert spent.spent_at == @now

      # Not :error — a spent refresh answers with the record, which is how a
      # replay is told apart from a token that never existed.
      assert {:spent, _record} = Token.fetch_refresh(persistence, token)
    end
  end

  test "an authorization code written by the previous version still reads back", %{
    persistence: persistence,
    legacy: legacy
  } do
    [{code, _}] = legacy.codes
    {:ok, attrs} = persistence.take_code.(code)

    assert attrs.resource == @resource
    assert attrs.scope == "vault"
    assert attrs.redirect_uri == "https://claude.ai/api/mcp/auth_callback"
    assert is_binary(attrs.code_challenge)
    assert is_binary(attrs.grant_id)
    assert attrs.expires_at > @issued_at
  end
end
