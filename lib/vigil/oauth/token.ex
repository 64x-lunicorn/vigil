defmodule Vigil.OAuth.Token do
  @moduledoc """
  The token record: what it is made of, which kind it is, and whether one is
  a valid access token for a resource.

  Four places used to construct or destructure the same map and none of them
  owned it. `Vigil.OAuth.Flow` wrote an access record by *leaving out*
  `:type`; `Vigil.MCP.Server` re-derived the same classification the other way
  round, matching `%{type: :refresh}` to reject; `Vigil.OAuth.Store` read
  `:expires_at` and `:grant_id` off the map while sweeping and revoking; and
  `mix vigil.seed_token` hand-wrote a fifth variant. The two defaults for old
  records were each written twice, in different modules, with nothing making
  them agree.

  So: everything that writes a record does it here — minting the pair a
  redemption produces, seeding one out of band, marking one spent — and
  everything that asks what a record *is* does that here too: `classify/1`,
  `validate_access/3`, `fetch_refresh/1`, `expired?/2`, `scope_of/1`,
  `grant_of/1`, rather than reaching for a field.

  Verifying an access token is an OAuth 2.1 decision like any other, which is
  why `validate_access/3` takes a token and a resource and not a `Plug.Conn`:
  it lived in a private `cond` inside the MCP router, reachable only through a
  full request with a Bearer header, and that is what made audience, expiry
  and refresh-presented-as-access awkward to ask about on their own.
  """

  alias Vigil.OAuth
  alias Vigil.OAuth.{Code, Store}

  @access_ttl 3600
  @refresh_ttl 30 * 86_400

  @doc "32 random bytes, hex-encoded (64 chars). Used for auth codes, access and refresh tokens."
  def random do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  @doc "RFC 7636 S256 PKCE check."
  def pkce_valid?(code_verifier, code_challenge)
      when is_binary(code_verifier) and is_binary(code_challenge) do
    computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, code_challenge)
  end

  def pkce_valid?(_verifier, _challenge), do: false

  ## Minting

  @doc """
  Mints the access/refresh pair a redemption produces, writes both records,
  and returns the RFC 6749 token response.

  `record` is what the pair descends from: the authorization code being
  redeemed, or the refresh token being rotated. The pair inherits that
  record's client, audience, scope and grant from the record itself, so no
  caller can inherit them one way here and another way there.

  Both tokens carry the same `grant_id`: the family is what a replay revokes.
  They expire on different schedules — an hour against thirty days — because
  rotation is what bounds a refresh token, not its lifetime.
  """
  def issue_pair(record, now) do
    access_token = random()
    refresh_token = random()
    {aud, scope} = inherited(record)
    grant_id = grant_for_issue(record)

    Store.put_token(access_token, %{
      grant_id: grant_id,
      aud: aud,
      scope: scope,
      expires_at: now + @access_ttl
    })

    Store.put_token(refresh_token, %{
      type: :refresh,
      grant_id: grant_id,
      client_id: record.client_id,
      aud: aud,
      scope: scope,
      expires_at: now + @refresh_ttl
    })

    %{
      access_token: access_token,
      token_type: "Bearer",
      expires_in: @access_ttl,
      refresh_token: refresh_token,
      scope: scope
    }
  end

  @doc """
  Mints a lone long-lived access token, and returns it. For first access and
  for `verify()` during a rebuild — there was no flow, so there is no client
  and no refresh token to rotate.

  It still gets a grant of its own, so the token is a one-token family the
  replay defence can revoke like any other. Leaving the field out would make
  it indistinguishable from a record written before grants existed, which is
  the one thing revocation must not treat as a family.
  """
  def issue_out_of_band(aud, scope, ttl_seconds, now) do
    token = random()

    Store.put_token(token, %{
      grant_id: Vigil.Uuid.v4(),
      aud: aud,
      scope: scope,
      expires_at: now + ttl_seconds
    })

    token
  end

  # Where the pair's audience and its scope come from. A refresh token is this
  # module's record and carries both; an authorization code is
  # `Vigil.OAuth.Code`'s record and answers for itself.
  #
  # The audience used to arrive as a parameter, because the two records name it
  # differently — `:aud` here, `:resource` there — and reading both names in
  # this module would have put the shape of a record it does not own into it.
  # With the code record owned, it can be asked instead.
  defp inherited(%{aud: aud} = record), do: {aud, scope_of(record)}
  defp inherited(code), do: {Code.audience_of(code), Code.scope_of(code)}

  ## Classification

  @doc """
  Which of the three kinds a stored record is.

  An access token is one by the *absence* of `:type` — that is the shape
  already in every deployment's `.dets` file, so it is read that way here
  rather than migrated. `:spent_refresh` is a refresh token that rotation has
  already consumed; presenting one is the replay signal of RFC 9700 §4.14.2.

  `:spent_at` is read only on a refresh token, and that is the invariant:
  rotation is the only thing that spends a record, and it only ever spends a
  refresh token. A marker on anything else is not a shape this server writes
  and must not turn one into a replayable refresh token.
  """
  def classify(record)
  def classify(%{type: :refresh, spent_at: _}), do: :spent_refresh
  def classify(%{type: :refresh}), do: :refresh
  def classify(_record), do: :access

  @doc "Whether a record's hour is up. Inclusive: `expires_at` is the first instant it is dead."
  def expired?(record, now), do: record.expires_at <= now

  @doc """
  The scope a **token** record grants when it does not name one.

  Records written before scopes existed are full-access: they were minted when
  `vault` was the only thing a token could be, and reading them as
  `vault:read` would silently take write access away from a client that has
  it. New records always carry a scope, so this default only ever applies
  backwards.

  Only to token records, and that is deliberate: an authorization code answers
  `Vigil.OAuth.Code.scope_of/1`, which has no default. A code lives sixty
  seconds, so there is no such thing as a code from before scopes existed, and
  a default here would have quietly covered a code minted without one.
  """
  def scope_of(record), do: Map.get(record, :scope, OAuth.scope())

  @doc """
  The grant a record belongs to, or `nil` when it belongs to none.

  This is the answer for *revoking*: a record written before grants existed
  carries no family, and "every token whose grant is unknown" is not one —
  one replay must not take down a stranger. `Vigil.OAuth.Store.revoke_grant/1`
  therefore treats `nil` as a no-op.

  For *issuing* the same absent field falls the other way; see
  `grant_for_issue/1`.
  """
  def grant_of(record), do: Map.get(record, :grant_id)

  @doc """
  The grant a pair minted from `record` belongs to: its own, or a fresh one.

  This is the answer for *issuing*, and it is deliberately the opposite of
  `grant_of/1` on the same missing field. Minting one here keeps the invariant
  unconditional — every token issued from now on belongs to a family that can
  be revoked — where returning `nil` would let a record from before grants
  existed keep producing tokens that no replay can ever clean up.
  """
  def grant_for_issue(record), do: grant_of(record) || Vigil.Uuid.v4()

  ## Verification

  @doc """
  Whether `token` is a valid access token for `resource`, and at what scope.

  `{:ok, scope}` or `:error`. One failure shape on purpose: the resource
  server answers every one of them with the same 401 challenge, so a caller
  learns nothing from which check rejected it — not whether the token exists,
  not whether it was minted for somebody else's resource.

  An expired record is deleted on the way past. A refresh token presented here
  is refused and left alone: it is a valid token handed to the wrong endpoint,
  and deleting it would let anyone holding it destroy the ability to renew.
  """
  def validate_access(token, resource, now \\ System.system_time(:second)) do
    with {:ok, record} <- Store.get_token(token),
         :access <- classify(record) do
      valid_access(token, record, resource, now)
    else
      _ -> :error
    end
  end

  defp valid_access(token, record, resource, now) do
    cond do
      expired?(record, now) ->
        Store.delete_token(token)
        :error

      not Plug.Crypto.secure_compare(record.aud, resource) ->
        :error

      true ->
        {:ok, scope_of(record)}
    end
  end

  @doc """
  Marks a refresh token spent instead of deleting it.

  Deleting it made a replay indistinguishable from a token that never
  existed, and the replay is the whole point of rotation: it is the moment
  the authorization server learns that exactly one of two holders is an
  attacker. The record keeps its `expires_at`, so the janitor reclaims it on
  the same schedule as a live one and the marker does not outlive what it is
  evidence about.

  Only a refresh record matches, and that is the other half of how
  `classify/1` reads `:spent_at`. The marker can mean "replayed" only because
  rotation is the one thing that writes it and this is the only place
  rotation can.
  """
  def spend_refresh(token, %{type: :refresh} = record, now) do
    Store.put_token(token, Map.put(record, :spent_at, now))
  end

  @doc """
  Looks up a refresh token and says whether it is live or a replay.

  `{:ok, record}`, `{:spent, record}`, or `:error` for anything that is not a
  refresh token at all. The three are distinct returns rather than clause
  order at the call site because the caller must act on the replay *first*:
  presenting a spent token is the signal, and no other check may run ahead of
  it.
  """
  def fetch_refresh(token) do
    with {:ok, record} <- Store.get_token(token) do
      case classify(record) do
        :refresh -> {:ok, record}
        :spent_refresh -> {:spent, record}
        :access -> :error
      end
    end
  end
end
