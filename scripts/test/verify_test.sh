#!/usr/bin/env bash
# scripts/test/verify_test.sh — the acceptance function, checked check by check.
#
# verify() decides whether a delivery stands or is rolled back (update.sh step
# 7), and it was a single 210-line block that could only run against a real
# vault host: systemd, journald, Cloudflare, a git remote and a booted release.
# So the one thing nothing could test was the thing that decides. It is twelve
# functions now, and this drives each of them against both outcomes.
#
# What stays real: every check's own logic — the conditions, the comparisons,
# the verdict it prints and the code it answers with. What is replaced is only
# what a check reaches for outside the process: `systemctl`, `journalctl`,
# `curl`, `mcp_call` and `as_vigil` are shell functions here, and the
# installation layout points at a temp directory (scripts/lib.sh states it
# once, which is what makes that possible).
#
# The order matters and is asserted too: check 7 discovers the writable domain
# that 9, 10 and 12 reuse, so a reordering that moved 7 after them would leave
# three checks testing a default they were never meant to use.
#
# Usage: bash scripts/test/verify_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-verify-test.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${WORK:?}"; }

## ── The layout, pointed at the temp dir ──────────────────────────────────

export VIGIL_PREFIX="${WORK}/opt/vigil"
export VIGIL_STATE_DIR="${WORK}/var/lib/vigil"
export VIGIL_VAULT_DIR="${WORK}/var/lib/vigil/vault"
export VIGIL_ENV_FILE="${WORK}/etc/env"
export VIGIL_SERVICE_NAME="vigil-under-test"
mkdir -p "$VIGIL_STATE_DIR" "$VIGIL_VAULT_DIR/admin" "$VIGIL_VAULT_DIR/skills"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

# lib.sh installs `trap summary EXIT` when it is sourced, so the trap has to go
# in after it — and has to keep the summary, which is what prints the run's
# result. Installed before it, this one was silently replaced and every run left
# its temp directory behind.
trap 'summary; cleanup' EXIT INT TERM

## ── The stand-ins ────────────────────────────────────────────────────────

# Everything a check reaches for outside the process. Each reads a file under
# $WORK, so a case sets an outcome by writing one.
SERVICE_STATE="${WORK}/service-active"
JOURNAL="${WORK}/journal"
HTTP_STATUS="${WORK}/http-status"
MCP_SCRIPT="${WORK}/mcp-responses"
GIT_REMOTE_OK="${WORK}/git-remote-ok"
UNPUSHED="${WORK}/unpushed"

# shellcheck disable=SC2329 # called by the checks in lib.sh
systemctl() {
  case "${1:-}" in
    is-active) [ -f "$SERVICE_STATE" ] ;;
    *) : ;;
  esac
}

# shellcheck disable=SC2329 # called by the checks in lib.sh
journalctl() { cat "$JOURNAL" 2>/dev/null || true; }

# shellcheck disable=SC2329 # called by the checks in lib.sh
curl() {
  # verify_public_endpoint_protected is the only caller, and it asks for the
  # status code alone.
  cat "$HTTP_STATUS" 2>/dev/null || echo "000"
}

# as_vigil runs directly, except for the two git questions the checks ask,
# which are answered from files.
# shellcheck disable=SC2329 # called by the checks in lib.sh
as_vigil() {
  case "${1:-} ${4:-}" in
    "git ls-remote") [ -f "$GIT_REMOTE_OK" ] ;;
    "git rev-list") cat "$UNPUSHED" 2>/dev/null || echo "?" ;;
    *) "$@" ;;
  esac
}

# One response per tool, written by the case under test:
#   <tool> <json>
# shellcheck disable=SC2329 # called by the checks in lib.sh
mcp_call() {
  local tool="$3"
  local line
  line="$(grep -m1 "^${tool} " "$MCP_SCRIPT" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    return 1
  fi
  echo "${line#"${tool} "}"
}

reset_stubs() {
  rm -f "$SERVICE_STATE" "$JOURNAL" "$HTTP_STATUS" "$MCP_SCRIPT" "$GIT_REMOTE_OK" "$UNPUSHED"
  : >"$MCP_SCRIPT"
  : >"$JOURNAL"
}

