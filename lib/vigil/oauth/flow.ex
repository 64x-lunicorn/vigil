defmodule Vigil.OAuth.Flow do
  @moduledoc """
  The OAuth 2.1 decisions, without a `Plug.Conn` in sight.

  Registration, the checks on an `/authorize` request, and both grants take
  plain parameter maps and return plain results; `Vigil.OAuth.Endpoint` is
  the only thing that knows how those become HTTP. Splitting it this way is
  what makes a PKCE or refresh-rotation question answerable without building
  a conn — and, before that, without starting a git-backed vault, because the
  whole flow used to live inside the MCP router.

  What a *record* is belongs next door. `Vigil.OAuth.Token` owns the token
  record: minting the pair a grant produces, telling access from refresh from
  replay, and answering whether a token is valid for a resource.
  `Vigil.OAuth.Code` owns the authorization-code record: minting one at
  consent, and answering whether the request presenting one may redeem it.
  What stays here is what to *say* about a verdict — every way a code can be
  wrong is one `invalid_grant` — and the checks that span both grants.
  Verification is an OAuth 2.1 decision like the ones here and just as free of
  a conn; it only used to live in the router because the record had no owner.

  Which authorization server these are decisions *for*, and where its records
  are kept, is nobody's decision here either — and it is one question rather
  than two. `authorize_request` and `consent` take a `Vigil.OAuth.Server`: the
  `Vigil.OAuth.Persistence` every record they read or write lives in, and the
  `Vigil.Settings` that names the audience a request may ask for and the
  password a consent is checked against. No caller has ever held one without
  the other, and in production `Vigil.OAuth.Endpoint` builds the pair once,
  when the router is initialized. `register` and `grant` ask the settings
  nothing, so they still take the persistence alone.
  """

  alias Vigil.OAuth
  alias Vigil.OAuth.{Cimd, Client, Code, RedirectUri, Server, Token}

  @doc """
  Dynamic client registration. Returns the registration response, or
  `{:error, "invalid_redirect_uri"}` when no usable redirect URI was offered.
  """
  def register(persistence, json, now \\ System.system_time(:second)) do
    redirect_uris = Map.get(json, "redirect_uris", [])

    if redirect_uris == [] or not Enum.all?(redirect_uris, &RedirectUri.valid_candidate?/1) do
      {:error, "invalid_redirect_uri"}
    else
      client =
        Client.register(
          persistence,
          Map.get(json, "client_name", "Unbenannter Client"),
          redirect_uris,
          now
        )

      {:ok,
       %{
         client_id: client.client_id,
         client_name: client.name,
         redirect_uris: client.redirect_uris,
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

  `now` and `net` reach `Vigil.OAuth.Client.resolve/4` from here, so a CIMD
  client can be driven through the whole authorization request with a test
  adapter and an injected time — the production values are the defaults, so
  `Vigil.OAuth.Endpoint` calling this with neither changes nothing.

  The audience the request was checked against travels on in `ctx`, so the
  code minted from it is minted for the resource this request was authorized
  for and `Vigil.OAuth.Code` has no second opinion to hold.
  """
  @spec authorize_request(Server.t(), map(), integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def authorize_request(
        %Server{persistence: persistence, settings: settings},
        params,
        now \\ System.system_time(:second),
        net \\ Cimd.net()
      ) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]

    with true <- is_binary(client_id) and client_id != "",
         true <- is_binary(redirect_uri) and redirect_uri != "",
         {:ok, client} <- Client.resolve(persistence, client_id, now, net),
         true <- RedirectUri.matches?(client.redirect_uris, redirect_uri) do
      authorize_details(params, settings, client, redirect_uri)
    else
      _ -> {:error, :untrusted}
    end
  end

  defp authorize_details(params, settings, client, redirect_uri) do
    state = params["state"]

    cond do
      params["response_type"] != "code" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      not is_binary(params["code_challenge"]) or params["code_challenge"] == "" ->
        {:error, {:redirect, redirect_uri, "invalid_request", state}}

      params["code_challenge_method"] != "S256" ->
        {:error, :bad_code_challenge_method}

      not (is_nil(params["resource"]) or params["resource"] == settings.resource) ->
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
           resource: settings.resource,
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
  @spec consent(Server.t(), String.t(), String.t() | nil, map(), integer()) ::
          :rate_limited | :wrong_password | {:ok, String.t()}
  def consent(
        %Server{persistence: persistence, settings: settings},
        ip,
        password,
        ctx,
        now \\ System.system_time(:second)
      ) do
    cond do
      persistence.rate_limited?.(ip, now) ->
        :rate_limited

      Plug.Crypto.secure_compare(password || "", settings.auth_password) ->
        persistence.reset_rate_limit.(ip)
        {:ok, Code.issue(persistence, ctx, now)}

      true ->
        persistence.record_failure.(ip, now)
        :wrong_password
    end
  end

  @doc """
  Redeems a token request. `{:ok, token_response}` or `{:error, status, code}`.

  Both grants are deliberately uniform about failure: every way an
  authorization code can be wrong reports `invalid_grant`, so a caller
  learns nothing from which check rejected it.
  """
  def grant(persistence, params, now \\ System.system_time(:second))

  def grant(persistence, %{"grant_type" => "authorization_code"} = params, now) do
    case Code.redeem(persistence, params["code"] || "", params, now) do
      # Unknown, expired, the wrong client, the wrong redirect URI, a verifier
      # that does not match the challenge — RFC 6749 §5.2 answers all five with
      # one code, so this renders every problem the same way rather than
      # matching them one by one and inviting a sixth to be told apart.
      {:error, _problem} ->
        {:error, 400, "invalid_grant"}

      {:ok, record} ->
        redeemed(persistence, record, params, now)
    end
  end

  def grant(persistence, %{"grant_type" => "refresh_token"} = params, now) do
    refresh_token = params["refresh_token"] || ""

    case Token.fetch_refresh(persistence, refresh_token) do
      # Order matters: a spent token is a replay before it is anything else.
      {:spent, data} -> replayed(persistence, data)
      {:ok, data} -> refresh(persistence, refresh_token, data, params, now)
      :error -> {:error, 400, "invalid_grant"}
    end
  end

  def grant(_persistence, _params, _now), do: {:error, 400, "unsupported_grant_type"}

  defp redeemed(persistence, record, params, now) do
    aud = Code.audience_of(record)

    if target_ok?(params, aud) do
      {:ok, Token.issue_pair(persistence, record, now)}
    else
      {:error, 400, "invalid_target"}
    end
  end

  defp refresh(persistence, refresh_token, data, params, now) do
    cond do
      Token.expired?(data, now) ->
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
        Token.spend_refresh(persistence, refresh_token, data, now)
        {:ok, Token.issue_pair(persistence, data, now)}
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
  defp replayed(persistence, data) do
    persistence.revoke_grant.(Token.grant_of(data))
    {:error, 400, "invalid_grant"}
  end

  defp target_ok?(params, expected) do
    is_nil(params["resource"]) or params["resource"] == expected
  end
end
