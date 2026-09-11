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

  `issuer`, `resource` and `auth_password` are read, not set: they are
  configured once for the whole run in `config/runtime.exs`. A test that needs a
  different persistence builds one; a test that needs different configuration
  is still on its own, and is still serial for it.
  """

  alias Vigil.OAuth
  alias Vigil.OAuth.{Client, Code, Flow, Persistence}

  @redirect_uri "https://client.example.org/cb"

  # The S256 challenge for the verifier below, precomputed so a test that has
  # no interest in PKCE does not have to hash anything to mint a code.
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  @doc "Returns `%{issuer:, resource:, auth_password:, persistence:}`."
  @spec setup!() :: %{
          issuer: String.t(),
          resource: String.t(),
          auth_password: String.t(),
          persistence: Persistence.t()
        }
  def setup! do
    %{
      issuer: OAuth.issuer(),
      resource: OAuth.resource(),
      auth_password: OAuth.auth_password(),
      persistence: Persistence.Memory.new()
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
      Flow.authorize_request(persistence, %{
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