# The real wire shape, because that is what mcp_payload and mcp_error_text
# parse. Vigil.MCP.Server encodes `%{result: value}` merged with the envelope
# into result.content[0].text as a *string* — so the tool's own JSON is nested
# twice, and a filter like `.result.pull_failed` is applied to the inner
# document, not the outer one. A flatter stub would have let check 5 pass
# against a response the server never sends.
mcp_responds() {
  local tool="$1" payload="$2"
  local inner
  inner="$(printf '{"result":%s,"now":"2026-01-01T00:00:00Z"}' "$payload")"
  printf '%s {"result":{"content":[{"type":"text","text":%s}],"isError":false}}\n' \
    "$tool" "$(printf '%s' "$inner" | jq -Rs .)" >>"$MCP_SCRIPT"
}

# An error carries `%{error: message}` through the same envelope, and
# mcp_error_text reads the whole inner document back out as one string.
mcp_errors() {
  local tool="$1" message="$2"
  local inner
  inner="$(jq -nc --arg m "$message" '{error: $m, now: "2026-01-01T00:00:00Z"}')"
  printf '%s {"result":{"content":[{"type":"text","text":%s}],"isError":true}}\n' \
    "$tool" "$(printf '%s' "$inner" | jq -Rs .)" >>"$MCP_SCRIPT"
}


# What verify() reads about the deployment it is checking.
VIGIL_VAULT="$VIGIL_VAULT_DIR"
VIGIL_LOCAL_URL="http://localhost:4000"
VIGIL_RESOURCE="https://vault.example/mcp"
VIGIL_GIT_REMOTE="github"
VIGIL_ALLOW_UNPROTECTED=0
VIGIL_RW_TOKEN="rw-token"
VIGIL_RO_TOKEN="ro-token"

# Runs one check with stdout captured, in *this* shell: checks 7 and 12 hand
# VIGIL_TEST_DOMAIN to each other through a global, and a command substitution
# would run them in a subshell and drop it.
RC=0
run_check() {
  set +e
  "$1" >"${WORK}/out.txt" 2>&1
  RC=$?
  set -e
}

assert_check() {
  local description="$1" check="$2" expected="$3"
  run_check "$check"
  local rc="$RC"
  if [ "$rc" = "$expected" ]; then
    pass "$description"
  else
    fail "$description" "expected exit ${expected}, got ${rc}: $(tail -1 "${WORK}/out.txt")"
  fi
}

assert_output() {
  local description="$1" needle="$2"
  if grep -q "$needle" "${WORK}/out.txt"; then
    pass "$description"
  else
    fail "$description" "not in output: ${needle}"
  fi
}

## ── 1. Service active ────────────────────────────────────────────────────

section "1/12  Service active"
reset_stubs
: >"$SERVICE_STATE"
assert_check "passes while the unit is active" verify_service_active 0
reset_stubs
assert_check "fails once it is not" verify_service_active 1
assert_output "names the journal command to run" "journalctl -u vigil-under-test"

## ── 2. Public endpoint protected ─────────────────────────────────────────

section "2/12  Public endpoint sits behind Cloudflare Access"
reset_stubs
echo "403" >"$HTTP_STATUS"
assert_check "403 is the expected answer" verify_public_endpoint_protected 0

reset_stubs
echo "401" >"$HTTP_STATUS"
assert_check "401 fails — the request reached Elixir" verify_public_endpoint_protected 1
assert_output "says Access is not in front" "Cloudflare Access is NOT in front"

reset_stubs
echo "200" >"$HTTP_STATUS"
assert_check "200 fails — completely unprotected" verify_public_endpoint_protected 1
assert_output "says the endpoint is unprotected" "completely unprotected"

reset_stubs
echo "200" >"$HTTP_STATUS"
VIGIL_ALLOW_UNPROTECTED=1
assert_check "--allow-unprotected skips it rather than failing" verify_public_endpoint_protected 0
VIGIL_ALLOW_UNPROTECTED=0

## ── 3. Local call answers ────────────────────────────────────────────────

section "3/12  A valid token is answered locally"
reset_stubs
mcp_responds current '{}'
assert_check "passes when current answers" verify_local_call_answers 0
reset_stubs
assert_check "fails when it does not" verify_local_call_answers 1

