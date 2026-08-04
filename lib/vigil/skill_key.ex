defmodule Vigil.SkillKey do
  @moduledoc """
  Rotating attestation token (AP-4): `skill_read` hands this out, write tools
  require it as proof that the caller actually read the current skill guide
  before writing. Rotates every `:skillkey_ttl_seconds` (default 3600, one
  hour); the previous window stays valid as a grace period so a key handed out
  just before rotation doesn't die mid-conversation.
  """

  @length 16

  @doc "Current token for `now` (defaults to real time), derived from `secret`."
  def current(secret, now \\ System.system_time(:second)) do
    token(secret, bucket(now))
  end

  @doc "True if `key` matches the current or the immediately preceding rotation window."
  def valid?(key, secret, now \\ System.system_time(:second)) do
    current_bucket = bucket(now)

    Plug.Crypto.secure_compare(key, token(secret, current_bucket)) or
      Plug.Crypto.secure_compare(key, token(secret, current_bucket - 1))
  end

  @doc "Reads the HMAC secret from application config (the required auth_password)."
  def secret, do: Application.fetch_env!(:vigil, :auth_password)

  defp bucket(now), do: div(now, ttl_seconds())

  defp ttl_seconds, do: Application.get_env(:vigil, :skillkey_ttl_seconds, 3600)

  defp token(secret, bucket) do
    :crypto.mac(:hmac, :sha256, secret, "vigil-skillkey:#{bucket}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, @length)
  end
end
