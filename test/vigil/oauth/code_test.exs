defmodule Vigil.OAuth.CodeTest do
  @moduledoc """
  The authorization-code record on its own: what minting writes, and every way
  a redemption can be wrong.

  `Vigil.OAuth.FlowTest` covers what the client is *told* about each of these —
  one `invalid_grant` for all of them. Here they are distinguishable, which is
  the point of the verdict being typed: the four checks are visible, and a
  test can name the one it pins.
  """

  use ExUnit.Case, async: true

  alias Vigil.OAuth
  alias Vigil.OAuth.{Code, Flow}

  @redirect_uri "https://app.example/cb"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @now 1_700_000_000

  setup do
    Vigil.OAuthCase.setup!()
  end

  defp ctx!(persistence) do
    {:ok, %{client_id: client_id}} =
      Flow.register(persistence, %{"redirect_uris" => [@redirect_uri]}, @now)

    {:ok, ctx} =
      Flow.authorize_request(persistence, %{
        "client_id" => client_id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256"
      })

    ctx
  end

  defp request(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => ctx.client.client_id,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => @verifier
      },
      overrides
    )
  end

  describe "issue/3" do
    test "writes the client, redirect URI, challenge, audience and scope it was consented for", %{
      persistence: persistence
    } do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:ok, record} = persistence.take_code.(code)
      assert record.client_id == ctx.client.client_id
      assert record.redirect_uri == @redirect_uri
      assert record.code_challenge == @challenge
      assert record.resource == OAuth.resource()
      assert record.scope == OAuth.scope()
    end

    # The one field the tests that hand-wrote this record used to leave out.
    # A code with no grant mints a pair with no family, and a family is what a
    # replay revokes.
    test "every code opens a grant of its own", %{persistence: persistence} do
      {:ok, first} = persistence.take_code.(Code.issue(persistence, ctx!(persistence), @now))
      {:ok, second} = persistence.take_code.(Code.issue(persistence, ctx!(persistence), @now))

      assert is_binary(first.grant_id)
      assert first.grant_id != second.grant_id
    end

    test "a code lives one minute", %{persistence: persistence} do
      {:ok, record} = persistence.take_code.(Code.issue(persistence, ctx!(persistence), @now))

      refute Code.expired?(record, @now + 59)
      assert Code.expired?(record, @now + 60)
    end
  end

  describe "redeem/4" do
    test "a code presented as it was issued comes back with its record", %{
      persistence: persistence
    } do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:ok, record} = Code.redeem(persistence, code, request(ctx), @now)
      assert Code.audience_of(record) == OAuth.resource()
    end

    test "a code the store has never seen", %{persistence: persistence} do
      assert {:error, :unknown} =
               Code.redeem(persistence, "nope", request(ctx!(persistence)), @now)
    end

    test "a code past its minute", %{persistence: persistence} do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:error, :expired} = Code.redeem(persistence, code, request(ctx), @now + 60)
    end

    test "a code redeemed by a client it was not issued to", %{persistence: persistence} do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:error, :wrong_client} =
               Code.redeem(
                 persistence,
                 code,
                 request(ctx, %{"client_id" => "someone-else"}),
                 @now
               )
    end

    test "a code redeemed against a redirect URI it was not checked against", %{
      persistence: persistence
    } do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:error, :wrong_redirect_uri} =
               Code.redeem(
                 persistence,
                 code,
                 request(ctx, %{"redirect_uri" => "https://app.example/other"}),
                 @now
               )
    end

    test "a verifier that does not hash to the stored challenge, and a missing one", %{
      persistence: persistence
    } do
      ctx = ctx!(persistence)

      assert {:error, :bad_pkce} =
               Code.redeem(
                 persistence,
                 Code.issue(persistence, ctx, @now),
                 request(ctx, %{"code_verifier" => "wrong"}),
                 @now
               )

      assert {:error, :bad_pkce} =
               Code.redeem(
                 persistence,
                 Code.issue(persistence, ctx, @now),
                 Map.delete(request(ctx), "code_verifier"),
                 @now
               )
    end

    # One-time use is not conditional on the redemption succeeding: the code is
    # taken out of the store before anything is checked, so a failed attempt
    # has still spent it. An attacker who guesses the client_id right on the
    # second try has nothing left to try it against.
    test "a failed redemption still consumes the code", %{persistence: persistence} do
      ctx = ctx!(persistence)
      code = Code.issue(persistence, ctx, @now)

      assert {:error, :wrong_client} =
               Code.redeem(
                 persistence,
                 code,
                 request(ctx, %{"client_id" => "someone-else"}),
                 @now
               )

      assert {:error, :unknown} = Code.redeem(persistence, code, request(ctx), @now)
    end
  end
end