## ── 4. Git remote reachable ──────────────────────────────────────────────

section "4/12  The vault's git remote is reachable"
reset_stubs
: >"$GIT_REMOTE_OK"
assert_check "passes when ls-remote succeeds" verify_git_remote_reachable 0
reset_stubs
assert_check "fails when it does not" verify_git_remote_reachable 1
assert_output "points at the key as the likely cause" "deploy key missing"

## ── 5. reload pulls ──────────────────────────────────────────────────────

section "5/12  reload reports no pull_failed"
reset_stubs
mcp_responds reload '{}'
assert_check "passes when reload is clean" verify_reload_pulls 0

reset_stubs
mcp_responds reload '{"pull_failed":"host key verification failed"}'
assert_check "fails when reload reports a failed pull" verify_reload_pulls 1
assert_output "quotes the reason the server gave" "host key verification failed"

## ── 6. Chunk count ───────────────────────────────────────────────────────

section "6/12  The chunk count is advisory, and remembered"
reset_stubs
# Verbatim from Vigil.Store's own log line (lib/vigil/store.ex) — lowercase
# `chunks`. A fabricated spelling here is what let the check pass while the
# pattern it uses matched nothing on a real host.
echo "vigil: 4 domains (admin, home, journal, training), 12 notes, 41 chunks" >"$JOURNAL"
assert_check "passes on the first run, with nothing to compare against" verify_chunk_count 0

if [ "$(cat "${VIGIL_STATE_DIR}/.last_chunks")" = "41" ]; then
  pass "records the count for the next run"
else
  fail "records the count for the next run" "got $(cat "${VIGIL_STATE_DIR}/.last_chunks" 2>/dev/null)"
fi

echo "vigil: 4 domains (admin, home, journal, training), 12 notes, 9 chunks" >"$JOURNAL"
assert_check "a drop warns rather than failing the delivery" verify_chunk_count 0
assert_output "says the count dropped" "chunk count dropped from 41 to 9"

reset_stubs
assert_check "an unreadable count warns rather than failing" verify_chunk_count 0
assert_output "says it could not read the count" "could not read the chunk count"

## ── 7. Write and push ────────────────────────────────────────────────────

section "7/12  A note is written, pushed and deleted again"
reset_stubs
mcp_responds create '{"path":"admin/verify-test.md"}'
mcp_responds delete_note '{}'
assert_check "passes when the write goes through" verify_write_and_push 0
assert_output "names the domain it used" "domain: admin"

if [ "${VIGIL_TEST_DOMAIN}" = "admin" ]; then
  pass "publishes the writable domain for checks 9, 10 and 12"
else
  fail "publishes the writable domain for checks 9, 10 and 12" "got '${VIGIL_TEST_DOMAIN}'"
fi

reset_stubs
mcp_errors create 'domain has a naming pattern'
assert_check "fails when no domain accepts a write" verify_write_and_push 1
assert_output "quotes the last error it saw" "naming pattern"

# skills/ is not a domain, and neither is anything starting with . or _.
if grep -q "skills" "${WORK}/out.txt"; then
  fail "skills/ is not offered as a write target"
else
  pass "skills/ is not offered as a write target"
fi

## ── 8. Nothing unpushed ──────────────────────────────────────────────────

section "8/12  The vault has no unpushed commits"
reset_stubs
echo "0" >"$UNPUSHED"
assert_check "passes at zero" verify_nothing_unpushed 0
reset_stubs
echo "3" >"$UNPUSHED"
assert_check "fails with commits still local" verify_nothing_unpushed 1
assert_output "says how many" "3 local commits not pushed"

## ── 9. SkillKey enforced ─────────────────────────────────────────────────

section "9/12  A write without a skill_key is refused"
reset_stubs
mcp_errors create 'SkillKey missing or stale'
assert_check "passes when the gate refuses it by name" verify_skill_key_enforced 0

reset_stubs
mcp_responds create '{"path":"admin/verify-nope.md"}'
assert_check "fails when the write is accepted" verify_skill_key_enforced 1

# An error that is not the SkillKey gate must not be read as the gate working.
reset_stubs
mcp_errors create 'domain does not exist'
assert_check "fails when some other error refused it" verify_skill_key_enforced 1

