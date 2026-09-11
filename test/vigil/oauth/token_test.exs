defmodule Vigil.OAuth.TokenTest do
  @moduledoc """
  The token record on its own: minted, classified, and asked whether it is a
  valid access token — with no `Plug.Conn` anywhere. Before the record had an
  owner, "is this a valid access token for this resource, and at what scope"
  was a `cond` inside a private function of the MCP router, and the only way
  to ask it was to build a conn with a Bearer header.
  """
  use ExUnit.Case, async: false

  alias Vigil.OAuth
  alias Vigil.OAuth.{Store, Token}

  @ttl_day 86_400

  setup do
    Vigil.OAuthCase.setup!()
  end

  defp resource, do: OAuth.resource()

  # An authorization code being redeemed: a client, a scope, a grant — and the
  # audience it was minted for, under the name Vigil.OAuth.Code writes it
  # under. The pair is issued from the record alone, so this is where its
  # audience comes from too.
  defp redeemed(overrides \\ []) do
    %{
      client_id: "client-1",
      resource: Keyword.get(overrides, :resource, OAuth.resource()),
      scope: Keyword.get(overrides, :scope, OAuth.scope()),
      grant_id: Keyword.get(overrides, :grant, Vigil.Uuid.v4())
    }
  end

  # A refresh token being rotated: the same four facts, under this module's
  # own names.
  defp rotated(overrides \\ []) do
    %{
      type: :refresh,
      client_id: "client-1",
      aud: Keyword.get(overrides, :aud, OAuth.resource()),
      scope: Keyword.get(overrides, :scope, OAuth.scope()),
      grant_id: Keyword.get(overrides, :grant, Vigil.Uuid.v4()),
      expires_at: Keyword.get(overrides, :expires_at, System.system_time(:second) + 100)
    }
  end

  test "random/0 returns 64 lowercase hex chars and is not constant" do
    a = Token.random()
    b = Token.random()
    assert String.length(a) == 64
    assert a =~ ~r/^[0-9a-f]{64}$/
    assert a != b
  end

  test "pkce_valid?/2 verifies the S256 challenge" do
    verifier = "some-random-verifier-string-1234567890"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert Token.pkce_valid?(verifier, challenge)
    refute Token.pkce_valid?("wrong-verifier", challenge)
    refute Token.pkce_valid?(verifier, "wrong-challenge")
  end

  describe "classify/1" do
    test "an access token is one by the absence of a type" do
      assert Token.classify(%{aud: "x", expires_at: 1}) == :access
    end

    test "a refresh token says so" do
      assert Token.classify(%{type: :refresh, aud: "x", expires_at: 1}) == :refresh
    end

    test "a spent refresh token is its own kind" do
      assert Token.classify(%{type: :refresh, spent_at: 7, aud: "x", expires_at: 1}) ==
               :spent_refresh
    end

    test "spent is read only on a refresh token" do
      # Only refresh tokens are ever spent — rotation is the only thing that
      # spends one. An access token carrying the marker is not a shape this
      # server writes, and it must not be classified as a replayable refresh.
      assert Token.classify(%{spent_at: 7, aud: "x", expires_at: 1}) == :access
    end
  end

  describe "issue_pair/3" do
    setup %{persistence: persistence} do
      now = System.system_time(:second)
      grant = Vigil.Uuid.v4()
      pair = Token.issue_pair(persistence, redeemed(grant: grant), now)
      %{now: now, grant: grant, pair: pair}
    end

    test "answers the token response the endpoint returns", %{pair: pair} do
      assert pair.token_type == "Bearer"
      assert pair.expires_in == 3600
      assert pair.scope == OAuth.scope()
      assert is_binary(pair.access_token) and is_binary(pair.refresh_token)
      assert pair.access_token != pair.refresh_token
    end

    test "both records descend from the grant they were given", %{pair: pair, grant: grant} do
      {:ok, access} = Store.get_token(pair.access_token)
      {:ok, refresh} = Store.get_token(pair.refresh_token)

      assert access.grant_id == grant
      assert refresh.grant_id == grant
    end

    test "the access record is an access token and the refresh record is not", %{pair: pair} do
      {:ok, access} = Store.get_token(pair.access_token)
      {:ok, refresh} = Store.get_token(pair.refresh_token)

      assert Token.classify(access) == :access
      assert Token.classify(refresh) == :refresh
      assert refresh.client_id == "client-1"
    end

    test "the two expire on different schedules", %{pair: pair, now: now} do
      {:ok, access} = Store.get_token(pair.access_token)
      {:ok, refresh} = Store.get_token(pair.refresh_token)

      assert access.expires_at == now + 3600
      assert refresh.expires_at == now + 30 * @ttl_day
    end

    test "the pair inherits the scope and the grant of what it descends from", %{
      persistence: persistence,
      now: now
    } do
      # Both are read off the record here rather than at the two call sites,
      # so a redemption cannot inherit them one way and a rotation another.
      pair =
        Token.issue_pair(
          persistence,
          redeemed(grant: "g-inherited", scope: OAuth.read_scope()),
          now
        )

      {:ok, access} = Store.get_token(pair.access_token)

      assert pair.scope == OAuth.read_scope()
      assert access.grant_id == "g-inherited"
    end

    test "the pair inherits the audience of what it descends from", %{
      persistence: persistence,
      now: now
    } do
      # The audience used to be a parameter, because a code stores it as
      # `:resource` and a refresh token as `:aud`. Both records answer for
      # themselves now, and the same pair comes out either way.
      for record <- [redeemed(), rotated()] do
        pair = Token.issue_pair(persistence, record, now)

        assert Token.validate_access(persistence, pair.access_token, OAuth.resource(), now) ==
                 {:ok, OAuth.scope()}
      end
    end

    test "a code minted for another resource issues a pair good only there", %{
      persistence: persistence,
      now: now
    } do
      pair = Token.issue_pair(persistence, redeemed(resource: "https://andere.tld/mcp"), now)

      assert Token.validate_access(persistence, pair.access_token, OAuth.resource(), now) ==
               :error

      assert Token.validate_access(persistence, pair.access_token, "https://andere.tld/mcp", now) ==
               {:ok, OAuth.scope()}
    end

    test "a record from before grants existed still mints into a family", %{
      persistence: persistence,
      now: now
    } do
      pair = Token.issue_pair(persistence, rotated(grant: nil) |> Map.delete(:grant_id), now)

      {:ok, access} = Store.get_token(pair.access_token)
      {:ok, refresh} = Store.get_token(pair.refresh_token)

      assert is_binary(access.grant_id)
      assert access.grant_id == refresh.grant_id
    end
  end

  describe "validate_access/4" do
    setup %{persistence: persistence} do
      now = System.system_time(:second)
      pair = Token.issue_pair(persistence, redeemed(), now)
      %{now: now, pair: pair}
    end

    test "a freshly minted access token is valid at its scope", %{
      persistence: persistence,
      pair: pair,
      now: now
    } do
      assert Token.validate_access(persistence, pair.access_token, resource(), now) ==
               {:ok, OAuth.scope()}
    end

    test "a read-only token validates at the read scope", %{persistence: persistence, now: now} do
      pair = Token.issue_pair(persistence, redeemed(scope: OAuth.read_scope()), now)

      assert Token.validate_access(persistence, pair.access_token, resource(), now) ==
               {:ok, OAuth.read_scope()}
    end

    test "a token minted for another resource is refused", %{
      persistence: persistence,
      pair: pair,
      now: now
    } do
      assert Token.validate_access(persistence, pair.access_token, "https://andere.tld/mcp", now) ==
               :error
    end

    test "an expired token is refused and reclaimed", %{persistence: persistence, now: now} do
      token = Token.issue_out_of_band(persistence, resource(), OAuth.scope(), 0, now)

      assert Token.validate_access(persistence, token, resource(), now + 1) == :error
      assert Store.get_token(token) == :error
    end

    test "a refresh token presented as an access token is refused", %{
      persistence: persistence,
      pair: pair,
      now: now
    } do
      assert Token.validate_access(persistence, pair.refresh_token, resource(), now) == :error
    end

    test "refusing a refresh token does not spend or delete it", %{
      persistence: persistence,
      pair: pair,
      now: now
    } do
      # It is a valid refresh token that was handed to the wrong endpoint.
      # Deleting it here would let anyone holding it destroy their own — or,
      # after a leak, somebody else's — ability to renew.
      Token.validate_access(persistence, pair.refresh_token, resource(), now)

      assert {:ok, record} = Store.get_token(pair.refresh_token)
      assert Token.classify(record) == :refresh
    end

    test "an unknown token is refused", %{persistence: persistence, now: now} do
      assert Token.validate_access(persistence, Token.random(), resource(), now) == :error
    end

    test "a record written before scopes existed grants the full scope", %{
      persistence: persistence,
      now: now
    } do
      legacy = Token.random()
      Store.put_token(legacy, %{aud: resource(), expires_at: now + 3600})

      assert Token.validate_access(persistence, legacy, resource(), now) == {:ok, OAuth.scope()}
    end
  end

  describe "fetch_refresh/2" do
    setup %{persistence: persistence} do
      now = System.system_time(:second)
      pair = Token.issue_pair(persistence, redeemed(), now)
      %{now: now, pair: pair}
    end

    test "a live refresh token comes back with its record", %{
      persistence: persistence,
      pair: pair
    } do
      assert {:ok, record} = Token.fetch_refresh(persistence, pair.refresh_token)
      assert record.client_id == "client-1"
    end

    test "a spent refresh token is a replay, not a live one", %{
      persistence: persistence,
      pair: pair,
      now: now
    } do
      {:ok, record} = Store.get_token(pair.refresh_token)
      Token.spend_refresh(persistence, pair.refresh_token, record, now)

      assert {:spent, spent} = Token.fetch_refresh(persistence, pair.refresh_token)
      assert spent.spent_at == now
    end

    test "an access token is not a refresh token", %{persistence: persistence, pair: pair} do
      assert Token.fetch_refresh(persistence, pair.access_token) == :error
    end

    test "an unknown token is not a refresh token", %{persistence: persistence} do
      assert Token.fetch_refresh(persistence, Token.random()) == :error
    end
  end

  describe "spend_refresh/4" do
    test "only a refresh record can be spent", %{persistence: persistence} do
      # `classify/1` reads `:spent_at` as "replayed" only because rotation is
      # the one thing that writes the marker and this is the only place it
      # can. A real access record has no way through here.
      now = System.system_time(:second)
      pair = Token.issue_pair(persistence, redeemed(), now)
      {:ok, access} = Store.get_token(pair.access_token)

      assert_raise FunctionClauseError, fn ->
        Token.spend_refresh(persistence, pair.access_token, access, now)
      end
    end

    test "the marker keeps the record's own expiry, so the janitor still reclaims it", %{
      persistence: persistence
    } do
      now = System.system_time(:second)
      pair = Token.issue_pair(persistence, redeemed(), now)
      {:ok, record} = Store.get_token(pair.refresh_token)

      Token.spend_refresh(persistence, pair.refresh_token, record, now)

      {:ok, spent} = Store.get_token(pair.refresh_token)
      assert spent.expires_at == record.expires_at
    end
  end

  describe "the defaults for records written before the field existed" do
    test "a token record without a scope grants the full scope" do
      assert Token.scope_of(%{aud: "x"}) == OAuth.scope()
      assert Token.scope_of(%{aud: "x", scope: OAuth.read_scope()}) == OAuth.read_scope()
    end

    # The default is a rule about token records, and it stops there. A code
    # lives sixty seconds, so no code from before scopes existed can be in a
    # store — and a code without one is a record this server did not write.
    test "the default does not reach an authorization code", %{persistence: persistence} do
      now = System.system_time(:second)

      assert_raise KeyError, fn ->
        Token.issue_pair(persistence, redeemed() |> Map.delete(:scope), now)
      end
    end

    test "a record without a grant belongs to no family" do
      # Read for revocation: "every token whose grant is unknown" is not a
      # family, so there is nothing to take down.
      assert Token.grant_of(%{aud: "x"}) == nil
      assert Token.grant_of(%{aud: "x", grant_id: "g-1"}) == "g-1"
    end

    test "issuing from a record without a grant mints a fresh one" do
      # Read for issuing: the pair minted from it must belong to *some*
      # family, or the invariant would hold only for tokens minted after
      # grants existed.
      assert Token.grant_for_issue(%{aud: "x", grant_id: "g-1"}) == "g-1"

      fresh = Token.grant_for_issue(%{aud: "x"})
      assert is_binary(fresh)
      assert fresh != Token.grant_for_issue(%{aud: "x"})
    end
  end

  describe "issue_out_of_band/4" do
    test "mints an access token that validates at the resource", %{persistence: persistence} do
      now = System.system_time(:second)

      token =
        Token.issue_out_of_band(persistence, resource(), OAuth.read_scope(), 3650 * @ttl_day, now)

      assert Token.validate_access(persistence, token, resource(), now) ==
               {:ok, OAuth.read_scope()}
    end

    test "the seeded token is a family of one rather than a token with no family", %{
      persistence: persistence
    } do
      now = System.system_time(:second)

      token =
        Token.issue_out_of_band(persistence, resource(), OAuth.scope(), 3650 * @ttl_day, now)

      {:ok, record} = Store.get_token(token)
      assert is_binary(Token.grant_of(record))

      Store.revoke_grant(Token.grant_of(record))
      assert Store.get_token(token) == :error
    end

    test "it carries no refresh token", %{persistence: persistence} do
      now = System.system_time(:second)
      token = Token.issue_out_of_band(persistence, resource(), OAuth.scope(), @ttl_day, now)

      assert Token.fetch_refresh(persistence, token) == :error
      assert length(Store.all_tokens()) == 1
    end
  end

  describe "expired?/2" do
    test "expiry is inclusive of the instant itself" do
      refute Token.expired?(%{expires_at: 100}, 99)
      assert Token.expired?(%{expires_at: 100}, 100)
      assert Token.expired?(%{expires_at: 100}, 101)
    end
  end
end
