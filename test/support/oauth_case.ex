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
  alias Vigil.OAuth.Persistence

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
end
