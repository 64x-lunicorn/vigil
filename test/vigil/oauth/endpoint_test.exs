defmodule Vigil.OAuth.EndpointTest do
  @moduledoc """
  The authorization server over HTTP, driven directly against
  `Vigil.OAuth.Endpoint`. That `Vigil.MCP.Server` forwards everything it does
  not own to the authorization server is asserted once, below; the audience
  check goes through `Server` because `/mcp` is its own. The decisions these
  paths make are tested without a conn in `Vigil.OAuth.FlowTest`, and that a
  token outlives the process that stored it is the `:dets` adapter's, in
  `Vigil.OAuth.PersistenceTest`.

  Nothing here is installed. The router resolves persistence, the limiter, the
  budgets and the proxy configuration once, at init, and every one of them is
  an option — so a test states the deployment it is testing instead of writing
  it into global application env and undoing it afterwards. That is what makes
  this file parallel, and it is also what lets a limit test name the budget it
  is testing rather than spend the shipped one thirty requests at a time.
  """

  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Vigil.MCP.Server
  alias Vigil.OAuth
  alias Vigil.OAuth.ClientAddr
  alias Vigil.RateLimit

  @issuer "https://vault.factory-lab.org"
  @resource "https://vault.factory-lab.org/mcp"
  @password "correct-horse-battery-staple"

  setup do
    oauth = Vigil.OAuthCase.setup!()
    Map.put(oauth, :endpoint, endpoint(persistence: oauth.persistence))
  end

  # A router of this test's own, initialized once and passed to every request
  # it makes. Counting state is built here rather than in `setup`, so each
  # router holds its own windows and no test spends a budget another is
  # counting in; the deployment has no proxy unless the test says it has one.
  # What a test does not name, `init/1` resolves the way production does.
  defp endpoint(opts) do
    opts
    |> Keyword.put_new_lazy(:limiter, &RateLimit.Counter.new/0)
    |> Keyword.put_new(:client_addr, header: nil, trusted: [])
    |> OAuth.Endpoint.init()
  end

  # The budgets are arguments. A test names the one it is testing and the rest
  # are put out of reach, so the only limit a request here can hit is the one
  # the test asked about.
  defp budgets(named), do: Map.merge(%{authorize: 1_000, token: 1_000, register: 1_000}, named)

  # A deployment behind a proxy, in the shape `Vigil.OAuth.ClientAddr.config/0`
  # would have resolved from the environment.
  defp behind_proxy(header, cidrs), do: [header: header, trusted: ClientAddr.parse_trusted(cidrs)]

  # `/mcp` is handed the authorization server's options rather than resolving
  # its own, so the token this router verifies and the token that server
  # minted are in the same place by construction.
  defp call(conn, endpoint), do: OAuth.Endpoint.call(conn, endpoint)

  defp server_call(conn, endpoint), do: Server.call(conn, Server.init(oauth: endpoint))

  defp get_json(endpoint, path) do
    conn(:get, path) |> call(endpoint)
  end

  defp post_json(endpoint, path, map) do
    conn(:post, path, Jason.encode!(map))
    |> put_req_header("content-type", "application/json")
    |> call(endpoint)
  end

  defp post_form(endpoint, path, params) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> call(endpoint)
  end

  defp get_query(endpoint, path, params) do
    conn(:get, path <> "?" <> URI.encode_query(params)) |> call(endpoint)
  end

  defp register(endpoint, redirect_uris, name \\ "Test Client") do
    conn =
      post_json(endpoint, "/oauth/register", %{client_name: name, redirect_uris: redirect_uris})

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_query(client_id, redirect_uri, challenge, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz"
      },
      extra
    )
  end

  defp extract_query_param(url, key) do
    URI.parse(url).query |> URI.decode_query() |> Map.get(key)
  end

  ## Forwarding

  test "Vigil.MCP.Server forwards a path it does not own to the authorization server", %{
    endpoint: endpoint
  } do
    conn = conn(:get, "/.well-known/oauth-protected-resource") |> server_call(endpoint)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["resource"] == @resource
    assert body["authorization_servers"] == [@issuer]
  end

  ## Discovery

  test "both protected-resource discovery paths return identical JSON, no auth required", %{
    endpoint: endpoint
  } do
    c1 = get_json(endpoint, "/.well-known/oauth-protected-resource")
    c2 = get_json(endpoint, "/.well-known/oauth-protected-resource/mcp")

    assert c1.status == 200
    assert c1.resp_body == c2.resp_body

    body = Jason.decode!(c1.resp_body)
    assert body["resource"] == @resource
    assert body["authorization_servers"] == [@issuer]
  end

  test "authorization-server metadata advertises S256 PKCE and public-client auth", %{
    endpoint: endpoint
  } do
    conn = get_json(endpoint, "/.well-known/oauth-authorization-server")
    body = Jason.decode!(conn.resp_body)

    assert body["code_challenge_methods_supported"] == ["S256"]
    assert body["token_endpoint_auth_methods_supported"] == ["none"]
    assert body["client_id_metadata_document_supported"] == true
    assert body["issuer"] == @issuer
  end

  ## DCR

  test "DCR registration succeeds and never returns a client_secret", %{endpoint: endpoint} do
    {status, body} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    assert status == 201
    assert body["client_id"] != nil
    refute Map.has_key?(body, "client_secret")
  end

  test "DCR rejects a redirect_uri that is neither https nor loopback http", %{
    endpoint: endpoint
  } do
    {status, body} = register(endpoint, ["http://evil.example.com/cb"])
    assert status == 400
    assert body["error"] == "invalid_redirect_uri"
  end

  test "DCR accepts a bare http://localhost redirect_uri", %{endpoint: endpoint} do
    {status, _body} = register(endpoint, ["http://localhost/callback"])
    assert status == 201
  end

  ## Redirect-URI matching

  test "loopback redirect matching ignores the port but not the path", %{endpoint: endpoint} do
    {201, client} = register(endpoint, ["http://localhost/callback"])
    {_verifier, challenge} = pkce_pair()

    ok =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/callback", challenge)
      )

    assert ok.status == 200

    wrong_path =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/other", challenge)
      )

    assert wrong_path.status == 400
    assert get_resp_header(wrong_path, "location") == []

    wrong_host =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://evil.tld/callback", challenge)
      )

    assert wrong_host.status == 400
    assert get_resp_header(wrong_host, "location") == []
  end

  ## Full PKCE flow

  test "full authorization_code + PKCE flow issues an access token", %{
    endpoint: endpoint,
    persistence: persistence
  } do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    get_conn =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(client["client_id"], redirect_uri, challenge)
      )

    assert get_conn.status == 200
    assert get_conn.resp_body =~ client["client_name"]

    post_conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    assert post_conn.status == 302
    [location] = get_resp_header(post_conn, "location")
    assert String.starts_with?(location, redirect_uri)
    code = extract_query_param(location, "code")
    assert extract_query_param(location, "state") == "xyz"
    assert code != nil

    token_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => verifier
      })

    assert token_conn.status == 200
    assert get_resp_header(token_conn, "cache-control") == ["no-store"]
    body = Jason.decode!(token_conn.resp_body)
    assert String.length(body["access_token"]) == 64
    assert body["refresh_token"] != nil
    assert body["scope"] == "vault"

    {:ok, record} = persistence.get_token.(body["access_token"])
    assert record.aud == @resource
  end

  test "wrong code_verifier is rejected and the code becomes permanently unusable", %{
    endpoint: endpoint
  } do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    post_conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    [location] = get_resp_header(post_conn, "location")
    code = extract_query_param(location, "code")

    bad_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => "falsch"
      })

    assert bad_conn.status == 400
    assert Jason.decode!(bad_conn.resp_body)["error"] == "invalid_grant"

    retry_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => verifier
      })

    assert retry_conn.status == 400
    assert Jason.decode!(retry_conn.resp_body)["error"] == "invalid_grant"
  end

  test "code_challenge_method=plain is rejected with a bare 400", %{endpoint: endpoint} do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])

    conn =
      get_query(
        endpoint,
        "/oauth/authorize",
        %{
          "response_type" => "code",
          "client_id" => client["client_id"],
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
          "code_challenge" => "whatever",
          "code_challenge_method" => "plain"
        }
      )

    assert conn.status == 400
    assert get_resp_header(conn, "location") == []
  end

  ## Audience

  test "an access token issued for a different resource is rejected at /mcp", %{
    endpoint: endpoint,
    persistence: persistence
  } do
    bad_token = OAuth.Token.random()

    persistence.put_token.(bad_token, %{
      aud: "https://andere.tld/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{bad_token}")
      |> server_call(endpoint)

    assert conn.status == 401
  end

  ## Refresh

  test "refresh rotates both tokens; the old refresh token becomes invalid", %{
    endpoint: endpoint
  } do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    post_conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    [location] = get_resp_header(post_conn, "location")
    code = extract_query_param(location, "code")

    token_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => verifier
      })

    tokens = Jason.decode!(token_conn.resp_body)

    refresh_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client["client_id"]
      })

    assert refresh_conn.status == 200
    new_tokens = Jason.decode!(refresh_conn.resp_body)
    assert new_tokens["access_token"] != tokens["access_token"]
    assert new_tokens["refresh_token"] != tokens["refresh_token"]

    reuse_conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client["client_id"]
      })

    assert reuse_conn.status == 400
    assert Jason.decode!(reuse_conn.resp_body)["error"] == "invalid_grant"
  end

  test "an expired refresh token yields exactly invalid_grant", %{
    endpoint: endpoint,
    persistence: persistence
  } do
    refresh = OAuth.Token.random()

    persistence.put_token.(refresh, %{
      type: :refresh,
      client_id: "some-client",
      aud: @resource,
      expires_at: System.system_time(:second) - 1
    })

    conn =
      post_form(endpoint, "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => "some-client"
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_grant"
  end

  ## Password / rate limiting

  test "wrong password re-renders the consent page without a redirect or a code", %{
    endpoint: endpoint
  } do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => "falsch",
          "decision" => "allow"
        })
      )

    assert conn.status == 200
    assert get_resp_header(conn, "location") == []
    assert conn.resp_body =~ "Wrong password"
  end

  test "the sixth wrong-password attempt within 15 minutes gets 429", %{endpoint: endpoint} do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    params =
      Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
        "password" => "falsch",
        "decision" => "allow"
      })

    results = for _ <- 1..6, do: post_form(endpoint, "/oauth/authorize", params).status

    assert Enum.take(results, 5) == [200, 200, 200, 200, 200]
    assert List.last(results) == 429
  end

  ## The address the limit is keyed on

  test "behind a trusted proxy the consent limit is counted per forwarded client", %{
    persistence: persistence
  } do
    endpoint =
      endpoint(
        persistence: persistence,
        client_addr: behind_proxy("cf-connecting-ip", ["203.0.113.0/24"])
      )

    params = wrong_password_params(endpoint)

    # Five failures exhaust this client's budget and the sixth is refused...
    for _ <- 1..5 do
      assert consent_as(endpoint, params, {203, 0, 113, 7}, "198.51.100.9").status == 200
    end

    assert consent_as(endpoint, params, {203, 0, 113, 7}, "198.51.100.9").status == 429

    # ...and the next client through the same proxy still has its own.
    assert consent_as(endpoint, params, {203, 0, 113, 7}, "198.51.100.20").status == 200
  end

  test "a forwarded header from an untrusted peer buys the caller nothing", %{
    persistence: persistence
  } do
    endpoint =
      endpoint(
        persistence: persistence,
        client_addr: behind_proxy("cf-connecting-ip", ["203.0.113.0/24"])
      )

    params = wrong_password_params(endpoint)

    # The peer is not the proxy, so claiming a fresh address on every attempt
    # does not get a fresh budget: all six land in the peer's own bucket.
    results =
      for i <- 1..6, do: consent_as(endpoint, params, {192, 0, 2, 5}, "198.51.100.#{i}").status

    assert Enum.take(results, 5) == [200, 200, 200, 200, 200]
    assert List.last(results) == 429
  end

  test "with no proxy configured the header is ignored and the peer is the bucket", %{
    endpoint: endpoint
  } do
    params = wrong_password_params(endpoint)

    results =
      for i <- 1..6,
          do: consent_as(endpoint, params, {203, 0, 113, 7}, "198.51.100.#{i}").status

    assert List.last(results) == 429
  end

  ## Issuer identification (RFC 9207)

  test "the authorization response says which server issued it", %{endpoint: endpoint} do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert extract_query_param(location, "iss") == @issuer
    assert extract_query_param(location, "code") != nil
  end

  test "an error redirect says which server issued it too", %{endpoint: endpoint} do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "decision" => "deny"
        })
      )

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert extract_query_param(location, "error") == "access_denied"
    assert extract_query_param(location, "iss") == @issuer
  end

  test "the metadata tells a client the iss parameter will be there", %{endpoint: endpoint} do
    body =
      Jason.decode!(get_json(endpoint, "/.well-known/oauth-authorization-server").resp_body)

    assert body["authorization_response_iss_parameter_supported"] == true
  end

  ## Rate limits on the endpoints themselves

  test "the shipped budgets are per minute and per address, register the tightest" do
    limits = Vigil.OAuth.Endpoint.init([])[:limits]

    assert limits == %{authorize: 30, token: 30, register: 5}
  end

  test "registration past its budget is refused with an RFC 6749 error body", %{
    persistence: persistence
  } do
    endpoint = endpoint(persistence: persistence, limits: budgets(%{register: 2}))

    body = %{client_name: "Test Client", redirect_uris: ["https://claude.ai/cb"]}

    assert post_json(endpoint, "/oauth/register", body).status == 201
    assert post_json(endpoint, "/oauth/register", body).status == 201

    conn = post_json(endpoint, "/oauth/register", body)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "temporarily_unavailable"
  end

  test "the token endpoint past its budget is refused with an RFC 6749 error body", %{
    persistence: persistence
  } do
    endpoint = endpoint(persistence: persistence, limits: budgets(%{token: 1}))

    # Under budget the answer is the flow's own: an unknown code is a bad
    # grant. Over it, the endpoint answers before the flow is consulted.
    assert post_form(endpoint, "/oauth/token", %{"grant_type" => "authorization_code"}).status ==
             400

    conn = post_form(endpoint, "/oauth/token", %{"grant_type" => "authorization_code"})
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "temporarily_unavailable"
    # The wait is stated, so a client renewing reactively does not have to guess.
    assert get_resp_header(conn, "retry-after") == ["60"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "the consent page past its budget is refused as HTML, not as JSON", %{
    persistence: persistence
  } do
    endpoint = endpoint(persistence: persistence, limits: budgets(%{authorize: 1}))
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    query =
      authorize_query(client["client_id"], "https://claude.ai/api/mcp/auth_callback", challenge)

    assert get_query(endpoint, "/oauth/authorize", query).status == 200

    conn = get_query(endpoint, "/oauth/authorize", query)
    assert conn.status == 429
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    # The same headers the rest of the HTML surface carries — a refusal is
    # still a page a browser renders.
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "a refused /authorize never reaches the CIMD fetch", %{persistence: persistence} do
    endpoint = endpoint(persistence: persistence, limits: budgets(%{authorize: 1}))
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    # Spend the budget on a client that needs no fetch...
    spend =
      authorize_query(client["client_id"], "https://claude.ai/api/mcp/auth_callback", challenge)

    assert get_query(endpoint, "/oauth/authorize", spend).status == 200

    # ...then ask with an https client_id, which is the only input that sends
    # `Vigil.OAuth.Client.resolve/4` out to the network. 429 is the endpoint
    # refusing before it resolves anything; a fetch that had been attempted
    # would have failed and come back as 400 untrusted instead.
    conn =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(
          "https://cimd.invalid/metadata.json",
          "https://cimd.invalid/cb",
          challenge
        )
      )

    assert conn.status == 429
  end

  test "behind a trusted proxy the endpoint budgets are per forwarded client", %{
    persistence: persistence
  } do
    endpoint =
      endpoint(
        persistence: persistence,
        limits: budgets(%{register: 1}),
        client_addr: behind_proxy("cf-connecting-ip", ["203.0.113.0/24"])
      )

    body = %{client_name: "Test Client", redirect_uris: ["https://claude.ai/cb"]}

    assert register_as(endpoint, body, {203, 0, 113, 7}, "198.51.100.9").status == 201
    assert register_as(endpoint, body, {203, 0, 113, 7}, "198.51.100.9").status == 429

    # A different client through the same proxy still has its own budget.
    assert register_as(endpoint, body, {203, 0, 113, 7}, "198.51.100.20").status == 201
  end

  defp register_as(endpoint, body, peer, forwarded) do
    conn(:post, "/oauth/register", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("cf-connecting-ip", forwarded)
    |> Map.put(:remote_ip, peer)
    |> call(endpoint)
  end

  defp wrong_password_params(endpoint) do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
      "password" => "falsch",
      "decision" => "allow"
    })
  end

  defp consent_as(endpoint, params, peer, forwarded) do
    conn(:post, "/oauth/authorize", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("cf-connecting-ip", forwarded)
    |> Map.put(:remote_ip, peer)
    |> call(endpoint)
  end

  ## Response headers on the HTML

  # The consent page is the only HTML vigil serves and the only place a human
  # types a password, so the headers on it are worth asserting rather than
  # hoping for.

  defp consent_page(endpoint) do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    get_query(
      endpoint,
      "/oauth/authorize",
      authorize_query(client["client_id"], "https://claude.ai/api/mcp/auth_callback", challenge)
    )
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp csp_directives(conn) do
    conn
    |> header("content-security-policy")
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
  end

  test "the consent page denies by default and permits only what it uses", %{
    endpoint: endpoint
  } do
    conn = consent_page(endpoint)
    assert conn.status == 200

    directives = csp_directives(conn)

    assert "default-src 'none'" in directives
    assert "frame-ancestors 'none'" in directives
    assert "base-uri 'none'" in directives

    # form-action is deliberately absent: its treatment of the redirect that
    # answers the Allow POST is not interoperable, and it guards nothing here.
    # See Vigil.OAuth.Endpoint.html_security_headers/1.
    refute Enum.any?(directives, &String.starts_with?(&1, "form-action"))

    # The page's one style block, and nothing else. No 'unsafe-inline'
    # anywhere: an injected <style> without the nonce does not run.
    assert Enum.any?(directives, &String.starts_with?(&1, "style-src 'nonce-"))
    refute conn |> header("content-security-policy") =~ "unsafe-inline"
  end

  test "the consent page carries the three headers a password form deserves", %{
    endpoint: endpoint
  } do
    conn = consent_page(endpoint)

    assert header(conn, "x-content-type-options") == "nosniff"
    assert header(conn, "referrer-policy") == "no-referrer"
    # frame-ancestors covers modern clients; this covers the ones that predate it.
    assert header(conn, "x-frame-options") == "DENY"
  end

  test "the nonce in the policy is the nonce on the page, and is fresh each time", %{
    endpoint: endpoint
  } do
    conn = consent_page(endpoint)

    [nonce] =
      Regex.run(~r/style-src 'nonce-([^']+)'/, header(conn, "content-security-policy"))
      |> tl()

    assert conn.resp_body =~ ~s(<style nonce="#{nonce}">)

    second = consent_page(endpoint)

    [other] =
      Regex.run(~r/style-src 'nonce-([^']+)'/, header(second, "content-security-policy")) |> tl()

    refute other == nonce
  end

  test "the page renders no external asset and runs no script, as the policy claims", %{
    endpoint: endpoint
  } do
    # `default-src 'none'` is only honest while this stays true. The URLs in
    # the hidden fields are data, not asset references, so the check is for
    # the things that would actually load something.
    body = consent_page(endpoint).resp_body

    refute body =~ "<script"
    refute body =~ "<link"
    refute body =~ "<img"
    refute body =~ "src="
    refute body =~ "url("
  end

  test "the error variant still renders and still carries the headers", %{
    endpoint: endpoint
  } do
    {201, client} = register(endpoint, ["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
        endpoint,
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => "falsch",
          "decision" => "allow"
        })
      )

    assert conn.status == 200
    assert conn.resp_body =~ "Wrong password"

    [nonce] =
      Regex.run(~r/style-src 'nonce-([^']+)'/, header(conn, "content-security-policy")) |> tl()

    assert conn.resp_body =~ ~s(<style nonce="#{nonce}">)
    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "referrer-policy") == "no-referrer"
  end

  test "the loopback-warning variant still renders and still carries the headers", %{
    endpoint: endpoint
  } do
    {201, client} = register(endpoint, ["http://localhost/callback"])
    {_verifier, challenge} = pkce_pair()

    conn =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/callback", challenge)
      )

    assert conn.status == 200
    assert conn.resp_body =~ "loopback redirect address"

    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "x-content-type-options") == "nosniff"
    assert csp_directives(conn) |> Enum.member?("frame-ancestors 'none'")
  end

  test "the HTML error page refuses framing too, and needs no style-src", %{
    endpoint: endpoint
  } do
    conn =
      get_query(
        endpoint,
        "/oauth/authorize",
        authorize_query("nobody", "https://evil.tld/cb", "x")
      )

    assert conn.status == 400

    directives = csp_directives(conn)
    assert "default-src 'none'" in directives
    assert "frame-ancestors 'none'" in directives
    refute Enum.any?(directives, &String.starts_with?(&1, "style-src"))

    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "x-content-type-options") == "nosniff"
    assert header(conn, "referrer-policy") == "no-referrer"
  end

  ## Janitor sweep (time injected, no sleeping)

  test "an expired code is gone after a sweep", %{
    endpoint: endpoint,
    persistence: persistence
  } do
    {201, client} = register(endpoint, ["https://client.example/cb"])
    {_verifier, challenge} = pkce_pair()

    {:ok, ctx} =
      OAuth.Flow.authorize_request(
        persistence,
        authorize_query(client["client_id"], "https://client.example/cb", challenge)
      )

    # A code lives a minute, so one minted an hour ago has expired. Minted by
    # the module that owns the record, so what the sweep walks is the shape
    # production writes.
    code = OAuth.Code.issue(persistence, ctx, System.system_time(:second) - 3600)

    persistence.sweep_expired.(System.system_time(:second))

    assert persistence.take_code.(code) == :error
  end

  ## CIMD SSRF guard (deterministic — a literal loopback IP needs no network access)

  test "a CIMD client_id resolving to a private IP is rejected", %{persistence: persistence} do
    assert OAuth.Cimd.fetch(persistence, "https://127.0.0.1/client-metadata.json") == :error
  end
end
