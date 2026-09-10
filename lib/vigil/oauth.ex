defmodule Vigil.OAuth do
  @moduledoc """
  The facts both halves of the HTTP surface need: who this authorization
  server says it is, what it protects, and the two scopes it issues.

  `Vigil.MCP.Server` needs them to challenge and to check an access token's
  audience; `Vigil.OAuth.Endpoint` needs them to issue one.
  """

  @scope "vault"
  @read_scope "vault:read"

  @doc "Full read/write scope."
  def scope, do: @scope

  @doc "Read-only scope (AP-6): the write tools are refused for a token holding it."
  def read_scope, do: @read_scope

  @doc "Every scope this server issues."
  def scopes, do: [@scope, @read_scope]

  def issuer, do: Application.fetch_env!(:vigil, :issuer)
  def resource, do: Application.fetch_env!(:vigil, :resource)
  def auth_password, do: Application.fetch_env!(:vigil, :auth_password)

  @doc "RFC 9728 protected-resource metadata."
  def protected_resource_metadata do
    %{
      resource: resource(),
      authorization_servers: [issuer()],
      scopes_supported: scopes(),
      bearer_methods_supported: ["header"]
    }
  end

  @doc "RFC 8414 authorization-server metadata."
  def authorization_server_metadata do
    %{
      issuer: issuer(),
      authorization_endpoint: issuer() <> "/oauth/authorize",
      token_endpoint: issuer() <> "/oauth/token",
      registration_endpoint: issuer() <> "/oauth/register",
      scopes_supported: scopes(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      client_id_metadata_document_supported: true,
      # RFC 9207. The parameter is on every authorization response either way;
      # this is what tells a client it can rely on being there, and therefore
      # that it may reject a response that arrives without it.
      authorization_response_iss_parameter_supported: true
    }
  end
end