## ── 10. Read-only token refused ──────────────────────────────────────────

section "10/12  The read-only token cannot write"
reset_stubs
mcp_errors create 'insufficient scope'
assert_check "passes when the write is refused" verify_read_only_token_refused 0
reset_stubs
mcp_responds create '{"path":"admin/verify-ro.md"}'
assert_check "fails when the read-only token could write" verify_read_only_token_refused 1
assert_output "calls it a role separation failure" "Role separation is not working"

## ── 11. Domain drift ─────────────────────────────────────────────────────

section "11/12  _domains.yml and the directories agree"
reset_stubs
echo "vigil: started" >"$JOURNAL"
assert_check "passes on a quiet log" verify_no_domain_drift 0

echo "domain 'phantom' has no matching directory" >"$JOURNAL"
assert_check "fails when the log reports drift" verify_no_domain_drift 1

echo "directory 'garden' has no entry in _domains.yml" >"$JOURNAL"
assert_check "fails on drift in the other direction too" verify_no_domain_drift 1

## ── 12. Survives a write error ───────────────────────────────────────────

section "12/12  A failed write does not take the Store down"
reset_stubs
VIGIL_TEST_DOMAIN="admin"
mcp_errors create 'permission denied'
mcp_responds search '{"hits":[]}'

# Deliberately not 0750: the check used to restore that mode unconditionally,
# and a fixture that already had it could not tell the difference between
# putting the mode back and overwriting it with a guess.
chmod 0705 "${VIGIL_VAULT_DIR}/admin"

assert_check "passes when search still answers afterwards" verify_survives_write_error 0

MODE="$(stat -c '%a' "${VIGIL_VAULT_DIR}/admin" 2>/dev/null || stat -f '%Lp' "${VIGIL_VAULT_DIR}/admin")"
if [ "$MODE" = "705" ]; then
  pass "puts the domain's own permissions back, not a guessed mode"
else
  fail "puts the domain's own permissions back, not a guessed mode" "left mode ${MODE}"
fi

reset_stubs
VIGIL_TEST_DOMAIN="admin"
mcp_errors create 'permission denied'
assert_check "fails when search no longer answers" verify_survives_write_error 1
assert_output "calls it a crash-safety failure" "Crash safety not effective"

reset_stubs
VIGIL_TEST_DOMAIN=""
assert_check "fails when check 7 found no writable domain" verify_survives_write_error 1
assert_output "says why it was skipped" "check 7 found no writable domain"

## ── The list itself ──────────────────────────────────────────────────────

section "The check list"

EXPECTED_ORDER="verify_service_active verify_public_endpoint_protected verify_local_call_answers verify_git_remote_reachable verify_reload_pulls verify_chunk_count verify_write_and_push verify_nothing_unpushed verify_skill_key_enforced verify_read_only_token_refused verify_no_domain_drift verify_survives_write_error"

# Check 7 discovers the domain that 9, 10 and 12 reuse, so the order is part of
# what the checks mean, not a presentation detail.
# IFS is $'\n\t' in these scripts, so "${array[*]}" joins with a newline.
ACTUAL_ORDER="$(IFS=' ' && echo "${VIGIL_VERIFY_CHECKS[*]}")"
if [ "$ACTUAL_ORDER" = "$EXPECTED_ORDER" ]; then
  pass "twelve checks, in the order the later ones depend on"
else
  fail "twelve checks, in the order the later ones depend on" "$ACTUAL_ORDER"
fi

# One assertion, and it reflects the loop: a name that resolves to nothing is
# collected rather than reported on the spot, so removing a verify_* function
# turns this red instead of recording a failure and a pass together.
UNDEFINED=""
for check in "${VIGIL_VERIFY_CHECKS[@]}"; do
  if ! declare -F "$check" >/dev/null; then
    UNDEFINED="${UNDEFINED:+${UNDEFINED} }${check}"
  fi
done
if [ -z "$UNDEFINED" ]; then
  pass "every name in the list is a function that exists"
else
  fail "every name in the list is a function that exists" "not defined: ${UNDEFINED}"
fi

## ── Summary ──────────────────────────────────────────────────────────────

report
