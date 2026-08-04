defmodule Vigil.MCP.Server do
  @moduledoc false
  use Plug.Router
  require Logger

  alias Vigil.MCP.{Tools, Envelope, RateLimit}
  alias Vigil.Store
  alias Vigil.OAuth
  alias Vigil.OAuth.{Client, RedirectUri, ConsentPage, Token}

  @protocol_version "2025-11-25"
  @scope "vault"
  @read_scope "vault:read"

  plug(:match)
  plug(:dispatch)

  ## Routes — MCP

  post "/mcp" do
    handle_mcp(conn)
  end

  get "/mcp" do
    send_resp(conn, 405, "")
  end

  delete "/mcp" do
    send_resp(conn, 405, "")
  end

  ## Routes — OAuth discovery

  get "/.well-known/oauth-protected-resource" do
    send_json(conn, 200, protected_resource_metadata())
  end

  get "/.well-known/oauth-protected-resource/mcp" do
    send_json(conn, 200, protected_resource_metadata())
  end

  get "/.well-known/oauth-authorization-server" do
    send_json(conn, 200, authorization_server_metadata())
  end

  ## Routes — OAuth flow

  post "/oauth/register" do
    handle_register(conn)
  end

  get "/oauth/authorize" do
    handle_authorize_get(conn)
  end

  post "/oauth/authorize" do
    handle_authorize_post(conn)
  end

  post "/oauth/token" do
    handle_token(conn)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## MCP handling

  defp handle_mcp(conn) do
    case validate_access_token(conn) do
      {:ok, scope, token} ->
        if RateLimit.limited?(token) do
          send_resp(conn, 429, "")
        else
          handle_mcp_authenticated(conn, scope)
        end

      {:error, :challenge} ->
        send_401_challenge(conn)
    end
  end

  defp validate_access_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case check_access_token(token) do
          {:ok, scope} -> {:ok, scope, token}
          {:error, :challenge} -> {:error, :challenge}
        end

      _ ->
        {:error, :challenge}
    end
  end

  defp check_access_token(token) do
    case OAuth.Store.get_token(token) do
      :error ->
        {:error, :challenge}

      {:ok, %{type: :refresh}} ->
        {:error, :challenge}

      {:ok, record} ->
        now = System.system_time(:second)

        cond do
          record.expires_at <= now ->
            OAuth.Store.delete_token(token)
            {:error, :challenge}

          not Plug.Crypto.secure_compare(record.aud, resource()) ->
            {:error, :challenge}

          true ->
            {:ok, Map.get(record, :scope, @scope)}
        end
    end
  end

  defp send_401_challenge(conn) do
    challenge =
      "Bearer resource_metadata=\"#{issuer()}/.well-known/oauth-protected-resource\", scope=\"#{@scope}\""

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> send_resp(401, "")
  end

  defp handle_mcp_authenticated(conn, scope) do
    with {:ok, protocol_version_ok?, conn} <- check_protocol_version(conn),
         true <- protocol_version_ok?,
         {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, msg} <- Jason.decode(body) do
      handle_message(conn, msg, scope)
    else
      false ->
        send_resp(conn, 400, "")

      {:error, %Jason.DecodeError{}} ->
        send_json(conn, 200, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32700, message: "Parse error"}
        })

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> {:ok, true, conn}
      [@protocol_version] -> {:ok, true, conn}
      [_other] -> {:ok, false, conn}
    end
  end

  defp handle_message(conn, %{"method" => "initialize"} = msg, _scope) do
    session_id = Vigil.Uuid.v4()

    result = %{
      protocolVersion: @protocol_version,
      serverInfo: %{name: "vigil", version: Application.spec(:vigil, :vsn) |> to_string()},
      capabilities: %{tools: %{}},
      instructions: instructions_text()
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> send_json(200, %{jsonrpc: "2.0", id: msg["id"], result: result})
  end

  defp handle_message(conn, %{"method" => "notifications/initialized"}, _scope) do
    send_resp(conn, 202, "")
  end

  defp handle_message(conn, %{"method" => "ping"} = msg, _scope) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/list"} = msg, _scope) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{tools: Tools.definitions()}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/call"} = msg, scope) do
    with_session(conn, fn session_id ->
      params = msg["params"] || %{}
      name = params["name"]
      arguments = params["arguments"] || %{}

      Logger.info("mcp tool_call tool=#{name} session=#{session_id}")

      result =
        if scope == @read_scope and Tools.write_tool?(name) do
          {:error, "Read-only token: write access denied."}
        else
          Tools.dispatch(name, arguments)
        end

      body = build_tool_call_result(name, result, session_id)
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: body})
    end)
  end

  defp handle_message(conn, msg, _scope) do
    if Map.has_key?(msg, "id") do
      send_json(conn, 200, %{
        jsonrpc: "2.0",
        id: msg["id"],
        error: %{code: -32601, message: "Method not found"}
      })
    else
      send_resp(conn, 202, "")
    end
  end

  defp with_session(conn, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] when session_id != "" -> fun.(session_id)
      _ -> send_resp(conn, 400, "")
    end
  end

  defp build_tool_call_result(name, {:ok, value}, session_id) do
    envelope = envelope_for(name, session_id)
    text = Jason.encode!(Map.merge(%{result: value}, envelope))
    %{content: [%{type: "text", text: text}]}
  end

  defp build_tool_call_result(_name, {:error, message}, _session_id) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  defp envelope_for("current", session_id), do: Envelope.for_current(session_id)
  defp envelope_for(_name, session_id), do: Envelope.for_call(session_id)

  # Sent to the client on `initialize`. These are writing rules for the vault,
  # not rules for this server, which is why the two things they depend on —
  # who the vault belongs to and which language it is written in — come from
  # configuration rather than being hardcoded. `VIGIL_VAULT_LANGUAGE` governs
  # the language of the *notes*; the server itself always speaks English.
  defp base_instructions do
    owner = Application.get_env(:vigil, :vault_owner, "the vault owner")
    language = Application.get_env(:vigil, :vault_language, "English")

    """
    Voice: use #{owner}'s own phrasing verbatim, do not smooth it out. What they
    said, in their words — when in doubt quote more rawly rather than summarize
    more elegantly. Mark your own interpretations and suggestions explicitly as
    such ("Suggestion from Claude: …"). In five years the vault must still sound
    like #{owner}, not like Claude.

    Language: write notes and headings in #{language}. Established technical
    terms stay in the language they are normally used in; do not translate them
    in either direction.

    Atomicity: every section must stand on its own — it gets retrieved
    individually. No "as mentioned above", no pronouns pointing outside the
    section.

    Frugality: always search before create. Prefer appending to something that
    exists over adding a new note. Do not write summaries of things the vault
    already contains.

    type: reference = a fact about the world (does not age). decision = a fact
    about #{owner} (ages). event = has starts/ends. When in doubt, decision.

    Skills: call skill_write only when explicitly told to. Never create or
    change skills on your own initiative, not even when it seems obvious.
    Skills are instructions to Claude; writing them is #{owner}'s decision, not
    Claude's.
    """
  end

  defp instructions_text do
    base_instructions() <>
      "\n\n## Domains (_domains.yml)\n\n```yaml\n" <> Store.instructions_domains_text() <> "\n```"
  end

  ## OAuth discovery documents

  defp protected_resource_metadata do
    %{
      resource: resource(),
      authorization_servers: [issuer()],
      scopes_supported: [@scope, @read_scope],
      bearer_methods_supported: ["header"]
    }
  end

  defp authorization_server_metadata do
    %{
      issuer: issuer(),
      authorization_endpoint: issuer() <> "/oauth/authorize",
      token_endpoint: issuer() <> "/oauth/token",
      registration_endpoint: issuer() <> "/oauth/register",
      scopes_supported: [@scope, @read_scope],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      client_id_metadata_document_supported: true
    }
  end

  ## OAuth — DCR

  defp handle_register(conn) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, json} <- Jason.decode(body) do
      redirect_uris = Map.get(json, "redirect_uris", [])

      if redirect_uris == [] or not Enum.all?(redirect_uris, &RedirectUri.valid_candidate?/1) do
        send_json(conn, 400, %{error: "invalid_redirect_uri"})
      else
        client_id = Vigil.Uuid.v4()
        now = System.system_time(:second)
        name = Map.get(json, "client_name", "Unbenannter Client")

        OAuth.Store.put_client(client_id, %{
          name: name,
          redirect_uris: redirect_uris,
          issued_at: now
        })

        send_json(conn, 201, %{
          client_id: client_id,
          client_name: name,
          redirect_uris: redirect_uris,
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          client_id_issued_at: now
        })
      end
    else
      _ -> send_json(conn, 400, %{error: "invalid_request"})
    end
  end

  ## OAuth — /authorize

  defp handle_authorize_get(conn) do
    conn = fetch_query_params(conn)

    case validate_authorize_params(conn.query_params) do
      {:ok, ctx} ->
        render_consent(conn, ctx, nil)

      {:error, :untrusted} ->
        send_html(conn, 400, error_html("Invalid client_id or redirect_uri."))

      {:error, :bad_code_challenge_method} ->
        send_html(conn, 400, error_html("code_challenge_method must be S256."))

      {:error, {:redirect, redirect_uri, error_code, state}} ->
        redirect_with_error(conn, redirect_uri, error_code, state)
    end
  end

  defp handle_authorize_post(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)

    case validate_authorize_params(params) do
      {:ok, ctx} ->
        process_consent_decision(conn, ctx, params)

      {:error, :untrusted} ->
        send_html(conn, 400, error_html("Invalid client_id or redirect_uri."))

      {:error, :bad_code_challenge_method} ->
        send_html(conn, 400, error_html("code_challenge_method must be S256."))

      {:error, {:redirect, redirect_uri, error_code, state}} ->
        redirect_with_error(conn, redirect_uri, error_code, state)
    end
  end

  defp validate_authorize_params(params) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]

    with true <- is_binary(client_id) and client_id != "",
         true <- is_binary(redirect_uri) and redirect_uri != "",
         {:ok, client} <- Client.resolve(client_id),
         true <- RedirectUri.matches?(client.redirect_uris, redirect_uri) do
      validate_authorize_rest(params, client, redirect_uri)
    else
      _ -> {:error, :untrusted}
    end
  end

  defp validate_authorize_rest(params, client, redirect_uri) do
    state = params["state"]

    cond do
      params["response_type"] != "code" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      not is_binary(params["code_challenge"]) or params["code_challenge"] == "" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      params["code_challenge_method"] != "S256" ->
        {:error, :bad_code_challenge_method}

      not (is_nil(params["resource"]) or params["resource"] == resource()) ->
        {:error, {:redirect, redirect_uri, "invalid_target", state}}

      params["scope"] not in [nil, "", @scope, @read_scope] ->
        {:error, {:redirect, redirect_uri, "invalid_scope", state}}

      true ->
        {:ok,
         %{
           client: client,
           redirect_uri: redirect_uri,
           code_challenge: params["code_challenge"],
           state: state,
           scope: params["scope"] || @scope
         }}
    end
  end

  defp render_consent(conn, ctx, error_message) do
    hidden = %{
      "response_type" => "code",
      "client_id" => ctx.client.client_id,
      "redirect_uri" => ctx.redirect_uri,
      "code_challenge" => ctx.code_challenge,
      "code_challenge_method" => "S256",
      "state" => ctx.state || "",
      "resource" => resource(),
      "scope" => ctx.scope
    }

    html =
      ConsentPage.render(%{
        client_name: ctx.client.name,
        redirect_uri: ctx.redirect_uri,
        hidden_fields: hidden,
        error: error_message
      })

    send_html(conn, 200, html)
  end

  defp process_consent_decision(conn, ctx, params) do
    case params["decision"] do
      "deny" -> redirect_with_error(conn, ctx.redirect_uri, "access_denied", ctx.state)
      "allow" -> process_allow(conn, ctx, params)
      _ -> send_html(conn, 400, error_html("Invalid request."))
    end
  end

  defp process_allow(conn, ctx, params) do
    ip = client_ip(conn)
    now = System.system_time(:second)

    if OAuth.Store.rate_limited?(ip, now) do
      send_resp(conn, 429, "")
    else
      password = params["password"] || ""

      if Plug.Crypto.secure_compare(password, auth_password()) do
        OAuth.Store.reset_rate_limit(ip)
        issue_authorization_code(conn, ctx, now)
      else
        OAuth.Store.record_failure(ip, now)
        render_consent(conn, ctx, "Wrong password.")
      end
    end
  end

  defp issue_authorization_code(conn, ctx, now) do
    code = Token.random()

    OAuth.Store.put_code(code, %{
      client_id: ctx.client.client_id,
      redirect_uri: ctx.redirect_uri,
      code_challenge: ctx.code_challenge,
      resource: resource(),
      scope: ctx.scope,
      expires_at: now + 60
    })

    redirect_with_query(conn, ctx.redirect_uri, maybe_put_state(%{"code" => code}, ctx.state))
  end

  defp redirect_with_error(conn, redirect_uri, error_code, state) do
    redirect_with_query(conn, redirect_uri, maybe_put_state(%{"error" => error_code}, state))
  end

  defp redirect_with_query(conn, redirect_uri, query) do
    separator = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
    location = redirect_uri <> separator <> URI.encode_query(query)

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp maybe_put_state(query, nil), do: query
  defp maybe_put_state(query, ""), do: query
  defp maybe_put_state(query, state), do: Map.put(query, "state", state)

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> List.to_string()
  end

  ## OAuth — /token

  defp handle_token(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    conn = put_resp_header(conn, "cache-control", "no-store")

    case params["grant_type"] do
      "authorization_code" -> handle_auth_code_grant(conn, params)
      "refresh_token" -> handle_refresh_grant(conn, params)
      _ -> oauth_error(conn, 400, "unsupported_grant_type")
    end
  end

  defp handle_auth_code_grant(conn, params) do
    code = params["code"] || ""

    case OAuth.Store.take_code(code) do
      :error ->
        oauth_error(conn, 400, "invalid_grant")

      {:ok, data} ->
        now = System.system_time(:second)

        cond do
          data.expires_at <= now ->
            oauth_error(conn, 400, "invalid_grant")

          data.client_id != params["client_id"] ->
            oauth_error(conn, 400, "invalid_grant")

          data.redirect_uri != params["redirect_uri"] ->
            oauth_error(conn, 400, "invalid_grant")

          not Token.pkce_valid?(params["code_verifier"] || "", data.code_challenge) ->
            oauth_error(conn, 400, "invalid_grant")

          not is_nil(params["resource"]) and params["resource"] != data.resource ->
            oauth_error(conn, 400, "invalid_target")

          true ->
            issue_tokens(conn, data.client_id, data.resource, Map.get(data, :scope, @scope))
        end
    end
  end

  defp handle_refresh_grant(conn, params) do
    refresh_token = params["refresh_token"] || ""
    now = System.system_time(:second)

    case OAuth.Store.get_token(refresh_token) do
      {:ok, %{type: :refresh} = data} ->
        cond do
          data.expires_at <= now ->
            oauth_error(conn, 400, "invalid_grant")

          data.client_id != params["client_id"] ->
            oauth_error(conn, 400, "invalid_grant")

          not is_nil(params["resource"]) and params["resource"] != data.aud ->
            oauth_error(conn, 400, "invalid_target")

          true ->
            OAuth.Store.delete_token(refresh_token)
            issue_tokens(conn, data.client_id, data.aud, Map.get(data, :scope, @scope))
        end

      _ ->
        oauth_error(conn, 400, "invalid_grant")
    end
  end

  defp issue_tokens(conn, client_id, aud, scope) do
    now = System.system_time(:second)
    access_token = Token.random()
    refresh_token = Token.random()

    OAuth.Store.put_token(access_token, %{aud: aud, scope: scope, expires_at: now + 3600})

    OAuth.Store.put_token(refresh_token, %{
      type: :refresh,
      client_id: client_id,
      aud: aud,
      scope: scope,
      expires_at: now + 30 * 86_400
    })

    send_json(conn, 200, %{
      access_token: access_token,
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: refresh_token,
      scope: scope
    })
  end

  defp oauth_error(conn, status, error) do
    send_json(conn, status, %{error: error})
  end

  ## shared helpers

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp send_html(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp error_html(message) do
    "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>vigil — error</title></head>" <>
      "<body><h1>Error</h1><p>#{Plug.HTML.html_escape(message)}</p></body></html>"
  end

  defp issuer, do: Application.fetch_env!(:vigil, :issuer)
  defp resource, do: Application.fetch_env!(:vigil, :resource)
  defp auth_password, do: Application.fetch_env!(:vigil, :auth_password)
end
