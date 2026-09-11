import Config

config :vigil,
  port: String.to_integer(System.get_env("VIGIL_PORT", "4000")),
  git_remote: System.get_env("VIGIL_GIT_REMOTE", "origin"),
  tz: System.get_env("VIGIL_TZ", "Europe/Berlin"),
  exclude:
    System.get_env("VIGIL_EXCLUDE", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "")),
  # Which address a rate limit is keyed on. The header name is unset and the
  # trusted list is empty by default, and that is the safe setting: a
  # forwarded header is attacker-controlled
  # unless a proxy is known to sanitize it, so vigil believes one only when
  # told both the header's name and the peers allowed to set it. Setting
  # these wrong is worse than leaving them unset — see docs/guide.md.
  trusted_proxy_header: System.get_env("VIGIL_TRUSTED_PROXY_HEADER"),
  trusted_proxies:
    System.get_env("VIGIL_TRUSTED_PROXIES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "")),
  issuer: System.get_env("VIGIL_ISSUER", "http://localhost:4000"),
  resource: System.get_env("VIGIL_RESOURCE", "http://localhost:4000/mcp"),
  auth_password: System.get_env("VIGIL_AUTH_PASSWORD"),
  skillkey_ttl_seconds: String.to_integer(System.get_env("VIGIL_SKILLKEY_TTL", "3600")),
  rate_limit_rpm: String.to_integer(System.get_env("VIGIL_RATE_LIMIT_RPM", "60")),
  # The authorization server's own budgets, per client address per minute.
  # Registration gets the tighter one: it is rare, and each call writes a
  # `:dets` row and fsyncs it.
  oauth_rate_limit_rpm: String.to_integer(System.get_env("VIGIL_OAUTH_RATE_LIMIT_RPM", "30")),
  oauth_register_rate_limit_rpm:
    String.to_integer(System.get_env("VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM", "5")),
  # Shape the writing instructions the server hands to the MCP client. These
  # describe the *vault*, not the server: whose notes these are, and which
  # language they are written in. The server's own output is always English.
  vault_owner: System.get_env("VIGIL_VAULT_OWNER", "the vault owner"),
  vault_language: System.get_env("VIGIL_VAULT_LANGUAGE", "English")

# What :test pins for itself, last so that nothing above can be picked up from
# the shell instead.
#
# vault_path/state_dir touch real data (the Markdown vault, OAuth client/token
# state) — in :test they must never follow a stray VIGIL_VAULT_PATH/
# VIGIL_STATE_DIR left over in the shell (e.g. from a sourced /etc/vigil/env),
# or a green `mix test` could silently mean nothing.
#
# The authorization server's identity and its consent password are pinned for
# a second reason: the suite reads them back and asserts against them, and
# they are set here — once, for the whole run — rather than by each OAuth test
# around itself. A fixture that mutates global application env cannot be
# shared by files running in parallel, and after `test/support/oauth_case.ex`
# stopped needing a state dir this was the only thing left holding the OAuth
# files serial. Where they are read from is a separate question and has an
# answer now: `Vigil.Settings.from_env/0`, once, where the supervision tree is
# built (docs/design.md, "The deployment is resolved once"). Which also makes
# the defaults above the only statement of each in `lib/` — no module there
# restates them. In the suite the three are one value in one place,
# `test/support/oauth_case.ex`: the server a test hands to a router or to a
# decision when its subject is what that server was told rather than where it
# read it from. Single fields are still written down elsewhere in the suite,
# in the files whose subject makes the string opaque: an audience persistence
# only stores and gives back, a password a flow only compares.
#
# `auth_password` doubles as the AP-4 SkillKey HMAC secret (`Vigil.SkillKey`),
# which is why the suite cannot simply leave it unset.
if config_env() == :test do
  config :vigil,
    vault_path: Path.expand("test/fixtures/vault", File.cwd!()),
    state_dir: Path.expand("tmp/test_oauth_state", File.cwd!()),
    issuer: "https://vault.factory-lab.org",
    resource: "https://vault.factory-lab.org/mcp",
    auth_password: "correct-horse-battery-staple"
else
  config :vigil,
    vault_path:
      System.get_env("VIGIL_VAULT_PATH", Path.expand("test/fixtures/vault", File.cwd!())),
    state_dir: System.get_env("VIGIL_STATE_DIR", Path.expand("tmp/oauth_state", File.cwd!()))
end
