import Config

# vault_path/state_dir touch real data (the Markdown vault, OAuth client/token
# state) — in :test they must never follow a stray VIGIL_VAULT_PATH/
# VIGIL_STATE_DIR left over in the shell (e.g. from a sourced /etc/vigil/env),
# or a green `mix test` could silently mean nothing.
if config_env() == :test do
  config :vigil,
    vault_path: Path.expand("test/fixtures/vault", File.cwd!()),
    state_dir: Path.expand("tmp/test_oauth_state", File.cwd!())
else
  config :vigil,
    vault_path:
      System.get_env("VIGIL_VAULT_PATH", Path.expand("test/fixtures/vault", File.cwd!())),
    state_dir: System.get_env("VIGIL_STATE_DIR", Path.expand("tmp/oauth_state", File.cwd!()))
end

config :vigil,
  port: String.to_integer(System.get_env("VIGIL_PORT", "4000")),
  git_remote: System.get_env("VIGIL_GIT_REMOTE", "origin"),
  tz: System.get_env("VIGIL_TZ", "Europe/Berlin"),
  exclude:
    System.get_env("VIGIL_EXCLUDE", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "")),
  issuer: System.get_env("VIGIL_ISSUER", "http://localhost:4000"),
  resource: System.get_env("VIGIL_RESOURCE", "http://localhost:4000/mcp"),
  auth_password: System.get_env("VIGIL_AUTH_PASSWORD"),
  skillkey_ttl_seconds: String.to_integer(System.get_env("VIGIL_SKILLKEY_TTL", "3600")),
  rate_limit_rpm: String.to_integer(System.get_env("VIGIL_RATE_LIMIT_RPM", "60")),
  # Shape the writing instructions the server hands to the MCP client. These
  # describe the *vault*, not the server: whose notes these are, and which
  # language they are written in. The server's own output is always English.
  vault_owner: System.get_env("VIGIL_VAULT_OWNER", "the vault owner"),
  vault_language: System.get_env("VIGIL_VAULT_LANGUAGE", "English")
