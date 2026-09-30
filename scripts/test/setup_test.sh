#!/usr/bin/env bash
# scripts/test/setup_test.sh — what setup.sh does to a host that nothing else
# undoes.
#
# setup.sh needs root, Debian 13, apt and the network, so it is not driven
# here: what is asserted is its own text, as secrets_test.sh and
# proxy_settings_test.sh do for init.sh, and the documents that say what it
# does.
#
# Usage: bash scripts/test/setup_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_SH="${REPO_ROOT}/scripts/setup.sh"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

# Whether a line appears in the text on a line of its own — not commented
# out, not inside a longer line. The text comes with its indentation removed.
has_line() {
  grep -qxF -- "$2" <<<"$1"
}

assert_line() {
  if has_line "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected a line of its own: $3"
  fi
}

## ── 1. epmd ──────────────────────────────────────────────────────────────

section "1/2  setup.sh leaves nothing listening on epmd's port"

# Debian's erlang-base enables epmd.socket, which listens on 4369 on every
# interface; the release's -start_epmd false does not close it.
setup_text="$(grep -v '^ *#' "$SETUP_SH" | sed 's/^ *//')"
assert_line "stops epmd.socket and epmd.service" "$setup_text" \
  'systemctl disable --now epmd.socket epmd.service >/dev/null 2>&1 || true'
assert_line "and masks both, so no upgrade starts them again" "$setup_text" \
  'systemctl mask epmd.socket epmd.service >/dev/null'

# After the packages that bring epmd, before the service is enabled.
line_of() { grep -n -m1 -F -- "$1" "$SETUP_SH" | cut -d: -f1; }
# shellcheck disable=SC2016 # setup.sh's own text, not an expansion
install_at="$(line_of 'apt-get install -y --no-install-recommends "${PACKAGES[@]}"')"
mask_at="$(line_of 'systemctl mask epmd.socket epmd.service')"
enable_at="$(line_of 'systemctl enable vigil >/dev/null')"
if [ -n "$install_at" ] && [ -n "$mask_at" ] && [ -n "$enable_at" ] &&
  [ "$install_at" -lt "$mask_at" ] && [ "$mask_at" -lt "$enable_at" ]; then
  pass "after the Erlang packages are installed, before vigil is enabled"
else
  fail "after the Erlang packages are installed, before vigil is enabled" \
    "install ${install_at:-?}, mask ${mask_at:-?}, enable ${enable_at:-?}"
fi

## ── 2. The guide ─────────────────────────────────────────────────────────

section "2/2  docs/guide.md says so, and how to check"

guide="$(cat "${REPO_ROOT}/docs/guide.md")"
case "$guide" in
  *"epmd.socket"*"sudo ss -ltnp | grep -E 'beam|epmd'"*)
    pass "the guide names epmd.socket and the ss check" ;;
  *) fail "the guide names epmd.socket and the ss check" ;;
esac

report
