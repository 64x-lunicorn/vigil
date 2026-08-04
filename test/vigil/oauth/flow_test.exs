defmodule Vigil.OAuth.FlowTest do
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
    start_supervised!(Vigil.MCP.RateLimit)

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

  ## Persistence

  test "a token survives an OAuth.Store restart against the same state dir", %{
    state_dir: state_dir
  } do
    token = OAuth.Token.random()

    OAuth.Store.put_token(token, %{aud: @resource, expires_at: System.system_time(:second) + 3600})

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
