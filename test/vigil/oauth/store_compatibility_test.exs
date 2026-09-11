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

  alias Vigil.OAuth.{Persistence, Store, Token}

  @fixture Path.expand("../../fixtures/oauth_store_pre_seam", __DIR__)
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

  defp token_with_scope(scope) do
    {token, _attrs} =
      Enum.find(tokens(), fn {_token, attrs} -> Map.get(attrs, :scope) == scope end)

    token
  end

  test "the fixture opens at all — three tables, written by the old code" do
    assert length(tokens()) == 2
    assert :dets.info(:oauth_clients, :size) == 1
    assert :dets.info(:oauth_codes, :size) == 0
  end

  test "an access token minted by the previous version still authenticates", %{
    persistence: persistence
  } do
    token = token_with_scope("vault")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault"}
  end

  test "a read-only token keeps the scope it was issued with", %{persistence: persistence} do
    token = token_with_scope("vault:read")

    assert Token.validate_access(persistence, token, @resource, @now) == {:ok, "vault:read"}
  end

  test "a token is still refused for a resource it was not issued for", %{
    persistence: persistence
  } do
    token = token_with_scope("vault")

    assert Token.validate_access(persistence, token, "https://elsewhere.example/mcp", @now) ==
             :error
  end

  test "the old token record still carries every field the reader asks of it", %{
    persistence: persistence
  } do
    {:ok, record} = persistence.get_token.(token_with_scope("vault"))

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

  test "the adapter this reads through is the production one" do
    assert %Persistence{} = Store.over_tables()
  end
end
