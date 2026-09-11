defmodule Vigil.Settings do
  @moduledoc """
  What the deployment says about itself, resolved once and handed on as one
  value (`docs/design.md`, "The deployment is resolved once").

  Seven facts, in three groups. The vault's timezone is the one notion of
  "now" every response and every write is stamped with. The authorization
  server's identity — issuer, resource, consent password, and the window an
  AP-4 SkillKey rotates on — is what it says it is, what it protects, what it
  checks a human against, and how long a key derived from that same password
  stays good for. The owner and the language shape the writing instructions
  handed to the MCP client; they describe the *vault*, not this server, whose
  own output is always English.

  They are one value rather than seven because of where they are read, not
  because they derive anything together: an environment read belongs in the
  composition root, and a module that asks for one key at a time cannot be
  handed another deployment — which is what made the tests that needed one
  write into global application env and undo it afterwards.

  `from_env/0` is the only place these seven keys are read. Every default is
  `config/runtime.exs`'s, stated once there as the fallback of the environment
  variable it comes from, which is why this fetches rather than defaults: a
  key that is somehow unset should fail at boot, where the operator can see
  it, and not at the first write.
  """

  @enforce_keys [
    :tz,
    :issuer,
    :resource,
    :auth_password,
    :skillkey_ttl_seconds,
    :vault_owner,
    :vault_language
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tz: String.t(),
          issuer: String.t(),
          resource: String.t(),
          auth_password: String.t(),
          skillkey_ttl_seconds: pos_integer(),
          vault_owner: String.t(),
          vault_language: String.t()
        }

  @doc """
  The deployment's settings, read from application configuration.

  Called once, where the supervision tree is built, and handed to the children
  that need them. Everything that takes a `:settings` option defaults to this
  so a caller that supplies none gets the deployment's own — the same rule
  `Vigil.Store`'s git adapter, OAuth persistence and the rate limiter follow.
  """
  @spec from_env() :: t
  def from_env do
    %__MODULE__{
      tz: Application.fetch_env!(:vigil, :tz),
      issuer: Application.fetch_env!(:vigil, :issuer),
      resource: Application.fetch_env!(:vigil, :resource),
      auth_password: Application.fetch_env!(:vigil, :auth_password),
      skillkey_ttl_seconds: Application.fetch_env!(:vigil, :skillkey_ttl_seconds),
      vault_owner: Application.fetch_env!(:vigil, :vault_owner),
      vault_language: Application.fetch_env!(:vigil, :vault_language)
    }
  end
end
