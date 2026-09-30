#!/usr/bin/env bash
# scripts/test/grants_test.sh — scripts/grants.sh, the operator's command for
# listing and revoking grants and clients.
#
# It drives the real script against a throwaway prefix. VIGIL_GRANTS_TEST_STUBS=1
# (see grants.sh) replaces root, the service account and systemd; the release
# is a fake bin/vigil that records the expression it was asked to evaluate and
# answers what the test tells it to. What the node does with that expression
# is Vigil.OAuth.GrantsTest's, that the expression names functions the
# application exports is Vigil.ScriptCallsTest's, and that a real release
# answers it is release_smoke.sh's. What is left, and checked here: which
# arguments the script accepts, that it asks before revoking everything, that
# an id reaches the node as data, and which exit status the operator sees.
#
# It also holds init.sh to what its --keep-token promises: no token for the
# owner, only the two short-lived ones verify() uses.
#
# Usage: bash scripts/test/grants_test.sh [--keep]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GRANTS_SH="${REPO_ROOT}/scripts/grants.sh"
INIT_SH="${REPO_ROOT}/scripts/init.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK=""

# Two codes for one false positive, as in update_test.sh.
# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap below
cleanup() {
  if [ -n "$WORK" ] && [ "$KEEP" = "0" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  elif [ -n "$WORK" ] && [ "$KEEP" = "1" ]; then
    echo "Work directory kept: ${WORK}"
  fi
}
trap cleanup EXIT INT TERM

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-grants-test.XXXXXX")" && pwd -P)"
PREFIX="${WORK}/opt/vigil"
RELEASE="${PREFIX}/releases/r1"

## ── The throwaway host ───────────────────────────────────────────────────

# A release whose `rpc` records the expression and answers from files: the
# answer it prints, and the status it exits with.
mkdir -p "${RELEASE}/bin" "${WORK}/state"
cat >"${RELEASE}/bin/vigil" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/.." && pwd)"
[ "$1" = "rpc" ] || exit 64
printf '%s\n' "$2" >"${here}/.rpc-expr"
cat "${here}/.rpc-answer" 2>/dev/null || true
exit "$(cat "${here}/.rpc-exit" 2>/dev/null || echo 0)"
EOF
chmod +x "${RELEASE}/bin/vigil"
ln -s "$RELEASE" "${PREFIX}/current"

service_up() { : >"${PREFIX}/.service-active"; }
service_down() { rm -f "${PREFIX}/.service-active"; }
answer() { printf '%s\n' "$1" >"${RELEASE}/.rpc-answer"; }
rpc_exits() { printf '%s\n' "$1" >"${RELEASE}/.rpc-exit"; }
forget_rpc() { rm -f "${RELEASE}/.rpc-expr" "${RELEASE}/.rpc-answer" "${RELEASE}/.rpc-exit"; }
rpc_called() { [ -f "${RELEASE}/.rpc-expr" ]; }

# The words the node was sent, decoded the way Vigil.OAuth.Grants.rpc/3
# decodes them: the one string literal in the expression, base64.
sent_words() {
  sed -n 's/.*"\([A-Za-z0-9+\/=]*\)")$/\1/p' "${RELEASE}/.rpc-expr" | openssl base64 -d -A
}

# Runs grants.sh; stdout+stderr land in $OUT, the exit status in $RC.
run() {
  set +e
  OUT="$(VIGIL_GRANTS_TEST_STUBS=1 VIGIL_PREFIX="$PREFIX" VIGIL_STATE_DIR="${WORK}/state" \
    bash "$GRANTS_SH" "$@" 2>&1 </dev/null)"
  RC=$?
  set -e
}

run_typing() {
  local typed="$1"
  shift
  set +e
  OUT="$(printf '%s\n' "$typed" | VIGIL_GRANTS_TEST_STUBS=1 VIGIL_PREFIX="$PREFIX" \
    VIGIL_STATE_DIR="${WORK}/state" bash "$GRANTS_SH" "$@" 2>&1)"
  RC=$?
  set -e
}

## ── 1. Arguments ─────────────────────────────────────────────────────────

section "1/5  Arguments"

service_up

run --help
assert_eq "--help exits 0" "0" "$RC"

for bad in "" "bogus" "revoke" "delete-client" "list extra" "revoke-all --force" "revoke a b"; do
  forget_rpc
  IFS=' ' read -r -a words <<<"$bad"
  run "${words[@]+"${words[@]}"}"
  assert_eq "'${bad}' is refused with exit 2" "2" "$RC"
  if rpc_called; then
    fail "'${bad}' reaches the node" "it must be refused before"
  else
    pass "'${bad}' does not reach the node"
  fi
