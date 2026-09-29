import Config

# A variable that reads as an integer is handed on as one, and anything else
# as written. Nothing here judges a value: `Vigil.Settings.Check` does, once,
# before anything starts, and names the variable it refuses — which a raise
# from `String.to_integer/1` in this file could not.
integer = fn var, default ->
  value = System.get_env(var, default)

  case Integer.parse(value) do
    {int, ""} -> int
    _ -> value
  end
end

config :vigil,
  # Whether `VIGIL_ISSUER` and `VIGIL_RESOURCE` must be https and share an
  # origin. Only a deployment talks to real clients; dev runs on localhost.
  https_required: config_env() == :prod,
  port: integer.("VIGIL_PORT", "4000"),
  # Loopback by default: cloudflared runs on the same host, and a port open on
  # the LAN is a way around Cloudflare Access. Set 0.0.0.0 (or an interface
  # address) only when a proxy on another host forwards to vigil.
  bind: System.get_env("VIGIL_BIND", "127.0.0.1"),
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
  # Browser origins besides the issuer's own that may send a request to `/mcp`
  # and the authorization server. Empty by default: a request with no `Origin`
  # (a program) and one from the issuer's origin (the consent form) are
  # allowed regardless, and every other browser origin is refused with 403.
  allowed_origins:
    System.get_env("VIGIL_ALLOWED_ORIGINS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "")),
  issuer: System.get_env("VIGIL_ISSUER", "http://localhost:4000"),
  resource: System.get_env("VIGIL_RESOURCE", "http://localhost:4000/mcp"),
  auth_password: System.get_env("VIGIL_AUTH_PASSWORD"),
  # The AP-4 SkillKey HMAC secret: random bytes of its own, never the consent
  # password. No default anywhere, like the password.
  skillkey_secret: System.get_env("VIGIL_SKILLKEY_SECRET"),
  skillkey_ttl_seconds: integer.("VIGIL_SKILLKEY_TTL", "3600"),
  rate_limit_rpm: integer.("VIGIL_RATE_LIMIT_RPM", "60"),
  # `reload` is counted a second time, per access token, against a budget of
  # its own: each call pulls and reparses the whole vault inside the writer.
  reload_rate_limit_rpm: integer.("VIGIL_RELOAD_RATE_LIMIT_RPM", "6"),
  # The authorization server's own budgets, per client address per minute.
  # Registration gets the tighter one: it is rare, and each call writes a
  # `:dets` row and fsyncs it.
  oauth_rate_limit_rpm: integer.("VIGIL_OAUTH_RATE_LIMIT_RPM", "30"),
  oauth_register_rate_limit_rpm: integer.("VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM", "5"),
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
# only stores and gives back, and the one a pre-seam fixture was minted with.
#
# `skillkey_secret` is pinned beside it: every write the suite makes carries a
# SkillKey (`Vigil.SkillKey`) derived from it, so it cannot be left unset
# either. Not a secret — it keys nothing outside the suite.
if config_env() == :test do
  config :vigil,
    vault_path: Path.expand("test/fixtures/vault", File.cwd!()),
    state_dir: Path.expand("tmp/test_oauth_state", File.cwd!()),
    issuer: "https://vault.factory-lab.org",
    resource: "https://vault.factory-lab.org/mcp",
    auth_password: "correct-horse-battery-staple",
    skillkey_secret: "y7CI4lMs8Utr4o5rIo2N2TqzaVmvCH4X6yjvDaLpVnzq4k5LCvhFQIPj3KnhnyKq"
else
  # In :prod the four facts that decide which vault, which OAuth state and
  # which identity have no fallback. A missing line in /etc/vigil/env used to
  # boot against the demo vault, keep OAuth state inside the release directory
  # (replaced on every update) or announce `localhost` as the issuer, which
  # fails every real token's audience check. Unset, they stay nil here and
  # Vigil.Settings.Check refuses to start, naming the variable.
  #
  # Only the server refuses: mix tasks run under MIX_ENV=prod (seed_token,
  # vault_check) evaluate this file too and take what they need as arguments.
  fallback = fn var, default ->
    if config_env() == :prod, do: System.get_env(var), else: System.get_env(var, default)
  end

  config :vigil,
    vault_path: fallback.("VIGIL_VAULT_PATH", Path.expand("test/fixtures/vault", File.cwd!())),
    state_dir: fallback.("VIGIL_STATE_DIR", Path.expand("tmp/oauth_state", File.cwd!())),
    issuer: fallback.("VIGIL_ISSUER", "http://localhost:4000"),
    resource: fallback.("VIGIL_RESOURCE", "http://localhost:4000/mcp")
end
