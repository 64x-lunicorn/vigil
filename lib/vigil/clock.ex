defmodule Vigil.Clock do
  @moduledoc """
  The vault's one notion of "now": reads the `:tz` application setting in one
  place and never raises. A missing or invalid timezone falls back to UTC
  rather than taking a caller down with it — in particular the write path,
  which must stay crash-safe by construction.
  """

  @default_tz "Europe/Berlin"

  @doc "The current time in the vault's configured timezone, falling back to UTC."
  def now do
    case DateTime.now(tz()) do
      {:ok, now} -> now
      _ -> DateTime.utc_now()
    end
  end

  @doc "The current date in the vault's configured timezone, falling back to UTC."
  def today, do: DateTime.to_date(now())

  defp tz, do: Application.get_env(:vigil, :tz, @default_tz)
end
