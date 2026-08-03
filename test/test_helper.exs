# auth_password doubles as the AP-4 SkillKey HMAC secret (Vigil.SkillKey).
# runtime.exs reads it from VIGIL_AUTH_PASSWORD with no default (intentional —
# production must set it explicitly), so tests need their own fallback here.
if is_nil(Application.get_env(:vigil, :auth_password)) do
  Application.put_env(:vigil, :auth_password, "test-default-password-not-for-prod")
end

ExUnit.start()
