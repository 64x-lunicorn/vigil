defmodule Vigil.OAuth.Flow do
  @moduledoc """
  The OAuth 2.1 decisions, without a `Plug.Conn` in sight.

  Registration, the checks on an `/authorize` request, and both grants take
  plain parameter maps and return plain results; `Vigil.OAuth.Endpoint` is
  the only thing that knows how those become HTTP. Splitting it this way is
  what makes a PKCE or refresh-rotation question answerable without building
  a conn — and, before that, without starting a git-backed vault, because the
  whole flow used to live inside the MCP router.
  """

  alias Vigil.OAuth
  alias Vigil.OAuth.{Client, RedirectUri, Store, Token}

  @access_token_ttl 3600
  @refresh_token_ttl 30 * 86_400
  @authorization_code_ttl 60

  @doc """
  Dynamic client registration. Returns the registration response, or
  `{:error, "invalid_redirect_uri"}` when no usable redirect URI was offered.
  """
  def register(json, now \\ System.system_time(:second)) do
    redirect_uris = Map.get(json, "redirect_uris", [])

    if redirect_uris == [] or not Enum.all?(redirect_uris, &RedirectUri.valid_candidate?/1) do
      {:error, "invalid_redirect_uri"}
    else
      client_id = Vigil.Uuid.v4()
      name = Map.get(json, "client_name", "Unbenannter Client")

      Store.put_client(client_id, %{name: name, redirect_uris: redirect_uris, issued_at: now})

      {:ok,
       %{
         client_id: client_id,
         client_name: name,
         redirect_uris: redirect_uris,
         grant_types: ["authorization_code", "refresh_token"],
         response_types: ["code"],
         token_endpoint_auth_method: "none",
         client_id_issued_at: now
       }}
    end
  end

  @doc """
  Checks an `/authorize` request.

  `{:ok, ctx}` carries everything the consent page and the code need. The
  three failure shapes are distinct because they are answered differently: an
  untrusted client or redirect URI must never be redirected to, a bad
  `code_challenge_method` is a local error page, and everything else is
  reported back to the client as a redirect.
  """
  def authorize_request(params) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]

    with true <- is_binary(client_id) and client_id != "",
         true <- is_binary(redirect_uri) and redirect_uri != "",
         {:ok, client} <- Client.resolve(client_id),
         true <- RedirectUri.matches?(client.redirect_uris, redirect_uri) do
      authorize_details(params, client, redirect_uri)
    else
      _ -> {:error, :untrusted}
    end
  end

  defp authorize_details(params, client, redirect_uri) do
    state = params["state"]

    cond do
      params["response_type"] != "code" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      not is_binary(params["code_challenge"]) or params["code_challenge"] == "" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      params["code_challenge_method"] != "S256" ->
        {:error, :bad_code_challenge_method}

      not (is_nil(params["resource"]) or params["resource"] == OAuth.resource()) ->
        {:error, {:redirect, redirect_uri, "invalid_target", state}}

      params["scope"] not in [nil, "", OAuth.scope(), OAuth.read_scope()] ->
        {:error, {:redirect, redirect_uri, "invalid_scope", state}}

      true ->
        {:ok,
         %{
           client: client,
           redirect_uri: redirect_uri,
           code_challenge: params["code_challenge"],
           state: state,
           scope: params["scope"] || OAuth.scope()
         }}
    end
  end

  @doc """
  Decides an "allow" on the consent page for a client at `ip`.

  `:rate_limited` once too many wrong passwords have come from that address,
  `:wrong_password` otherwise, and `{:ok, code}` with a fresh one-time
  authorization code when the password is right. Recording the attempt is part
  of the decision, so the caller cannot forget to.
  """
  def consent(ip, password, ctx, now \\ System.system_time(:second)) do
    cond do
      Store.rate_limited?(ip, now) ->
        :rate_limited

      Plug.Crypto.secure_compare(password || "", OAuth.auth_password()) ->
        Store.reset_rate_limit(ip)
        {:ok, issue_authorization_code(ctx, now)}

      true ->
        Store.record_failure(ip, now)
        :wrong_password
    end
  end

  @doc "Mints a one-time authorization code for an approved consent, and returns it."
  def issue_authorization_code(ctx, now \\ System.system_time(:second)) do
    code = Token.random()

    Store.put_code(code, %{
      client_id: ctx.client.client_id,
      redirect_uri: ctx.redirect_uri,
      code_challenge: ctx.code_challenge,
      resource: OAuth.resource(),
      scope: ctx.scope,
      # The authorization grant this code, and every token redeemed from it,
      # belongs to. It is what "revoke the whole family" is expressed in.
      grant_id: Vigil.Uuid.v4(),
      expires_at: now + @authorization_code_ttl
    })

    code
  end

  @doc """
  Redeems a token request. `{:ok, token_response}` or `{:error, status, code}`.

  Both grants are deliberately uniform about failure: every way an
  authorization code can be wrong reports `invalid_grant`, so a caller
  learns nothing from which check rejected it.
  """
  def grant(params, now \\ System.system_time(:second))

  def grant(%{"grant_type" => "authorization_code"} = params, now) do
    case Store.take_code(params["code"] || "") do
      :error ->
        {:error, 400, "invalid_grant"}

      {:ok, data} ->
        cond do
          data.expires_at <= now ->
            {:error, 400, "invalid_grant"}

          data.client_id != params["client_id"] ->
            {:error, 400, "invalid_grant"}

          data.redirect_uri != params["redirect_uri"] ->
            {:error, 400, "invalid_grant"}

          not pkce_ok?(params, data) ->
            {:error, 400, "invalid_grant"}

          not target_ok?(params, data.resource) ->
            {:error, 400, "invalid_target"}

          true ->
            {:ok,
             issue_tokens(
               data.client_id,
               data.resource,
               scope_of(data),
               grant_for_issue(data),
               now
             )}
        end
    end
  end

  def grant(%{"grant_type" => "refresh_token"} = params, now) do
    refresh_token = params["refresh_token"] || ""

    case Store.get_token(refresh_token) do
      # Order matters: a spent token is a replay before it is anything else.
      {:ok, %{type: :refresh, spent_at: _} = data} -> replayed(data)
      {:ok, %{type: :refresh} = data} -> refresh(refresh_token, data, params, now)
      _ -> {:error, 400, "invalid_grant"}
    end
  end

  def grant(_params, _now), do: {:error, 400, "unsupported_grant_type"}

  defp refresh(refresh_token, data, params, now) do
    cond do
      data.expires_at <= now ->
        {:error, 400, "invalid_grant"}

      data.client_id != params["client_id"] ->
        {:error, 400, "invalid_grant"}

      not target_ok?(params, data.aud) ->
        {:error, 400, "invalid_target"}

      true ->
        # Rotation: the presented token is spent before the new pair is minted,
        # so a replay is refused — and, because it is marked rather than
        # deleted, recognised as a replay rather than mistaken for a token that
        # never existed.
        Store.spend_token(refresh_token, data, now)
        {:ok, issue_tokens(data.client_id, data.aud, scope_of(data), grant_for_issue(data), now)}
    end
  end

  # A refresh token presented after it was rotated away. RFC 9700 §4.14.2:
  # "If a refresh token is compromised and subsequently used by both the
  # attacker and the legitimate client, one of them will present an
  # invalidated refresh token", and the authorization server "will revoke the
  # active refresh token" — which stops the attack "at the cost of forcing the
  # legitimate client to obtain a fresh authorization grant".
  #
  # vigil cannot tell which of the two holders replayed, so the whole grant
  # goes: every access and refresh token descended from the same authorization.
  # The answer is `invalid_grant` either way, identical to an unknown token, so
  # the caller does not learn that a family was found.
  #
  # No other check runs first. Presenting a spent token *is* the signal, and an
  # attacker who knows the token but not the `client_id` should not be able to
  # keep the family alive by getting the rest of the request wrong.
  defp replayed(data) do
    Store.revoke_grant(Map.get(data, :grant_id))
    {:error, 400, "invalid_grant"}
  end

  defp pkce_ok?(params, data) do
    Token.pkce_valid?(params["code_verifier"] || "", data.code_challenge)
  end

  defp target_ok?(params, expected) do
    is_nil(params["resource"]) or params["resource"] == expected
  end

  defp scope_of(data), do: Map.get(data, :scope, OAuth.scope())

  # The grant a newly issued pair belongs to. A code or refresh token minted
  # before grants existed carries none, and minting one here keeps the
  # invariant unconditional: every token issued from now on belongs to a family
  # that can be revoked. Note this is only right for *issuing* — revoking a
  # grant that does not exist has to stay a no-op, so `replayed/1` reads the
  # field directly rather than through this.
  defp grant_for_issue(data), do: Map.get(data, :grant_id) || Vigil.Uuid.v4()

  defp issue_tokens(client_id, aud, scope, grant_id, now) do
    access_token = Token.random()
    refresh_token = Token.random()

    Store.put_token(access_token, %{
      grant_id: grant_id,
      aud: aud,
      scope: scope,
      expires_at: now + @access_token_ttl
    })

    Store.put_token(refresh_token, %{
      type: :refresh,
      grant_id: grant_id,
      client_id: client_id,
      aud: aud,
      scope: scope,
      expires_at: now + @refresh_token_ttl
    })

    %{
      access_token: access_token,
      token_type: "Bearer",
      expires_in: @access_token_ttl,
      refresh_token: refresh_token,
      scope: scope
    }
  end
end