done

## ── 2. The service must be running ───────────────────────────────────────

section "2/5  The running node"

service_down
forget_rpc
run list
assert_eq "a stopped service is reported with exit 2" "2" "$RC"
if rpc_called; then fail "a stopped service is not called"; else pass "a stopped service is not called"; fi
service_up

## ── 3. What reaches the node, and what comes back ────────────────────────

section "3/5  The call"

forget_rpc
answer "GRANT  CLIENT  CLIENT ID  SCOPE  ISSUED  EXPIRES"
run list
assert_eq "list exits 0" "0" "$RC"
assert_eq "list prints the node's answer" "GRANT  CLIENT  CLIENT ID  SCOPE  ISSUED  EXPIRES" "$OUT"
assert_eq "list sends the word list" "list" "$(sent_words)"

if grep -q '^Vigil\.OAuth\.Grants\.rpc(Vigil\.OAuth\.Store\.over_tables(), System\.system_time(:second), "' "${RELEASE}/.rpc-expr"; then
  pass "the expression calls Vigil.OAuth.Grants.rpc/3 over the production tables"
else
  fail "the expression calls Vigil.OAuth.Grants.rpc/3 over the production tables" "$(cat "${RELEASE}/.rpc-expr")"
fi

# An id with a quote and an interpolation in it reaches the node as data.
hostile='x"<>System.halt()<>"#{1}'
forget_rpc
answer "Revoked grant."
run revoke "$hostile"
assert_eq "revoke exits 0 on the node's success" "0" "$RC"
assert_eq "the id reaches the node unchanged, after the command" "revoke
${hostile}" "$(sent_words)"
if grep -qF 'System.halt' "${RELEASE}/.rpc-expr"; then
  fail "the id is never part of the evaluated expression" "$(cat "${RELEASE}/.rpc-expr")"
else
  pass "the id is never part of the evaluated expression"
fi

forget_rpc
answer "error: no grant nope (see the list command)"
run revoke nope
assert_eq "a refusal from the node exits 1" "1" "$RC"
assert_eq "and is printed" "error: no grant nope (see the list command)" "$OUT"

forget_rpc
answer "Deleted client c-1 and revoked its 2 grant(s)."
run delete-client c-1
assert_eq "delete-client exits 0" "0" "$RC"
assert_eq "delete-client sends the client id" "delete-client
c-1" "$(sent_words)"

forget_rpc
rpc_exits 1
run clients
assert_eq "an rpc that fails exits 1" "1" "$RC"

## ── 4. revoke-all asks first ─────────────────────────────────────────────

section "4/5  revoke-all"

forget_rpc
run_typing "no" revoke-all
assert_eq "anything but yes aborts with exit 4" "4" "$RC"
if rpc_called; then fail "an aborted revoke-all revokes nothing"; else pass "an aborted revoke-all revokes nothing"; fi

forget_rpc
answer "Revoked every grant (3 live) and every unredeemed authorization code."
run_typing "yes" revoke-all
assert_eq "typing yes revokes" "0" "$RC"
assert_eq "revoke-all sends the word revoke-all" "revoke-all" "$(sent_words)"

forget_rpc
answer "Revoked every grant (0 live) and every unredeemed authorization code."
run revoke-all --yes
assert_eq "--yes revokes without asking" "0" "$RC"
assert_eq "--yes is not sent to the node" "revoke-all" "$(sent_words)"

## ── 5. init.sh --keep-token mints nothing long-lived ─────────────────────

# init.sh needs root, a service account and a booted host to run for real, so
# what is asserted is its text, as secrets_test.sh does: under --keep-token
# every token it seeds is given 900 seconds.
section "5/5  init.sh --keep-token"

keep_branch="$(awk '/^  if \[ "\$KEEP_TOKEN" = "1" \]; then$/{on=1; next} on && /^  else$/{exit} on' "$INIT_SH")"
seeded="$(printf '%s\n' "$keep_branch" | grep -c 'vigil_seed_token' || true)"
# shellcheck disable=SC2016 # $RESOURCE is matched literally, not expanded
short="$(printf '%s\n' "$keep_branch" | grep -c 'vigil_seed_token "\$RESOURCE" [a-z:]* 900)' || true)"

assert_eq "the --keep-token branch seeds the two tokens verify() needs" "2" "$seeded"
assert_eq "and both live 900 seconds" "2" "$short"

report
