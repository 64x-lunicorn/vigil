defmodule Vigil.OAuth.Endpoint do
  @moduledoc """
  The HTTP surface of the authorization server: discovery documents, dynamic
  client registration, the consent page and the token endpoint.

  It holds only the conn plumbing — reading bodies, rendering, redirecting.
  Every decision it makes is `Vigil.OAuth.Flow`'s.
  """
  use Plug.Router

  alias Vigil.OAuth
  alias Vigil.OAuth.{ClientAddr, ConsentPage, Flow}
  alias Vigil.RateLimit

  @default_rpm 30
  @default_register_rpm 5

  plug(:match)
  plug(:dispatch)

  # Resolves what the deployment says about its proxy and its budgets once,
  # when the router is initialized, rather than re-parsing a CIDR list and
  # re-reading application config on every request.
  @impl true
  def init(opts) do
    opts
    |> Keyword.put_new_lazy(:client_addr, &ClientAddr.config/0)
    |> Keyword.put_new_lazy(:limits, &configured_limits/0)
  end

  @impl true
  def call(conn, opts) do
    conn
    |> put_private(:vigil_client_addr, opts[:client_addr] || ClientAddr.config())
    |> put_private(:vigil_limits, opts[:limits] || configured_limits())
    |> super(opts)
  end

  defp configured_limits do
    rpm = budget(:oauth_rate_limit_rpm, @default_rpm)

    %{
      authorize: rpm,
      token: rpm,
      register: budget(:oauth_register_rate_limit_rpm, @default_register_rpm)
    }
  end

  # A budget that is not a positive number is not a budget. Falling back to the
  # default keeps a mistyped environment variable from producing a limit that
  # either refuses everything or crashes on the comparison.
  defp budget(key, default) do
    case Application.get_env(:vigil, key, default) do
      rpm when is_integer(rpm) and rpm > 0 -> rpm
      _ -> default
    end
  end

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
    under_limit(conn, :register, &handle_register/1)
  end

  get "/oauth/authorize" do
    under_limit(conn, :authorize, fn conn ->
      conn = fetch_query_params(conn)
      with_authorize_request(conn, conn.query_params, &render_consent(&1, &2, nil))
    end)
  end

  post "/oauth/authorize" do
    under_limit(conn, :authorize, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      with_authorize_request(conn, params, &process_consent_decision(&1, &2, params))
    end)
  end

  post "/oauth/token" do
    under_limit(conn, :token, &handle_token/1)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  ## Rate limits

  @doc false
  # Every endpoint here is reachable without a token, so this is the only thing
  # bounding what an unauthenticated caller can make vigil do: fetch a CIMD
  # document from an address it chose, write a `:dets` row and fsync it, or ask
  # the token endpoint to answer a guess. Cloudflare Access is what keeps that
  # from being reachable on the deployment `docs/guide.md` describes; this is
  # the defence behind it.
  #
  # It runs before the handler rather than inside it, so the refusal costs
  # nothing that the request was trying to buy — in particular `/authorize`
  # refuses before `Vigil.OAuth.Client.resolve/2` can go out to the network.
  #
  # A refusal takes the shape of the surface it refuses: the consent page is
  # HTML a browser renders, and the other two are read by a program.
  defp under_limit(conn, endpoint, handler) do
    budget = Map.fetch!(conn.private.vigil_limits, endpoint)
    key = {:oauth, endpoint, ClientAddr.of(conn, conn.private.vigil_client_addr)}

    if RateLimit.limited?(key, budget, System.system_time(:second)) do
      refuse(conn, endpoint)
    else
      handler.(conn)
    end
  end

  defp refuse(conn, :authorize) do
    send_html(conn, 429, error_html("Too many requests. Try again in a minute."))
  end

  defp refuse(conn, _endpoint) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_json(429, %{error: "temporarily_unavailable"})
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

    nonce = ConsentPage.nonce()

    html =
      ConsentPage.render(%{
        client_name: ctx.client.name,
        redirect_uri: ctx.redirect_uri,
        hidden_fields: hidden,
        error: error_message,
        nonce: nonce
      })

    send_html(conn, 200, html, nonce)
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

  # Which address the consent limit is counted against. `Vigil.OAuth.ClientAddr`
  # owns the decision; this only says where the configuration was put.
  defp client_ip(conn), do: ClientAddr.of(conn, conn.private.vigil_client_addr)

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp send_html(conn, status, html, nonce \\ nil) do
    conn
    |> put_resp_content_type("text/html")
    |> merge_resp_headers(html_security_headers(nonce))
    |> send_resp(status, html)
  end

  @doc """
  The response headers for the HTML vigil serves.

  The consent page is the only HTML here and the only place a human types a
  password, and it is unusually cheap to lock down: no template directory, no
  assets, no JavaScript, and a single inline `<style>` block. So the policy
  denies everything and permits exactly that one block, by nonce rather than
  by `'unsafe-inline'` — an injected `<style>` without the nonce does not run.
  Pass `nil` for the error page, which has no style at all.

  What each one buys:

    * `frame-ancestors 'none'`, with `X-Frame-Options: DENY` for clients that
      predate it, stops the page being framed. An attacker who frames it
      cannot steer a click onto Allow.
    * `Referrer-Policy: no-referrer` stops the URL leaking. The consent page's
      URL carries `client_id`, `redirect_uri`, `state` and `code_challenge`.
    * `X-Content-Type-Options: nosniff` and `default-src 'none'` close the
      distance between "renders no external assets today" and "renders no
      external assets".
    * `base-uri 'none'` keeps an injected `<base>` from re-pointing the one
      relative URL on the page, the form's own action.

  Deliberately absent: `form-action 'self'`. The password POST does land on
  this origin, but its answer is a 302 to the client's `redirect_uri`, which is
  another origin by definition — and whether `form-action` applies to a
  redirect *after* a submission is, in MDN's words, "debated and browser
  implementations of this aspect are inconsistent (e.g., Firefox 57 doesn't
  block the redirects whereas Chrome 63 does)". So the directive can break the
  Allow button in the more likely browser, and it guards nothing here: the
  form's action is a literal in the template with nowhere for input to reach
  it. A `Plug.Test` assertion cannot see this failure either, since it only
  ever observes the 302.

  The nonce half lives on `Vigil.OAuth.ConsentPage`, which both mints the value
  and stamps it on its `<style>` tag; this function only names it.
  """
  def html_security_headers(nonce) do
    [
      {"content-security-policy", content_security_policy(nonce)},
      {"x-frame-options", "DENY"},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"}
    ]
  end

  defp content_security_policy(nil), do: base_policy()
  defp content_security_policy(nonce), do: base_policy() <> "; style-src 'nonce-#{nonce}'"

  defp base_policy, do: "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"

  defp error_html(message) do
    "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>vigil — error</title></head>" <>
      "<body><h1>Error</h1><p>#{Plug.HTML.html_escape(message)}</p></body></html>"
  end
end
