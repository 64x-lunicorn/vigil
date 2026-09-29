#!/usr/bin/env bash
# scripts/test/proxy_settings_test.sh — the proxy lines init.sh writes into
# /etc/vigil/env.
#
# The rate limits and the consent lockout count per client address, and which
# address that is comes from two settings (Vigil.OAuth.ClientAddr). The guide
# used to show Cloudflare's edge ranges as the trusted proxies. The deployment
# it describes runs cloudflared on the same host, so the peer of every request
# is loopback and a list of edge ranges never matched: everyone shared one
# bucket, and anyone could lock the owner out of consenting. What fits the
# tunnel is loopback as the trusted peer and CF-Connecting-IP as the header,
# and init.sh writes it.
#
# init.sh's step 4 needs root, a "vigil" user and a booted host, so what is
# asserted is the env file it writes, cut out of its own text — the heredoc
# that becomes ENV_CONTENT — and the two documents that say what it writes.
#
# Usage: bash scripts/test/proxy_settings_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INIT_SH="${REPO_ROOT}/scripts/init.sh"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

HEADER_LINE='VIGIL_TRUSTED_PROXY_HEADER=CF-Connecting-IP'
PROXIES_LINE='VIGIL_TRUSTED_PROXIES=127.0.0.1/32,::1/128'

# Whether a line appears in the text on a line of its own — not commented out,
# not inside a longer line.
has_line() {
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

assert_line() {
  if has_line "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected a line of its own: $3"
  fi
}

## ── 1. The env file init.sh writes ───────────────────────────────────────

section "1/3  init.sh writes the tunnel's proxy settings"

# The heredoc between `ENV_CONTENT="$(` and the `EOF` that closes it.
env_content="$(awk '/^ENV_CONTENT="\$\($/ { on = 1; next } on && /^EOF$/ { exit } on' "$INIT_SH")"

# init.sh's own text, expansion and all, so single-quoted.
# shellcheck disable=SC2016
if has_line "$env_content" 'VIGIL_VAULT_PATH=${VAULT}'; then
  pass "the env file's heredoc was found in init.sh"
else
  fail "the env file's heredoc was found in init.sh" "cut out: ${env_content:-nothing}"
fi

assert_line "the env file names CF-Connecting-IP as the header" "$env_content" "$HEADER_LINE"
assert_line "the env file trusts loopback, where cloudflared connects from" \
  "$env_content" "$PROXIES_LINE"

## ── 2. The example env file ──────────────────────────────────────────────

section "2/3  deploy/vigil.env.example shows the same two lines"

example="$(cat "${REPO_ROOT}/deploy/vigil.env.example")"
assert_line "the example names CF-Connecting-IP as the header" "$example" "$HEADER_LINE"
assert_line "the example trusts loopback" "$example" "$PROXIES_LINE"

if printf '%s\n' "$example" | grep -qE '^#? *VIGIL_TRUSTED_PROXIES=.*(173\.245|103\.21)'; then
  fail "the example no longer offers Cloudflare's edge ranges for the tunnel"
else
  pass "the example no longer offers Cloudflare's edge ranges for the tunnel"
fi

## ── 3. The guide ─────────────────────────────────────────────────────────

section "3/3  docs/guide.md shows the same two lines"

guide="$(cat "${REPO_ROOT}/docs/guide.md")"
assert_line "the guide names CF-Connecting-IP as the header" "$guide" "$HEADER_LINE"
assert_line "the guide trusts loopback" "$guide" "$PROXIES_LINE"

report
