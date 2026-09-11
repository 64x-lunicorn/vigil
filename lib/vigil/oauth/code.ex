defmodule Vigil.OAuth.Code do
  @moduledoc """
  The authorization-code record: what it is made of, and whether the request
  presenting one may have what it points at.

  Six places used to write or read the same map and none of them owned it.
  `Vigil.OAuth.Flow` built it as a literal at consent and then destructured it
  field by field through four checks in the grant path and once more for the
  audience; the sweep reached into it for `:expires_at` — while asking
  `Vigil.OAuth.Token` the very same question about a token, so it knew the
  shape of one record and not the other. Two tests wrote their own variants,
  one of them without the `grant_id` production always sets.

  `docs/oauth.md` already records this decision for the token record — "The
  token record has one owner" — and the reason: four modules used to construct
  or destructure the same map and none of them owned it. That fix landed for
  tokens and never landed for codes.

  So: minting a code writes the record here, and every question about one is
  answered here. `redeem/4` takes a code and the token request presenting it
  and answers with the record or with a typed problem, in the terms the rule
  is stated in rather than in any caller's wording. Where the record is kept
  is `Vigil.OAuth.Persistence`'s, and arrives as a value. `Vigil.OAuth.Flow` renders
  that verdict, and renders every one of them the same way: RFC 6749 §5.2's
  `invalid_grant`, so a caller learns nothing from which check rejected it.
  """

  alias Vigil.OAuth.{Persistence, Token}

  @ttl 60

  @typedoc """
  What is wrong with a redemption. Every one of them is `invalid_grant` to the
  client; they are distinct here because a reader of this module needs to see
  that the four checks exist, and a test needs to name the one it is pinning.
  """
  @type problem :: :unknown | :expired | :wrong_client | :wrong_redirect_uri | :bad_pkce

  @doc """
  Mints a one-time authorization code for an approved consent and writes its
  record, returning the code.

  `ctx` is what `Vigil.OAuth.Flow.authorize_request/5` decided: the client,
  the redirect URI it was checked against, the PKCE challenge, the scope, and
  the audience the request was authorized for. The audience comes from there
  rather than from configuration read a second time here, so a code cannot be
  minted for a resource the request was never checked against. What is left
  for this module is the grant the code opens and the minute it lives.
  """
  def issue(persistence, ctx, now \\ System.system_time(:second)) do
    code = Token.random()

    persistence.put_code.(code, %{
      client_id: ctx.client.client_id,
      redirect_uri: ctx.redirect_uri,
      code_challenge: ctx.code_challenge,
      resource: ctx.resource,
      scope: ctx.scope,
      # The authorization grant this code, and every token redeemed from it,
      # belongs to. It is what "revoke the whole family" is expressed in.
      grant_id: Vigil.Uuid.v4(),
      expires_at: now + @ttl
    })

    code
  end

  @doc """
  Takes `code` out of the store and says whether `request` — the token request
  presenting it — may redeem it.

  The code is consumed either way: it is one-time use, and a redemption that
  got the client or the verifier wrong has still spent it. That is deliberate,
  and it is why the lookup comes first.

  `{:ok, record}` or `{:error, problem}`. The audience is not checked here:
  RFC 8707 answers a wrong `resource` with `invalid_target` rather than
  `invalid_grant`, and the same rule applies to a refresh token, so it stays
  with the caller that has both grants in front of it.
  """
  @spec redeem(Persistence.t(), String.t(), map(), integer()) ::
          {:ok, map()} | {:error, problem()}
  def redeem(persistence, code, request, now) do
    with {:ok, record} <- take(persistence, code),
         :ok <- live?(record, now),
         :ok <- own_client?(record, request),
         :ok <- own_redirect_uri?(record, request) do
      pkce_ok?(record, request)
    end
  end

  defp take(persistence, code) do
    case persistence.take_code.(code) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :unknown}
    end
  end

  defp live?(record, now), do: if(expired?(record, now), do: {:error, :expired}, else: :ok)

  defp own_client?(record, request),
    do: if(record.client_id == request["client_id"], do: :ok, else: {:error, :wrong_client})

  defp own_redirect_uri?(record, request) do
    if record.redirect_uri == request["redirect_uri"],
      do: :ok,
      else: {:error, :wrong_redirect_uri}
  end

  defp pkce_ok?(record, request) do
    if Token.pkce_valid?(request["code_verifier"] || "", record.code_challenge) do
      {:ok, record}
    else
      {:error, :bad_pkce}
    end
  end

  @doc """
  Whether a code's minute is up. Inclusive: `expires_at` is the first instant
  it is dead, exactly as `Vigil.OAuth.Token.expired?/2` reads a token's — which
  is the point of both existing. The sweep asks each record's owner rather than
  reading one of the two maps itself.
  """
  def expired?(record, now), do: record.expires_at <= now

  @doc """
  The resource a code was minted for — what a token redeemed from it is good
  for, and what an RFC 8707 `resource` parameter is checked against.
  """
  def audience_of(record), do: record.resource

  @doc """
  The scope a code carries into the pair redeemed from it.

  No default, and deliberately. `Vigil.OAuth.Token.scope_of/1` reads a missing
  scope as full vault access, which is a rule about token records written
  before scopes existed. A code lives sixty seconds, so no code from before
  scopes existed can be in a store: one without a scope is a record this
  server did not write, and it fails here rather than minting a pair with more
  access than the authorization carried.
  """
  def scope_of(record), do: record.scope
end
