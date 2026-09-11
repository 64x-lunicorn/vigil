defmodule Vigil.OAuth do
  @moduledoc """
  The two scopes this authorization server issues, and the two metadata
  documents it publishes about itself.

  Who the server says it is, what it protects and what it checks a human
  against are not read here: they are three of the deployment's settings,
  resolved once (`Vigil.Settings`) and handed in. Both metadata functions take
  that value, which is why a test can state an authorization server rather
  than install one.
  """

  alias Vigil.Settings

  @scope "vault"
  @read_scope "vault:read"

  @doc "Full read/write scope."
  def scope, do: @scope

  @doc "Read-only scope (AP-6): the write tools are refused for a token holding it."
  def read_scope, do: @read_scope

  @doc "Every scope this server issues."
  def scopes, do: [@scope, @read_scope]

  @doc "RFC 9728 protected-resource metadata."
  @spec protected_resource_metadata(Settings.t()) :: map()
  def protected_resource_metadata(settings) do
    %{
      resource: settings.resource,
      authorization_servers: [settings.issuer],
      scopes_supported: scopes(),
      bearer_methods_supported: ["header"]
    }
  end

  @doc "RFC 8414 authorization-server metadata."
  @spec authorization_server_metadata(Settings.t()) :: map()
  def authorization_server_metadata(settings) do
    %{
      issuer: settings.issuer,
      authorization_endpoint: settings.issuer <> "/oauth/authorize",
      token_endpoint: settings.issuer <> "/oauth/token",
      registration_endpoint: settings.issuer <> "/oauth/register",
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
