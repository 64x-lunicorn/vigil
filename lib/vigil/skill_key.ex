defmodule Vigil.SkillKey do
  @moduledoc """
  Rotating attestation token (AP-4): `skill_read` hands this out, write tools
  require it as proof that the caller actually read the current skill guide
  before writing. Rotates every `key.window` seconds; the previous window
  stays valid as a grace period so a key handed out just before rotation
  doesn't die mid-conversation.

  The secret and the window are individually meaningless — neither derives a
  token alone — so every function here takes them bundled as one `key`
  (`%{secret:, window:}`), obtained from `config/0`, the single accessor that
  reads application configuration.
  """

  @length 16

  @doc "The configured secret and rotation window, bundled as one value."
  def config do
    %{
      secret: Application.fetch_env!(:vigil, :auth_password),
      window: Application.get_env(:vigil, :skillkey_ttl_seconds, 3600)
    }
  end

  @doc "Current token for `now` (defaults to real time), derived from `key`."
  def current(key, now \\ System.system_time(:second)) do
    derive(key.secret, bucket(now, key.window))
  end

  @doc "True if `token` matches the current or the immediately preceding rotation window."
  def valid?(token, key, now \\ System.system_time(:second)) do
    current_bucket = bucket(now, key.window)

    Plug.Crypto.secure_compare(token, derive(key.secret, current_bucket)) or
      Plug.Crypto.secure_compare(token, derive(key.secret, current_bucket - 1))
  end

  defp bucket(now, window), do: div(now, window)

  defp derive(secret, bucket) do
    :crypto.mac(:hmac, :sha256, secret, "vigil-skillkey:#{bucket}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, @length)
  end
end
