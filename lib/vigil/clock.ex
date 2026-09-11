defmodule Vigil.Clock do
  @moduledoc """
  The vault's one notion of "now": the current time in the timezone it is
  given, and never a raise.

  The timezone is an argument rather than a configuration read, because the
  deployment is resolved once and handed on (`Vigil.Settings`). What is left
  here is the part that is this module's own: an *invalid* timezone falls back
  to UTC rather than taking a caller down with it — in particular the write
  path, which must stay crash-safe by construction. A *missing* one cannot
  reach here any more; `Vigil.Settings.from_env/0` fetches it at boot, where
  an operator can see it fail.
  """

  @doc "The current time in `tz`, falling back to UTC when `tz` is not a zone."
  @spec now(String.t()) :: DateTime.t()
  def now(tz) do
    case DateTime.now(tz) do
      {:ok, now} -> now
      _ -> DateTime.utc_now()
    end
  end
end
