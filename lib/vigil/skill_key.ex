defmodule Vigil.SkillKey do
  @moduledoc """
  Rotating attestation token (AP-4): `skill_read` hands this out, write tools
  require it as proof that the caller actually read the current skill guide
  before writing. Rotates hourly; the previous hour stays valid as a grace
  window so a key handed out just before rotation doesn't die mid-conversation.
  """

  @length 16

  @doc "Current token for `now` (defaults to real time), derived from `secret`."
  def current(secret, now \\ System.system_time(:second)) do
    token(secret, hour_bucket(now))
  end

  @doc "True if `key` matches the current or the immediately preceding hour bucket."
  def valid?(key, secret, now \\ System.system_time(:second)) do
    bucket = hour_bucket(now)

    Plug.Crypto.secure_compare(key, token(secret, bucket)) or
      Plug.Crypto.secure_compare(key, token(secret, bucket - 1))
  end

  @doc "Reads the HMAC secret from application config (the required auth_password)."
  def secret, do: Application.fetch_env!(:vigil, :auth_password)

  defp hour_bucket(now), do: div(now, 3600)

  defp token(secret, bucket) do
    :crypto.mac(:hmac, :sha256, secret, "vigil-skillkey:#{bucket}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, @length)
  end
end
