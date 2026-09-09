defmodule Vigil.OAuth.Endpoint do
  @moduledoc """
  The HTTP surface of the authorization server: discovery documents, dynamic
  client registration, the consent page and the token endpoint.

  It holds only the conn plumbing — reading bodies, rendering, redirecting.
  Every decision it makes is `Vigil.OAuth.Flow`'s.
  """
  use Plug.Router

  alias Vigil.OAuth
  alias Vigil.OAuth.{ConsentPage, Flow}

  plug(:match)
  plug(:dispatch)

  ## Discovery

  get "/.well-known/oauth-protected-resource" do
    send_json(conn, 200, OAuth.protected_resource_metadata())
  end

  get "/.well-known/oauth-protected-resource/mcp" do
    send_json(conn, 200, OAuth.protected_resource_metadata())
  end

  get "/.well-known/oauth-authorization-server" do
    send_json(conn, 200, OAuth.authorization_server_metadata())
  end

  ## Flow

  post "/oauth/register" do
    handle_register(conn)
  end

  get "/oauth/authorize" do
    conn = fetch_query_params(conn)
    with_authorize_request(conn, conn.query_params, &render_consent(&1, &2, nil))
  end

  post "/oauth/authorize" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)

    with_authorize_request(conn, params, &process_consent_decision(&1, &2, params))
  end

  post "/oauth/token" do
    handle_token(conn)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## Registration

  defp handle_register(conn) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, json} <- Jason.decode(body) do
      case Flow.register(json) do
        {:ok, registration} -> send_json(conn, 201, registration)
        {:error, error} -> send_json(conn, 400, %{error: error})
      end
    else
      _ -> send_json(conn, 400, %{error: "invalid_request"})
    end
  end

  ## Authorization

  defp with_authorize_request(conn, params, on_ok) do
    case Flow.authorize_request(params) do
      {:ok, ctx} ->
        on_ok.(conn, ctx)

      {:error, :untrusted} ->
        send_html(conn, 400, error_html("Invalid client_id or redirect_uri."))

      {:error, :bad_code_challenge_method} ->
        send_html(conn, 400, error_html("code_challenge_method must be S256."))

      {:error, {:redirect, redirect_uri, error_code, state}} ->
        redirect_with_error(conn, redirect_uri, error_code, state)
    end
  end

  defp process_consent_decision(conn, ctx, params) do
    case params["decision"] do
      "deny" -> redirect_with_error(conn, ctx.redirect_uri, "access_denied", ctx.state)
      "allow" -> process_allow(conn, ctx, params)
      _ -> send_html(conn, 400, error_html("Invalid request."))
    end
  end

  defp process_allow(conn, ctx, params) do
    case Flow.consent(client_ip(conn), params["password"], ctx) do
      {:ok, code} ->
        redirect_with_query(conn, ctx.redirect_uri, put_state(%{"code" => code}, ctx.state))

      :wrong_password ->
        render_consent(conn, ctx, "Wrong password.")

      :rate_limited ->
        send_resp(conn, 429, "")
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
      "resource" => OAuth.resource(),
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

  ## Token

  defp handle_token(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Flow.grant(params) do
      {:ok, tokens} -> send_json(conn, 200, tokens)
      {:error, status, error} -> send_json(conn, status, %{error: error})
    end
  end

  ## Conn plumbing

  defp redirect_with_error(conn, redirect_uri, error_code, state) do
    redirect_with_query(conn, redirect_uri, put_state(%{"error" => error_code}, state))
  end

  defp redirect_with_query(conn, redirect_uri, query) do
    separator = if String.contains?(redirect_uri, "?"), do: "&", else: "?"

    conn
    |> put_resp_header("location", redirect_uri <> separator <> URI.encode_query(query))
    |> send_resp(302, "")
  end

  defp put_state(query, nil), do: query
  defp put_state(query, ""), do: query
  defp put_state(query, state), do: Map.put(query, "state", state)

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> List.to_string()

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
end
