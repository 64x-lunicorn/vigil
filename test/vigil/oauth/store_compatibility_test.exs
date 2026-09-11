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

  The test does not carry the token strings: it discovers them from the tables,
  which keeps a ten-year bearer token out of the repository. That it has to
  reach into `:dets` to do so is the same reach the rest of the suite makes at
  the tables, and deliberate — the persistence contract has no "list", because
  nothing in `lib/` needs one.
  """
  # The Store is a named singleton, and this one is opened against its own
  # state dir rather than OAuthCase's.
  use ExUnit.Case, async: false

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

    previous = Application.get_env(:vigil, :resource)
    Application.put_env(:vigil, :resource, @resource)

    on_exit(fn ->
      Application.put_env(:vigil, :resource, previous)
      File.rm_rf(state_dir)
    end)

    start_supervised!({Store, state_dir: state_dir})

    %{persistence: Store.over_tables()}
  end

  # Every token in the fixture, as {token, attrs}.
  defp tokens do
    :dets.foldl(fn record, acc -> [record | acc] end, [], :oauth_tokens)
  end

  # The long-lived token `verify()` and first access are handed: no :type, and
  # still alive at @now. Named precisely because the fixture also holds the
  # hour-long access token of the redeemed pair, which has the same scope and
  # has expired by then.
  defp out_of_band_token(scope) do
    {token, _attrs} =
      Enum.find(tokens(), fn {_token, attrs} ->
        attrs.scope == scope and not Map.has_key?(attrs, :type) and attrs.expires_at > @now
      end)

    token
  end

  # The refresh record, found by the field that makes it one.
  defp refresh_record do
    Enum.find(tokens(), fn {_token, attrs} -> Map.get(attrs, :type) == :refresh end)
  end

  test "the fixture opens at all — three tables, written by the old code" do
    # Two out-of-band tokens, plus the access/refresh pair a redemption made.
    assert length(tokens()) == 4
    assert :dets.info(:oauth_clients, :size) == 1
    # One authorization code, minted and left unredeemed.
    assert :dets.info(:oauth_codes, :size) == 1
  end

  test "an access token minted by the previous version still authenticates", %{
    persistence: persistence
  } do
    token = out_of_band_token("vault")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault"}
  end

  test "a read-only token keeps the scope it was issued with", %{persistence: persistence} do
    token = out_of_band_token("vault:read")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault:read"}
  end

  test "a token is still refused for a resource it was not issued for", %{
    persistence: persistence
  } do
    token = out_of_band_token("vault")

    assert Token.validate_access(persistence, token, "https://elsewhere.example/mcp", @now) ==
             :error
  end

  test "the old token record still carries every field the reader asks of it", %{
    persistence: persistence
  } do
    {:ok, record} = persistence.get_token.(out_of_band_token("vault"))

    assert record.aud == @resource
    assert record.scope == "vault"
    assert record.expires_at > @now
    # Present and set: a nil grant revokes nothing, so a record that lost it
    # would silently opt out of the RFC 9700 replay defence.
    assert is_binary(record.grant_id)
  end

  test "a client registered by the previous version still resolves", %{persistence: persistence} do
    [{client_id, _attrs}] =
      :dets.foldl(fn record, acc -> [record | acc] end, [], :oauth_clients)

    {:ok, attrs} = persistence.get_client.(client_id)

    assert attrs.name == "Frozen fixture client"
    assert attrs.redirect_uris == ["https://claude.ai/api/mcp/auth_callback"]
  end

  describe "the refresh token, which is what strands a client when it breaks" do
    # An access token lives an hour. Every client connected before a deploy is
    # therefore rotating within the hour after it, against a refresh record the
    # old code wrote — and out-of-band tokens, which carry none of these
    # fields, cannot stand in for that.
    test "is still recognised as a refresh token", %{persistence: persistence} do
      {token, _} = refresh_record()

      assert {:ok, data} = Token.fetch_refresh(persistence, token)
      assert data.scope == "vault"
      assert data.aud == @resource
      assert is_binary(data.client_id)
      assert is_binary(data.grant_id)
    end

    test "is refused when presented as an access token", %{persistence: persistence} do
      {token, _} = refresh_record()

      assert Token.validate_access(persistence, token, @resource, @now) == :error
    end

    test "still rotates, and the pair it produces stays in its grant", %{
      persistence: persistence
    } do
      {token, attrs} = refresh_record()
      {:ok, data} = Token.fetch_refresh(persistence, token)

      pair = Token.issue_pair(persistence, data, @now)

      assert {:ok, "vault"} =
               Token.validate_access(persistence, pair.access_token, @resource, @now)

      {:ok, rotated} = persistence.get_token.(pair.refresh_token)
      assert rotated.grant_id == attrs.grant_id
    end

    test "is marked spent rather than deleted, so a replay is still visible", %{
      persistence: persistence
    } do
      {token, _} = refresh_record()
      {:ok, data} = Token.fetch_refresh(persistence, token)

      :ok = Token.spend_refresh(persistence, token, data, @now)

      assert {:ok, spent} = persistence.get_token.(token)
      assert spent.spent_at == @now

      # Not :error — a spent refresh answers with the record, which is how a
      # replay is told apart from a token that never existed.
      assert {:spent, _record} = Token.fetch_refresh(persistence, token)
    end
  end

  test "an authorization code written by the previous version still reads back" do
    [{_code, attrs}] = :dets.foldl(fn record, acc -> [record | acc] end, [], :oauth_codes)

    assert attrs.resource == @resource
    assert attrs.scope == "vault"
    assert attrs.redirect_uri == "https://claude.ai/api/mcp/auth_callback"
    assert is_binary(attrs.code_challenge)
    assert is_binary(attrs.grant_id)
    assert attrs.expires_at > @issued_at
  end
end
