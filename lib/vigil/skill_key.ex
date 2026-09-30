defmodule Vigil.SkillKey do
  @moduledoc """
  Rotating attestation token (AP-4): `skill_read` hands this out, write tools
  require it as proof that the caller actually read the current skill guide
  before writing. Rotates every `key.window` seconds; the previous window
  stays valid as a grace period so a key handed out just before rotation
  doesn't die mid-conversation.

  The secret and the window are individually meaningless — neither derives a
  token alone — so every function here takes them bundled as one `key`
  (`%{secret:, window:}`). Nothing here reads application configuration: both
  halves come from the settings the composition root resolved (`docs/design.md`,
  "The deployment is resolved once"), and `key/1` is where that value becomes
  this one.
  """

  alias Vigil.Settings

  @length 16

  @type t :: %{secret: String.t(), window: pos_integer()}

  @doc """
  The key this deployment's tokens are derived from.

  The HMAC secret is the deployment's SkillKey secret (`VIGIL_SKILLKEY_SECRET`)
  and nothing else: a token is handed to every client and ends up in chat
  transcripts, so it is keyed with random bytes no one chose, never with the
  consent password, which a human may have. The two rotate apart. The window
  is the deployment's rotation window.
  """
  @spec key(Settings.t()) :: t
  def key(%Settings{skillkey_secret: secret, skillkey_ttl_seconds: window}),
    do: %{secret: secret, window: window}

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
