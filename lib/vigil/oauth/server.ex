defmodule Vigil.OAuth.Server do
  @moduledoc """
  The authorization server as a value: where it keeps what it remembers, and
  what it says it is (`docs/design.md`, "The flow decides for one
  authorization server").

  A struct, not a process and not a router. `Vigil.OAuth.Endpoint` is the HTTP
  surface; this is what the decisions it hands to `Vigil.OAuth.Flow` are made
  *against* — the clients, codes and tokens of `Vigil.OAuth.Persistence` — and
  *for*: the issuer, resource and consent password `Vigil.Settings` carries.

  The two are one value because they never travelled apart. The router
  resolved both once at `init/1`, passed both to `authorize_request`, and
  passed both again to `consent` on the way back in. Which server a decision
  is for and where its records are kept are answered in the same breath, by
  the same caller, for a whole router rather than per request — so a signature
  that took them separately let them be answered differently, which no caller
  ever meant.

  `Vigil.OAuth.Endpoint.init/1` is the only place a pair is built. What
  `Vigil.MCP.Server` hands down and reads back are the halves, so there is no
  second pair for this one to disagree with.
  """

  alias Vigil.OAuth.Persistence
  alias Vigil.Settings

  @enforce_keys [:persistence, :settings]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          persistence: Persistence.t(),
          settings: Settings.t()
        }

  @doc """
  The authorization server a decision is made for, from the two halves that
  say so.

  `Vigil.OAuth.Endpoint.init/1` calls this once, out of the persistence and
  the settings it has just resolved, so every request it serves decides
  against the same pair.
  """
  @spec new(Persistence.t(), Settings.t()) :: t
  def new(persistence, settings) do
    %__MODULE__{persistence: persistence, settings: settings}
  end
end
