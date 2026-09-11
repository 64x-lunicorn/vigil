defmodule Vigil.OAuthCase do
  @moduledoc """
  The OAuth fixture: a persistence of this test's own, and the three
  configured facts the flow reads back.

  It used to build a throwaway state dir, start `Vigil.OAuth.Store` against it
  and hand back the `:dets` adapter over the tables that process registers
  globally. Eight files did that to ask a question about a token, and every
  one of them had to be serial for it. `persistence` is now
  `Vigil.OAuth.Persistence.Memory` — no filesystem, no state dir, no
  registered name — so the files that ask through it run in parallel. The one
  place that still opens a `:dets` file is the contract suite's production
  half (`test/vigil/oauth/persistence_test.exs`).

  `settings` is what the deployment says about itself
  (`Vigil.Settings.from_env/0`), read once here and handed on: `issuer`,
  `resource` and `auth_password` are the three of its fields the OAuth tests
  assert against, and they are pinned for the whole run in
  `config/runtime.exs`. Nothing here writes application env, so a test that
  needs a different authorization server builds a settings value of its own
  and hands it in, the same way it builds a persistence of its own.
  """

  alias Vigil.OAuth.{Client, Code, Flow, Persistence, Server}
  alias Vigil.Settings

  @redirect_uri "https://client.example.org/cb"

  # The S256 challenge for the verifier below, precomputed so a test that has
  # no interest in PKCE does not have to hash anything to mint a code.
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  @doc "Returns `%{settings:, issuer:, resource:, auth_password:, persistence:}`."
  @spec setup!() :: %{
          settings: Settings.t(),
          issuer: String.t(),
          resource: String.t(),
          auth_password: String.t(),
          persistence: Persistence.t()
        }
  def setup! do
    settings = Settings.from_env()

    %{
      settings: settings,
      issuer: settings.issuer,
      resource: settings.resource,
      auth_password: settings.auth_password,
      persistence: Persistence.Memory.new()
    }
  end

  @doc """
  An authorization server *stated* rather than read: the suite's one statement
  of an issuer, a resource and a consent password.

  `setup!/0`'s `settings` is the deployment's own, read from application env.
  This is for the files whose subject is what a server is *told* rather than
  where it read it from — `Vigil.OAuth.FlowTest` checks a request's target and
  a consent's password against it, `Vigil.OAuth.CodeTest` checks the audience
  a minted code carries, and `Vigil.OAuth.EndpointTest` initializes every
  router it drives with it and asserts the discovery documents and the `iss`
  parameter come back saying exactly this. Handed in, each of them checks the
  server against what it was given; read back, each would only check
  `config/runtime.exs` against itself.

  It is one value in one place because three files wanting the same stated
  server is one statement, not three. `config/runtime.exs` says the same, for
  `lib/`. Single fields are written down again where a file's subject makes
  the string opaque — `Vigil.OAuth.PersistenceTest` and `Vigil.OAuth.TokenTest`
  state an audience of their own, and `Vigil.OAuth.StoreCompatibilityTest` the
  one its frozen fixtures were already minted with. Each says why where it
  states it.
  """
  @spec stated_settings() :: Settings.t()
  def stated_settings do
    %Settings{
      tz: "Europe/Berlin",
      issuer: "https://vault.factory-lab.org",
      resource: "https://vault.factory-lab.org/mcp",
      auth_password: "correct-horse-battery-staple",
      skillkey_ttl_seconds: 3600,
      vault_owner: "the vault owner",
      vault_language: "English"
    }
  end

  @doc """
  Mints a real authorization code at `now`, through the modules that own the
  records: a client registered, a request authorized, a code issued.

  A code lives a minute, so one minted an hour ago has expired at `now` and
  one minted at `now` has not — which is what a test of the sweep needs, and
  why this is not a hand-written record. Both the contract suite and the
  janitor's want one.
  """
  @spec mint_code(Persistence.t(), integer()) :: String.t()
  def mint_code(persistence, now) do
    client = Client.register(persistence, "Client", [@redirect_uri], now)

    {:ok, ctx} =
      Flow.authorize_request(Server.new(persistence, Settings.from_env()), %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256"
      })

    Code.issue(persistence, ctx, now)
  end

  @doc "The redirect URI `mint_code/2` registers and checks against."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri
end
