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

  require Logger

  alias Vigil.OAuth
  alias Vigil.OAuth.{Cimd, Client, Code, Persistence, RedirectUri, Server, Token}

  # What one registration may store (`docs/oauth.md`, "Client registration").
  # Generous for any client that exists — claude.ai registers one redirect URI
  # and a short name — and small enough that `Vigil.OAuth.Client.max_clients/0`
  # records stay a few megabytes on the disk that also holds the vault.
  @max_client_name 200
  @max_redirect_uris 10
  @max_redirect_uri_bytes 2_000

  # The consent lockout (`docs/oauth.md`, "Is the rate limit per client, per
  # address, or global"): five wrong passwords per address in fifteen
  # minutes, and a budget per hour for every address together, which the
  # deployment sets. The shared one is counted under a key no address can
  # be: every address key is a string.
  @lockout_window 900
  @lockout_attempts 5
  @all_addresses :all_addresses
  @all_addresses_window 3600

  @doc """
  Dynamic client registration. Returns the registration response, or one of:

    * `{:error, "invalid_redirect_uri"}` when no usable redirect URI was
      offered, and `{:error, "invalid_client_metadata"}` when the metadata is
      not a JSON object;
    * `{:error, error, description}` when a field is over its cap — the
      description names the field;
    * `:unavailable` when the client table is full or the record could not be
      stored, which the endpoint answers as `temporarily_unavailable`.
  """
  def register(persistence, json, now \\ System.system_time(:second))

  def register(_persistence, json, _now) when not is_map(json),
    do: {:error, "invalid_client_metadata"}

  def register(persistence, json, now) do
    with {:ok, name} <- client_name(json),
         {:ok, redirect_uris} <- redirect_uris(json) do
      client = Client.register(persistence, name, redirect_uris, now)

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
  rescue
    Persistence.Unavailable -> :unavailable
  end

  defp redirect_uris(json) do
    uris = Map.get(json, "redirect_uris", [])

    cond do
      not valid_redirect_uris?(uris) ->
        {:error, "invalid_redirect_uri"}

      length(uris) > @max_redirect_uris ->
        {:error, "invalid_redirect_uri",
         "redirect_uris holds more than #{@max_redirect_uris} URIs"}

      Enum.any?(uris, &(byte_size(&1) > @max_redirect_uri_bytes)) ->
        {:error, "invalid_redirect_uri",
         "a URI in redirect_uris is longer than #{@max_redirect_uri_bytes} bytes"}

      true ->
        {:ok, uris}
    end
  end

  defp valid_redirect_uris?([_ | _] = uris), do: Enum.all?(uris, &RedirectUri.valid_candidate?/1)
  defp valid_redirect_uris?(_), do: false

  # Shown on the consent page, so it must be a string whatever the client sent.
  defp client_name(%{"client_name" => name}) when is_binary(name) and name != "" do
    if String.length(name) > @max_client_name,
      do:
        {:error, "invalid_client_metadata",
         "client_name is longer than #{@max_client_name} characters"},
      else: {:ok, name}
  end

  defp client_name(_json), do: {:ok, "Unnamed client"}

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
      # Checked first: every check below reads a parameter as a string. The
      # client and its redirect URI are trusted by now, so the refusal goes
      # back to it — without a `state` that is not one to echo.
      not flat?(params) ->
        {:error, {:redirect, redirect_uri, "invalid_request", if(is_binary(state), do: state)}}

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
  Decides an "allow" on the consent page for a client at `ip` — the key
  `Vigil.OAuth.ClientAddr` counts it under, an IPv6 client's /64.

  `:rate_limited` once too many wrong passwords have come from that address,
  or once every address together has spent the deployment's hourly budget of
  wrong passwords (`consent_failures_per_hour`) — the second logs a warning
  when it is first reached. `:wrong_password` otherwise, and `{:ok, code}`
  with a fresh one-time authorization code when the password is right.
  Counting the attempt is part of the decision, so the caller cannot forget
  to.

  The attempt is counted *before* the password is compared, not after it
  turned out wrong. Counted after, every request in flight at once would
  have been compared against a budget none of them had spent yet; counted
  first, each is handed its own place in the window, and the one past the
  budget is refused without a comparison. A right password gives back what
  it took.

  `:unavailable` when the right password was given but the code could not be
  stored: a code that was never written is not handed to the client.
  """
  @spec consent(Server.t(), String.t(), String.t() | nil, map(), integer()) ::
          :rate_limited | :wrong_password | :unavailable | {:ok, String.t()}
  def consent(
        %Server{persistence: persistence, settings: settings},
        ip,
        password,
        ctx,
        now \\ System.system_time(:second)
      ) do
    with :ok <- take_attempt(persistence, ip, now, settings) do
      if password_matches?(password, settings.auth_password) do
        persistence.forget_attempts.(ip)
        persistence.return_attempt.(@all_addresses)
        issue_code(persistence, ctx, now)
      else
        :wrong_password
      end
    end
  end

  # The address's own window first: an address already locked out spends
  # nothing of the budget every address shares. An attempt refused by the
  # shared budget gives back what it took from the address's, since no
  # password was compared.
  defp take_attempt(persistence, ip, now, settings) do
    budget = settings.consent_failures_per_hour

    cond do
      persistence.take_attempt.(ip, @lockout_window, now) > @lockout_attempts ->
        :rate_limited

      (spent = persistence.take_attempt.(@all_addresses, @all_addresses_window, now)) > budget ->
        persistence.return_attempt.(ip)
        if spent == budget + 1, do: warn_all_addresses_spent(budget)
        :rate_limited

      true ->
        :ok
    end
  end

  # Once per window, on the attempt that first finds the budget spent — every
  # refusal after it would say the same thing, as often as it is asked.
  defp warn_all_addresses_spent(budget) do
    Logger.warning(
      "consent: #{budget} wrong passwords within the hour from all addresses together " <>
        "(VIGIL_CONSENT_FAILURES_PER_HOUR); the consent form answers 429 until the hour is up"
    )
  end

  @doc """
  Whether `given` is the consent password, in time that does not depend on
  either one's length.

  `Plug.Crypto.secure_compare/2` is constant-time only between two values of
  the same length: it answers `false` at once when the lengths differ, so how
  fast a guess is refused says whether the guess had the password's length.
  Both values are hashed first, and it is the two digests — always 32 bytes
  each — that are compared. Hashing the guess takes time in the guess's
  length, which the guesser already knows; nothing about the password's
  length reaches the answer.
  """
  @spec password_matches?(String.t() | nil, String.t()) :: boolean()
  def password_matches?(given, password) when is_binary(password) do
    Plug.Crypto.secure_compare(digest(given || ""), digest(password))
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  # The client's first code is recorded before the code is minted, so a code
  # never reaches a client the unused-client sweep would still take.
  defp issue_code(persistence, ctx, now) do
    Client.authorized(persistence, ctx.client.client_id, now)
    {:ok, Code.issue(persistence, ctx, now)}
  rescue
    Persistence.Unavailable -> :unavailable
  end

  @doc """
  Redeems a token request. `{:ok, token_response}` or `{:error, status, code}`.

  Both grants are deliberately uniform about failure: every way an
  authorization code can be wrong reports `invalid_grant`, so a caller
  learns nothing from which check rejected it.

  A write that did not persist answers `{:error, 503,
  "temporarily_unavailable"}` rather than a pair nobody can look up again —
  RFC 6749's code for a server "unable to handle the request due to a
  temporary overloading or maintenance", and the status that says so.
  """
  def grant(persistence, params, now \\ System.system_time(:second)) do
    # Redeeming a code and rotating a refresh token are each a lookup followed
    # by a delete, not one step. Two requests racing on the same code or the
    # same refresh token must not both succeed, so grants run one at a time.
    # The token endpoint is rate-limited and rare; the lock costs nothing.
    :global.trans({__MODULE__, :grant}, fn -> stored_grant(persistence, params, now) end)
  end

  defp stored_grant(persistence, params, now) do
    if flat?(params),
      do: do_grant(persistence, params, now),
      else: {:error, 400, "invalid_request"}
  rescue
    Persistence.Unavailable -> {:error, 503, "temporarily_unavailable"}
  end

  defp do_grant(persistence, %{"grant_type" => "authorization_code"} = params, now) do
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

  defp do_grant(persistence, %{"grant_type" => "refresh_token"} = params, now) do
    refresh_token = params["refresh_token"] || ""

    case Token.fetch_refresh(persistence, refresh_token) do
      # Order matters: a spent token is a replay before it is anything else.
      {:spent, data} -> replayed(persistence, data)
      {:ok, data} -> refresh(persistence, refresh_token, data, params, now)
      :error -> {:error, 400, "invalid_grant"}
    end
  end

  defp do_grant(_persistence, _params, _now), do: {:error, 400, "unsupported_grant_type"}

  defp redeemed(persistence, record, params, now) do
    aud = Code.audience_of(record)

    if target_ok?(params, aud) do
      {:ok, Token.issue_pair(persistence, scope_defaulted(record), now)}
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
        # Rotation: the presented token is spent, so a replay is refused — and,
        # because it is marked rather than deleted, recognised as a replay
        # rather than mistaken for a token that never existed.
        #
        # The pair is stored *before* the spend, and only handed out once both
        # are. A write that fails part-way then leaves the presented token
        # live, and the client's retry is a retry rather than a replay that
        # would revoke its whole grant. What a failed spend leaves behind is a
        # pair nobody was given, which expires on its own. Grants run one at a
        # time (`grant/3`), so the order opens no race.
        pair = Token.issue_pair(persistence, scope_defaulted(data), now)
        Token.spend_refresh(persistence, refresh_token, data, now)
        {:ok, pair}
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

  # `scope=""` is accepted at the authorization endpoint as "no scope asked
  # for", and no scope asked for is the default one. The token endpoint is
  # where that is decided, for a code and for a refresh token alike: a pair is
  # never issued with the empty string, which the allow-list at `/mcp` would
  # read as a scope that may not write. Deciding it here rather than at
  # consent also carries a family redeemed before this rule into `vault` on
  # its next rotation.
  defp scope_defaulted(%{scope: ""} = record), do: %{record | scope: OAuth.scope()}
  defp scope_defaulted(record), do: record

  @doc """
  Whether every parameter of a request is a single string.

  The endpoint decodes queries and forms with `Plug.Conn.Query`, where
  `client_id[]=x` is a list and `state[a]=x` a map. Nothing in OAuth is
  either, and every check in this module reads a parameter as a string, so a
  request carrying one is `invalid_request` before it is anything else.
  """
  @spec flat?(map()) :: boolean()
  def flat?(params), do: Enum.all?(params, fn {_name, value} -> is_binary(value) end)

  defp target_ok?(params, expected) do
    is_nil(params["resource"]) or params["resource"] == expected
  end
end
