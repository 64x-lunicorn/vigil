defmodule Vigil.OAuth.EndpointTest do
  @moduledoc """
  The authorization server over HTTP, driven through `Vigil.MCP.Server` so the
  forwarding is exercised too. The decisions these paths make are tested
  without a conn in `Vigil.OAuth.FlowTest`.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Vigil.MCP.Server
  alias Vigil.OAuth
  alias Vigil.Store

  @issuer "https://vault.factory-lab.org"
  @resource "https://vault.factory-lab.org/mcp"
  @password "correct-horse-battery-staple"

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Vigil.MCP.Envelope)
    start_supervised!(Vigil.RateLimit)

    oauth = Vigil.OAuthCase.setup!()
    %{vault: vault, state_dir: oauth.state_dir}
  end

  defp call(conn), do: Server.call(conn, Server.init([]))

  defp get_json(path) do
    conn(:get, path) |> call()
  end

  defp post_json(path, map) do
    conn(:post, path, Jason.encode!(map))
    |> put_req_header("content-type", "application/json")
    |> call()
  end

  defp post_form(path, params) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> call()
  end

  defp get_query(path, params) do
    conn(:get, path <> "?" <> URI.encode_query(params)) |> call()
  end

  defp register(redirect_uris, name \\ "Test Client") do
    conn = post_json("/oauth/register", %{client_name: name, redirect_uris: redirect_uris})
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

  ## Discovery

  test "both protected-resource discovery paths return identical JSON, no auth required" do
    c1 = get_json("/.well-known/oauth-protected-resource")
    c2 = get_json("/.well-known/oauth-protected-resource/mcp")

    assert c1.status == 200
    assert c1.resp_body == c2.resp_body

    body = Jason.decode!(c1.resp_body)
    assert body["resource"] == @resource
    assert body["authorization_servers"] == [@issuer]
  end

  test "authorization-server metadata advertises S256 PKCE and public-client auth" do
    conn = get_json("/.well-known/oauth-authorization-server")
    body = Jason.decode!(conn.resp_body)

    assert body["code_challenge_methods_supported"] == ["S256"]
    assert body["token_endpoint_auth_methods_supported"] == ["none"]
    assert body["client_id_metadata_document_supported"] == true
    assert body["issuer"] == @issuer
  end

  ## DCR

  test "DCR registration succeeds and never returns a client_secret" do
    {status, body} = register(["https://claude.ai/api/mcp/auth_callback"])
    assert status == 201
    assert body["client_id"] != nil
    refute Map.has_key?(body, "client_secret")
  end

  test "DCR rejects a redirect_uri that is neither https nor loopback http" do
    {status, body} = register(["http://evil.example.com/cb"])
    assert status == 400
    assert body["error"] == "invalid_redirect_uri"
  end

  test "DCR accepts a bare http://localhost redirect_uri" do
    {status, _body} = register(["http://localhost/callback"])
    assert status == 201
  end

  ## Redirect-URI matching

  test "loopback redirect matching ignores the port but not the path" do
    {201, client} = register(["http://localhost/callback"])
    {_verifier, challenge} = pkce_pair()

    ok =
      get_query(
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/callback", challenge)
      )

    assert ok.status == 200

    wrong_path =
      get_query(
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/other", challenge)
      )

    assert wrong_path.status == 400
    assert get_resp_header(wrong_path, "location") == []

    wrong_host =
      get_query(
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://evil.tld/callback", challenge)
      )

    assert wrong_host.status == 400
    assert get_resp_header(wrong_host, "location") == []
  end

  ## Full PKCE flow

  test "full authorization_code + PKCE flow issues an access token" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    get_conn =
      get_query("/oauth/authorize", authorize_query(client["client_id"], redirect_uri, challenge))

    assert get_conn.status == 200
    assert get_conn.resp_body =~ client["client_name"]

    post_conn =
      post_form(
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
      post_form("/oauth/token", %{
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

    {:ok, record} = OAuth.Store.get_token(body["access_token"])
    assert record.aud == @resource
  end

  test "wrong code_verifier is rejected and the code becomes permanently unusable" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    post_conn =
      post_form(
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    [location] = get_resp_header(post_conn, "location")
    code = extract_query_param(location, "code")

    bad_conn =
      post_form("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => "falsch"
      })

    assert bad_conn.status == 400
    assert Jason.decode!(bad_conn.resp_body)["error"] == "invalid_grant"

    retry_conn =
      post_form("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => verifier
      })

    assert retry_conn.status == 400
    assert Jason.decode!(retry_conn.resp_body)["error"] == "invalid_grant"
  end

  test "code_challenge_method=plain is rejected with a bare 400" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])

    conn =
      get_query(
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

  test "an access token issued for a different resource is rejected at /mcp" do
    bad_token = OAuth.Token.random()

    OAuth.Store.put_token(bad_token, %{
      aud: "https://andere.tld/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{bad_token}")
      |> call()

    assert conn.status == 401
  end

  ## Refresh

  test "refresh rotates both tokens; the old refresh token becomes invalid" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    post_conn =
      post_form(
        "/oauth/authorize",
        Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
          "password" => @password,
          "decision" => "allow"
        })
      )

    [location] = get_resp_header(post_conn, "location")
    code = extract_query_param(location, "code")

    token_conn =
      post_form("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client["client_id"],
        "code_verifier" => verifier
      })

    tokens = Jason.decode!(token_conn.resp_body)

    refresh_conn =
      post_form("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client["client_id"]
      })

    assert refresh_conn.status == 200
    new_tokens = Jason.decode!(refresh_conn.resp_body)
    assert new_tokens["access_token"] != tokens["access_token"]
    assert new_tokens["refresh_token"] != tokens["refresh_token"]

    reuse_conn =
      post_form("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client["client_id"]
      })

    assert reuse_conn.status == 400
    assert Jason.decode!(reuse_conn.resp_body)["error"] == "invalid_grant"
  end

  test "an expired refresh token yields exactly invalid_grant" do
    refresh = OAuth.Token.random()

    OAuth.Store.put_token(refresh, %{
      type: :refresh,
      client_id: "some-client",
      aud: @resource,
      expires_at: System.system_time(:second) - 1
    })

    conn =
      post_form("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => "some-client"
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_grant"
  end

  ## Password / rate limiting

  test "wrong password re-renders the consent page without a redirect or a code" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
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

  test "the sixth wrong-password attempt within 15 minutes gets 429" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    params =
      Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
        "password" => "falsch",
        "decision" => "allow"
      })

    results = for _ <- 1..6, do: post_form("/oauth/authorize", params).status

    assert Enum.take(results, 5) == [200, 200, 200, 200, 200]
    assert List.last(results) == 429
  end

  ## The address the limit is keyed on

  test "behind a trusted proxy the consent limit is counted per forwarded client" do
    trust_proxy!("cf-connecting-ip", ["203.0.113.0/24"])
    params = wrong_password_params()

    # Five failures exhaust this client's budget and the sixth is refused...
    for _ <- 1..5 do
      assert consent_as(params, {203, 0, 113, 7}, "198.51.100.9").status == 200
    end

    assert consent_as(params, {203, 0, 113, 7}, "198.51.100.9").status == 429

    # ...and the next client through the same proxy still has its own.
    assert consent_as(params, {203, 0, 113, 7}, "198.51.100.20").status == 200
  end

  test "a forwarded header from an untrusted peer buys the caller nothing" do
    trust_proxy!("cf-connecting-ip", ["203.0.113.0/24"])
    params = wrong_password_params()

    # The peer is not the proxy, so claiming a fresh address on every attempt
    # does not get a fresh budget: all six land in the peer's own bucket.
    results =
      for i <- 1..6, do: consent_as(params, {192, 0, 2, 5}, "198.51.100.#{i}").status

    assert Enum.take(results, 5) == [200, 200, 200, 200, 200]
    assert List.last(results) == 429
  end

  test "with no proxy configured the header is ignored and the peer is the bucket" do
    params = wrong_password_params()

    results =
      for i <- 1..6, do: consent_as(params, {203, 0, 113, 7}, "198.51.100.#{i}").status

    assert List.last(results) == 429
  end

  ## Issuer identification (RFC 9207)

  test "the authorization response says which server issued it" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
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

  test "an error redirect says which server issued it too" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
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

  test "the metadata tells a client the iss parameter will be there" do
    body = Jason.decode!(get_json("/.well-known/oauth-authorization-server").resp_body)

    assert body["authorization_response_iss_parameter_supported"] == true
  end

  ## Rate limits on the endpoints themselves

  test "the shipped budgets are per minute and per address, register the tightest" do
    limits = Vigil.OAuth.Endpoint.init([])[:limits]

    assert limits == %{authorize: 30, token: 30, register: 5}
  end

  test "registration past its budget is refused with an RFC 6749 error body" do
    budgets!(register: 2)

    body = %{client_name: "Test Client", redirect_uris: ["https://claude.ai/cb"]}

    assert post_json("/oauth/register", body).status == 201
    assert post_json("/oauth/register", body).status == 201

    conn = post_json("/oauth/register", body)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "temporarily_unavailable"
  end

  test "the token endpoint past its budget is refused with an RFC 6749 error body" do
    budgets!(token: 1)

    # Under budget the answer is the flow's own: an unknown code is a bad
    # grant. Over it, the endpoint answers before the flow is consulted.
    assert post_form("/oauth/token", %{"grant_type" => "authorization_code"}).status == 400

    conn = post_form("/oauth/token", %{"grant_type" => "authorization_code"})
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "temporarily_unavailable"
    # The wait is stated, so a client renewing reactively does not have to guess.
    assert get_resp_header(conn, "retry-after") == ["60"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "the consent page past its budget is refused as HTML, not as JSON" do
    budgets!(authorize: 1)
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    query =
      authorize_query(client["client_id"], "https://claude.ai/api/mcp/auth_callback", challenge)

    assert get_query("/oauth/authorize", query).status == 200

    conn = get_query("/oauth/authorize", query)
    assert conn.status == 429
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    # The same headers the rest of the HTML surface carries — a refusal is
    # still a page a browser renders.
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "a refused /authorize never reaches the CIMD fetch" do
    budgets!(authorize: 1)
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    # Spend the budget on a client that needs no fetch...
    spend =
      authorize_query(client["client_id"], "https://claude.ai/api/mcp/auth_callback", challenge)

    assert get_query("/oauth/authorize", spend).status == 200

    # ...then ask with an https client_id, which is the only input that sends
    # `Vigil.OAuth.Client.resolve/2` out to the network. 429 is the endpoint
    # refusing before it resolves anything; a fetch that had been attempted
    # would have failed and come back as 400 untrusted instead.
    conn =
      get_query(
        "/oauth/authorize",
        authorize_query(
          "https://cimd.invalid/metadata.json",
          "https://cimd.invalid/cb",
          challenge
        )
      )

    assert conn.status == 429
  end

  test "behind a trusted proxy the endpoint budgets are per forwarded client" do
    budgets!(register: 1)
    trust_proxy!("cf-connecting-ip", ["203.0.113.0/24"])

    body = %{client_name: "Test Client", redirect_uris: ["https://claude.ai/cb"]}

    assert register_as(body, {203, 0, 113, 7}, "198.51.100.9").status == 201
    assert register_as(body, {203, 0, 113, 7}, "198.51.100.9").status == 429

    # A different client through the same proxy still has its own budget.
    assert register_as(body, {203, 0, 113, 7}, "198.51.100.20").status == 201
  end

  defp register_as(body, peer, forwarded) do
    conn(:post, "/oauth/register", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("cf-connecting-ip", forwarded)
    |> Map.put(:remote_ip, peer)
    |> call()
  end

  # The budgets are arguments; these tests would otherwise have to spend the
  # production ones, thirty requests at a time.
  defp budgets!(overrides) do
    previous = [
      oauth_rate_limit_rpm: Application.get_env(:vigil, :oauth_rate_limit_rpm),
      oauth_register_rate_limit_rpm: Application.get_env(:vigil, :oauth_register_rate_limit_rpm)
    ]

    for {endpoint, budget} <- overrides do
      case endpoint do
        :register -> Application.put_env(:vigil, :oauth_register_rate_limit_rpm, budget)
        _ -> Application.put_env(:vigil, :oauth_rate_limit_rpm, budget)
      end
    end

    on_exit(fn -> restore_env(previous) end)
  end

  defp wrong_password_params do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    Map.merge(authorize_query(client["client_id"], redirect_uri, challenge), %{
      "password" => "falsch",
      "decision" => "allow"
    })
  end

  defp consent_as(params, peer, forwarded) do
    conn(:post, "/oauth/authorize", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("cf-connecting-ip", forwarded)
    |> Map.put(:remote_ip, peer)
    |> call()
  end

  defp trust_proxy!(header, cidrs) do
    previous = [
      trusted_proxy_header: Application.get_env(:vigil, :trusted_proxy_header),
      trusted_proxies: Application.get_env(:vigil, :trusted_proxies)
    ]

    Application.put_env(:vigil, :trusted_proxy_header, header)
    Application.put_env(:vigil, :trusted_proxies, cidrs)

    on_exit(fn -> restore_env(previous) end)
  end

  # A key that was unset has to be deleted again, not set to nil: an explicit
  # nil is a value, and `Application.get_env/3`'s default only covers absence.
  defp restore_env(previous) do
    for {k, v} <- previous do
      if is_nil(v), do: Application.delete_env(:vigil, k), else: Application.put_env(:vigil, k, v)
    end
  end

  ## Response headers on the HTML

  # The consent page is the only HTML vigil serves and the only place a human
  # types a password, so the headers on it are worth asserting rather than
  # hoping for.

  defp consent_page do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()

    get_query(
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

  test "the consent page denies by default and permits only what it uses" do
    conn = consent_page()
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

  test "the consent page carries the three headers a password form deserves" do
    conn = consent_page()

    assert header(conn, "x-content-type-options") == "nosniff"
    assert header(conn, "referrer-policy") == "no-referrer"
    # frame-ancestors covers modern clients; this covers the ones that predate it.
    assert header(conn, "x-frame-options") == "DENY"
  end

  test "the nonce in the policy is the nonce on the page, and is fresh each time" do
    conn = consent_page()

    [nonce] =
      Regex.run(~r/style-src 'nonce-([^']+)'/, header(conn, "content-security-policy"))
      |> tl()

    assert conn.resp_body =~ ~s(<style nonce="#{nonce}">)

    second = consent_page()

    [other] =
      Regex.run(~r/style-src 'nonce-([^']+)'/, header(second, "content-security-policy")) |> tl()

    refute other == nonce
  end

  test "the page renders no external asset and runs no script, as the policy claims" do
    # `default-src 'none'` is only honest while this stays true. The URLs in
    # the hidden fields are data, not asset references, so the check is for
    # the things that would actually load something.
    body = consent_page().resp_body

    refute body =~ "<script"
    refute body =~ "<link"
    refute body =~ "<img"
    refute body =~ "src="
    refute body =~ "url("
  end

  test "the error variant still renders and still carries the headers" do
    {201, client} = register(["https://claude.ai/api/mcp/auth_callback"])
    {_verifier, challenge} = pkce_pair()
    redirect_uri = "https://claude.ai/api/mcp/auth_callback"

    conn =
      post_form(
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

  test "the loopback-warning variant still renders and still carries the headers" do
    {201, client} = register(["http://localhost/callback"])
    {_verifier, challenge} = pkce_pair()

    conn =
      get_query(
        "/oauth/authorize",
        authorize_query(client["client_id"], "http://localhost:3118/callback", challenge)
      )

    assert conn.status == 200
    assert conn.resp_body =~ "loopback redirect address"

    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "x-content-type-options") == "nosniff"
    assert csp_directives(conn) |> Enum.member?("frame-ancestors 'none'")
  end

  test "the HTML error page refuses framing too, and needs no style-src" do
    conn = get_query("/oauth/authorize", authorize_query("nobody", "https://evil.tld/cb", "x"))

    assert conn.status == 400

    directives = csp_directives(conn)
    assert "default-src 'none'" in directives
    assert "frame-ancestors 'none'" in directives
    refute Enum.any?(directives, &String.starts_with?(&1, "style-src"))

    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "x-content-type-options") == "nosniff"
    assert header(conn, "referrer-policy") == "no-referrer"
  end

  ## Persistence

  test "a token survives an OAuth.Store restart against the same state dir", %{
    state_dir: state_dir
  } do
    token =
      OAuth.Token.issue_out_of_band(@resource, "vault", 3600, System.system_time(:second))

    stop_supervised!(Vigil.OAuth.Store)
    start_supervised!({Vigil.OAuth.Store, state_dir: state_dir})

    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-session-id", "persist-session")
      |> call()

    assert conn.status == 200
  end

  ## Janitor sweep (time injected, no sleeping)

  test "an expired code is gone after a sweep" do
    OAuth.Store.put_code("stale-code", %{
      client_id: "x",
      redirect_uri: "https://x/y",
      code_challenge: "y",
      resource: @resource,
      expires_at: System.system_time(:second) - 1
    })

    OAuth.Store.sweep_expired(System.system_time(:second))

    assert OAuth.Store.take_code("stale-code") == :error
  end

  ## CIMD SSRF guard (deterministic — a literal loopback IP needs no network access)

  test "a CIMD client_id resolving to a private IP is rejected" do
    assert OAuth.Cimd.fetch("https://127.0.0.1/client-metadata.json") == :error
  end
end
