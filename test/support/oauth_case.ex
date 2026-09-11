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

  alias Vigil.OAuth.{Client, Code, Flow, Persistence}
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
  An authorization server *stated* rather than read.

  `setup!/0`'s `settings` is the deployment's own, for the files that assert
  what a deployment serves. This is for the two whose subject is a decision
  that turns on one of these fields and nothing else —
  `Vigil.OAuth.FlowTest` checks a request's target and a consent's password
  against it, `Vigil.OAuth.CodeTest` checks the audience a minted code
  carries — so the value those assertions name is written down rather than
  fetched. It is here, once, because two files wanting the same stated server
  is one statement, not two.
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
      Flow.authorize_request(persistence, Settings.from_env(), %{
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
