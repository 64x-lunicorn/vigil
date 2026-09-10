defmodule Vigil.OAuth.FlowTest do
  @moduledoc """
  The OAuth decisions on their own. No conn, no router — and no vault: before
  the flow was split out of `Vigil.MCP.Server`, asking any of these questions
  meant starting a git-backed fixture vault, a `Vigil.Store`, an envelope and
  a rate limiter, because `initialize` and every tool call reached the Store
  through the same Plug.
  """
  use ExUnit.Case, async: false

  alias Vigil.OAuth.{Code, Flow, Store}

  setup do
    Vigil.OAuthCase.setup!()
    :ok
  end

  defp client! do
    {:ok, %{client_id: id}} =
      Flow.register(%{"redirect_uris" => ["https://app.example/cb"], "client_name" => "App"})

    id
  end

  defp authorize_params(client_id, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => client_id,
        "redirect_uri" => "https://app.example/cb",
        "response_type" => "code",
        "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  # One whole authorization: consent, code, redemption. Several tests need a
  # second grant for the same client, which is the case the family revocation
  # must not touch.
  defp tokens_for(client_id) do
    {:ok, ctx} = Flow.authorize_request(authorize_params(client_id))
    code = Code.issue(ctx)

    {:ok, tokens} =
      Flow.grant(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client_id,
        "redirect_uri" => "https://app.example/cb",
        "code_verifier" => "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      })

    tokens
  end

  describe "register/2" do
    test "a registration never carries a client_secret" do
      assert {:ok, registration} =
               Flow.register(%{"redirect_uris" => ["https://app.example/cb"]})

      refute Map.has_key?(registration, :client_secret)
      assert registration.token_endpoint_auth_method == "none"
    end

    test "a redirect_uri that is neither https nor loopback http is refused" do
      assert {:error, "invalid_redirect_uri"} =
               Flow.register(%{"redirect_uris" => ["http://evil.example/cb"]})
    end

    test "no redirect_uri at all is refused" do
      assert {:error, "invalid_redirect_uri"} = Flow.register(%{})
    end
  end

  describe "authorize_request/1" do
    test "an unknown client is untrusted, never redirected to" do
      assert {:error, :untrusted} = Flow.authorize_request(authorize_params("nope"))
    end

    test "a redirect_uri the client did not register is untrusted" do
      params = authorize_params(client!(), %{"redirect_uri" => "https://evil.example/cb"})
      assert {:error, :untrusted} = Flow.authorize_request(params)
    end

    test "plain PKCE is refused locally rather than redirected" do
      params = authorize_params(client!(), %{"code_challenge_method" => "plain"})
      assert {:error, :bad_code_challenge_method} = Flow.authorize_request(params)
    end

    test "a missing code_challenge is reported to the client as a redirect" do
      params = authorize_params(client!(), %{"code_challenge" => "", "state" => "xyz"})

      assert {:error, {:redirect, "https://app.example/cb", "invalid_request", "xyz"}} =
               Flow.authorize_request(params)
    end

    test "an unknown scope is reported to the client as a redirect" do
      params = authorize_params(client!(), %{"scope" => "vault:admin"})

      assert {:error, {:redirect, _, "invalid_scope", _}} = Flow.authorize_request(params)
    end

    test "a resource other than this server is an invalid target" do
      params = authorize_params(client!(), %{"resource" => "https://elsewhere.example/mcp"})

      assert {:error, {:redirect, _, "invalid_target", _}} = Flow.authorize_request(params)
    end

    test "a valid request defaults to the full scope" do
      assert {:ok, ctx} = Flow.authorize_request(authorize_params(client!()))
      assert ctx.scope == "vault"
    end

    test "the read-only scope is carried through" do
      params = authorize_params(client!(), %{"scope" => "vault:read"})
      assert {:ok, %{scope: "vault:read"}} = Flow.authorize_request(params)
    end
  end

  describe "grant/2 — authorization_code" do
    setup do
      client_id = client!()
      {:ok, ctx} = Flow.authorize_request(authorize_params(client_id))
      code = Code.issue(ctx)

      %{client_id: client_id, code: code}
    end

    defp code_grant(overrides) do
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "redirect_uri" => "https://app.example/cb",
          "code_verifier" => "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        },
        overrides
      )
    end

    test "a correct verifier yields an access and a refresh token", %{
      client_id: client_id,
      code: code
    } do
      assert {:ok, tokens} =
               Flow.grant(code_grant(%{"code" => code, "client_id" => client_id}))

      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 3600
      assert is_binary(tokens.access_token)
      assert is_binary(tokens.refresh_token)
    end

    test "a wrong verifier is invalid_grant and spends the code", %{
      client_id: client_id,
      code: code
    } do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(
                 code_grant(%{
                   "code" => code,
                   "client_id" => client_id,
                   "code_verifier" => "wrong"
                 })
               )

      # One-time use: the code is gone even though the attempt failed.
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(code_grant(%{"code" => code, "client_id" => client_id}))
    end

    test "another client cannot redeem the code", %{code: code} do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(code_grant(%{"code" => code, "client_id" => "someone-else"}))
    end

    test "a mismatched redirect_uri is invalid_grant", %{client_id: client_id, code: code} do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(
                 code_grant(%{
                   "code" => code,
                   "client_id" => client_id,
                   "redirect_uri" => "https://app.example/other"
                 })
               )
    end

    test "an expired code is invalid_grant", %{client_id: client_id, code: code} do
      later = System.system_time(:second) + 120

      assert {:error, 400, "invalid_grant"} =
               Flow.grant(code_grant(%{"code" => code, "client_id" => client_id}), later)
    end

    test "an unknown code is invalid_grant" do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(code_grant(%{"code" => "nope", "client_id" => "x"}))
    end
  end

  describe "grant/2 — refresh_token" do
    setup do
      client_id = client!()
      {:ok, ctx} = Flow.authorize_request(authorize_params(client_id))
      code = Code.issue(ctx)

      {:ok, tokens} =
        Flow.grant(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "redirect_uri" => "https://app.example/cb",
          "code_verifier" => "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        })

      %{client_id: client_id, tokens: tokens}
    end

    test "refreshing rotates the refresh token", %{client_id: client_id, tokens: tokens} do
      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens.refresh_token,
        "client_id" => client_id
      }

      assert {:ok, fresh} = Flow.grant(params)
      assert fresh.refresh_token != tokens.refresh_token

      # The presented token is spent, so a replay is refused — and, as the
      # tests below cover, recognised rather than merely refused.
      assert {:error, 400, "invalid_grant"} = Flow.grant(params)
    end

    test "an access token is not a refresh token", %{client_id: client_id, tokens: tokens} do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => tokens.access_token,
                 "client_id" => client_id
               })
    end

    test "another client cannot refresh", %{tokens: tokens} do
      assert {:error, 400, "invalid_grant"} =
               Flow.grant(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => "someone-else"
               })
    end

    test "every token records the grant it descends from", %{tokens: tokens} do
      {:ok, access} = Store.get_token(tokens.access_token)
      {:ok, refresh} = Store.get_token(tokens.refresh_token)

      assert is_binary(access.grant_id)
      assert access.grant_id == refresh.grant_id
    end

    test "a rotated pair stays in the same grant", %{client_id: client_id, tokens: tokens} do
      {:ok, before} = Store.get_token(tokens.refresh_token)

      assert {:ok, fresh} =
               Flow.grant(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client_id
               })

      {:ok, after_refresh} = Store.get_token(fresh.refresh_token)
      assert after_refresh.grant_id == before.grant_id
    end

    test "a second grant to the same client is a different grant" do
      client_id = client!()

      first = tokens_for(client_id)
      second = tokens_for(client_id)

      {:ok, one} = Store.get_token(first.refresh_token)
      {:ok, two} = Store.get_token(second.refresh_token)

      assert one.grant_id != two.grant_id
    end

    test "replaying a spent refresh token kills the pair that replaced it", %{
      client_id: client_id,
      tokens: tokens
    } do
      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens.refresh_token,
        "client_id" => client_id
      }

      # The legitimate rotation.
      assert {:ok, rotated} = Flow.grant(params)
      assert {:ok, _} = Store.get_token(rotated.access_token)

      # Somebody presents the spent token. RFC 9700 §4.14.2: exactly one of
      # the two holders is an attacker, and the authorization server does not
      # know which — so the whole grant goes.
      assert {:error, 400, "invalid_grant"} = Flow.grant(params)

      assert Store.get_token(rotated.access_token) == :error
      assert Store.get_token(rotated.refresh_token) == :error
      assert Store.get_token(tokens.access_token) == :error
      assert Store.get_token(tokens.refresh_token) == :error
    end

    test "a replay is answered exactly like a token that never existed", %{
      client_id: client_id,
      tokens: tokens
    } do
      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens.refresh_token,
        "client_id" => client_id
      }

      assert {:ok, _} = Flow.grant(params)

      replay = Flow.grant(params)
      unknown = Flow.grant(%{params | "refresh_token" => Vigil.OAuth.Token.random()})

      # The caller must not learn that a family was found and revoked.
      assert replay == unknown
    end

    test "one grant's revocation leaves another grant alone", %{
      client_id: client_id,
      tokens: tokens
    } do
      other = tokens_for(client_id)

      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens.refresh_token,
        "client_id" => client_id
      }

      assert {:ok, _} = Flow.grant(params)
      assert {:error, 400, "invalid_grant"} = Flow.grant(params)

      # A client legitimately holds more than one grant over time, which is
      # why the family is keyed on the grant and not on the client.
      assert {:ok, _} = Store.get_token(other.access_token)
      assert {:ok, _} = Store.get_token(other.refresh_token)
    end

    test "a refresh token from before grants existed revokes nothing on replay" do
      # What is already in a deployment's dets file, written before grants
      # existed: a refresh token and an access token, neither carrying one.
      # "Every token whose grant is unknown" must not be read as a family, or
      # one replay would revoke a stranger along with its own.
      client_id = client!()
      legacy = Vigil.OAuth.Token.random()
      unrelated = Vigil.OAuth.Token.random()
      aud = Vigil.OAuth.resource()

      Store.put_token(legacy, %{
        type: :refresh,
        client_id: client_id,
        aud: aud,
        scope: "vault",
        expires_at: System.system_time(:second) + 3600
      })

      Store.put_token(unrelated, %{aud: aud, scope: "vault", expires_at: 4_000_000_000})

      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => legacy,
        "client_id" => client_id
      }

      assert {:ok, fresh} = Flow.grant(params)
      assert {:error, 400, "invalid_grant"} = Flow.grant(params)

      assert {:ok, _} = Store.get_token(unrelated)
      # The rotated pair got a grant of its own, so it is not collateral either.
      assert {:ok, _} = Store.get_token(fresh.access_token)
    end

    test "the scope survives a refresh", %{client_id: client_id, tokens: tokens} do
      assert {:ok, fresh} =
               Flow.grant(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client_id
               })

      assert fresh.scope == tokens.scope
    end
  end

  describe "grant/2 — anything else" do
    test "an unknown grant type is refused as such" do
      assert {:error, 400, "unsupported_grant_type"} =
               Flow.grant(%{"grant_type" => "password"})

      assert {:error, 400, "unsupported_grant_type"} = Flow.grant(%{})
    end
  end

  describe "consent/4" do
    setup do
      {:ok, ctx} = Flow.authorize_request(authorize_params(client!()))
      %{ctx: ctx}
    end

    test "the right password yields a usable code", %{ctx: ctx} do
      assert {:ok, code} = Flow.consent("10.0.0.1", "correct-horse-battery-staple", ctx)
      assert {:ok, _} = Store.take_code(code)
    end

    test "a wrong password yields no code", %{ctx: ctx} do
      assert :wrong_password = Flow.consent("10.0.0.2", "wrong", ctx)
      assert :wrong_password = Flow.consent("10.0.0.2", nil, ctx)
    end

    test "the sixth wrong attempt from one address is rate limited", %{ctx: ctx} do
      for _ <- 1..5, do: assert(:wrong_password = Flow.consent("10.0.0.3", "wrong", ctx))
      assert :rate_limited = Flow.consent("10.0.0.3", "wrong", ctx)

      # The limit is per address.
      assert :wrong_password = Flow.consent("10.0.0.4", "wrong", ctx)
    end

    test "a success clears the address's failure count", %{ctx: ctx} do
      for _ <- 1..4, do: Flow.consent("10.0.0.5", "wrong", ctx)
      assert {:ok, _} = Flow.consent("10.0.0.5", "correct-horse-battery-staple", ctx)

      for _ <- 1..5, do: assert(:wrong_password = Flow.consent("10.0.0.5", "wrong", ctx))
    end
  end

  describe "authorize_request/3 — CIMD" do
    # A client_id the flow cannot have registered via DCR, so resolving it
    # only succeeds by going out to `net` — the join `Vigil.OAuth.Client`
    # names. A fresh URL per test keeps each test's cache entry its own,
    # since `Vigil.OAuth.Store`'s CIMD cache is a process-wide ETS table.
    defp cimd_url, do: "https://cimd-#{System.unique_integer([:positive])}.example/metadata.json"

    defp cimd_document(url, overrides) do
      %{
        "client_id" => url,
        "client_name" => "CIMD Client",
        "redirect_uris" => ["https://cimd-client.example/cb"]
      }
      |> Map.merge(overrides)
      |> Jason.encode!()
    end

    defp cimd_net(opts) do
      body = Keyword.get(opts, :body)
      test = self()

      %{
        request: fn uri, ip ->
          send(test, {:request, URI.to_string(uri), ip})
          {:ok, body}
        end,
        resolve: fn _host, _family -> {:ok, {93, 184, 216, 34}} end
      }
    end

    test "a CIMD client's redirect_uris are matched, through the flow" do
      url = cimd_url()
      net = cimd_net(body: cimd_document(url, %{}))
      params = authorize_params(url, %{"redirect_uri" => "https://cimd-client.example/cb"})

      assert {:ok, ctx} = Flow.authorize_request(params, 1_700_000_000, net)
      assert ctx.client.client_id == url
      assert ctx.client.redirect_uris == ["https://cimd-client.example/cb"]
    end

    test "the CIMD document's client_name is what the consent page renders" do
      url = cimd_url()
      net = cimd_net(body: cimd_document(url, %{"client_name" => "Claude Code"}))
      params = authorize_params(url, %{"redirect_uri" => "https://cimd-client.example/cb"})

      assert {:ok, ctx} = Flow.authorize_request(params, 1_700_000_000, net)
      # `Vigil.OAuth.Endpoint.render_consent/2` renders exactly `ctx.client.name`.
      assert ctx.client.name == "Claude Code"
    end

    test "a redirect_uri the CIMD document does not list is untrusted" do
      url = cimd_url()
      net = cimd_net(body: cimd_document(url, %{}))
      params = authorize_params(url, %{"redirect_uri" => "https://evil.example/cb"})

      assert {:error, :untrusted} = Flow.authorize_request(params, 1_700_000_000, net)
    end

    test "a second request inside the cache's hour does not fetch again" do
      url = cimd_url()
      net = cimd_net(body: cimd_document(url, %{}))
      params = authorize_params(url, %{"redirect_uri" => "https://cimd-client.example/cb"})

      assert {:ok, _} = Flow.authorize_request(params, 1_700_000_000, net)
      assert_received {:request, _, _}

      assert {:ok, _} = Flow.authorize_request(params, 1_700_003_599, net)
      refute_received {:request, _, _}
    end

    test "a request after the cache's hour has elapsed fetches again" do
      url = cimd_url()
      net = cimd_net(body: cimd_document(url, %{}))
      params = authorize_params(url, %{"redirect_uri" => "https://cimd-client.example/cb"})

      assert {:ok, _} = Flow.authorize_request(params, 1_700_000_000, net)
      assert_received {:request, _, _}

      assert {:ok, _} = Flow.authorize_request(params, 1_700_003_601, net)
      assert_received {:request, _, _}
    end
  end

  describe "a minted code is one-time use" do
    test "the code is one-time: taking it twice fails" do
      {:ok, ctx} = Flow.authorize_request(authorize_params(client!()))
      code = Code.issue(ctx)

      assert {:ok, _} = Store.take_code(code)
      assert :error = Store.take_code(code)
    end
  end
end
