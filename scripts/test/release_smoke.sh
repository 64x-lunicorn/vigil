#!/usr/bin/env bash
# scripts/test/release_smoke.sh — acceptance test for a production release.
#
# What this covers that `mix test` cannot: `mix test` runs in MIX_ENV=test with
# a pinned fixture vault and never boots an OTP release. Everything that only
# exists in a real release — runtime.exs reading the environment, the release
# boot script, config that is only evaluated at startup, the vault's git
# remote, filename encoding on the host's locale — is invisible to it. Those
# are exactly the failures that reach production, because they are the ones the
# suite is structurally blind to.
#
# So this script builds a MIX_ENV=prod release, boots it against a throwaway
# git-backed vault with its own bare remote, and drives it over HTTP the way
# verify() drives the production service: read path, write path, git push,
# reload. On success the release is known to start and serve; on failure CI
# fails before a tag is ever cut.
#
# Everything happens in a temp directory and is removed afterwards. No root, no
# systemd, no production paths, no network beyond localhost.
#
# Usage: bash scripts/test/release_smoke.sh [--keep] [--port <n>]
#   --keep   leave the work directory in place for inspection
#   --port   listener port (default 4321, deliberately not the production 4000)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KEEP=0
PORT=4321
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      KEEP=1
      shift
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

PASS=0
FAIL=0
WORK=""
RELEASE_BIN=""
SERVER_PID=""

pass() {
  echo "  ok   - $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL - $1" >&2
  [ -n "${2:-}" ] && echo "         $2" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

step() {
  echo
  echo "── $1 ──"
}

# The server must never outlive this script, however it exits: a stray BEAM
# keeps holding the port and the dets files, and every later run then fails
# with a confusing 401 against the *previous* run's vault. Owning the PID
# directly (rather than `bin/vigil daemon` + `bin/vigil stop`) keeps shutdown
# independent of Erlang distribution, which needs epmd and a resolvable
# hostname — neither guaranteed on a CI runner.
cleanup() {
  local exit_code=$?
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    if [ "$KEEP" = "1" ]; then
      echo "Work directory kept: ${WORK}"
    else
      rm -rf "$WORK"
    fi
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

for tool in git curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing: ${tool}" >&2
    exit 2
  fi
done

# A busy port would silently point every assertion below at somebody else's
# server — including a leftover BEAM from a previous, badly terminated run.
if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/.well-known/oauth-protected-resource" 2>/dev/null; then
  echo "Port ${PORT} already serves a vigil instance. Stop it or pass --port." >&2
  exit 2
fi

## ── MCP helpers (same wire format as scripts/lib.sh) ─────────────────────

BASE_URL="http://127.0.0.1:${PORT}"

# curl's -f flag is deliberately NOT used here. With -f a 401 produces an empty
# body and a non-zero exit, `jq -e` on empty input then also exits non-zero,
# and an "is this an error response?" check reads that as "no error" — a
# rejected call would silently score as a pass. Instead the status code is
# recorded next to the body and checked explicitly.
mcp_call() {
  local token="$1" tool="$2"
  # Do NOT write this as "${3:-{}}": bash ends the parameter expansion at the
  # first closing brace, so the default is parsed as "{" and a stray "}" is
  # appended to every call that DOES pass arguments. Same trap as mcp_call in
  # scripts/lib.sh — an empty default plus an explicit fallback avoids it.
  local args="${3:-}"
  [ -z "$args" ] && args="{}"
  curl -sS -o "${WORK}/.mcp_body" -w '%{http_code}' \
    -X POST "${BASE_URL}/mcp" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "mcp-session-id: smoke-$$-${RANDOM}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}" \
    > "${WORK}/.mcp_status" 2>/dev/null || true
  cat "${WORK}/.mcp_body" 2>/dev/null || true
}

mcp_status() { cat "${WORK}/.mcp_status" 2>/dev/null || echo "000"; }

# Reads the response body from stdin; non-200 counts as an error too.
mcp_is_error() {
  if [ "$(mcp_status)" != "200" ]; then
    cat > /dev/null
    return 0
  fi
  jq -e '(.result.isError == true) or (.error != null)' > /dev/null 2>&1
}

mcp_payload() { jq -r '.result.content[0].text' | jq -r "$1"; }
mcp_text() { jq -r '.result.content[0].text // .error.message // empty' 2>/dev/null || true; }
mcp_why() { echo "HTTP $(mcp_status): $(mcp_text < "${WORK}/.mcp_body")"; }

## ── 1. Build the release ─────────────────────────────────────────────────

step "1/6  Build MIX_ENV=prod release"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vigil-smoke.XXXXXX")"
VAULT="${WORK}/vault"
UPSTREAM="${WORK}/upstream.git"
STATE="${WORK}/state"
RELEASE="${WORK}/release"
mkdir -p "$STATE"

cd "$REPO_ROOT"
MIX_ENV=prod mix release --overwrite --quiet --path "$RELEASE" >/dev/null
RELEASE_BIN="${RELEASE}/bin/vigil"

if [ -x "$RELEASE_BIN" ]; then
  pass "release built and bin/vigil is executable"
else
  fail "release built and bin/vigil is executable"
  exit 1
fi

## ── 2. Throwaway vault with a real git remote ────────────────────────────

step "2/6  Provision a throwaway vault"

git init --quiet --bare -b main "$UPSTREAM"
git init --quiet -b main "$VAULT"
git -C "$VAULT" config user.name "vigil smoke"
git -C "$VAULT" config user.email "vigil-smoke@localhost"
git -C "$VAULT" config commit.gpgsign false

bash "${REPO_ROOT}/scripts/init_vault.sh" "$VAULT" >/dev/null

# A note whose *filename* carries non-ASCII characters. Without a UTF-8 locale
# the BEAM treats filenames as raw bytes: File.ls returns the name, File.read
# on that very name then fails with :enoent. That bug reached production once
# already (see the LANG comment in deploy/vigil.service) and is invisible to
# any test that only writes ASCII paths.
mkdir -p "${VAULT}/home"
cat > "${VAULT}/home/diacritics-äöü-café.md" <<'EOF'
---
type: reference
---
# Diacritics äöü café

Filename encoding regression guard for the release smoke test.
EOF

git -C "$VAULT" add -A
git -C "$VAULT" commit --quiet -m "smoke fixture"
git -C "$VAULT" remote add origin "$UPSTREAM"
git -C "$VAULT" push --quiet -u origin main
pass "vault created, committed and pushed to its bare remote"

## ── 3. Seed tokens, then boot ────────────────────────────────────────────

step "3/6  Seed tokens and start the release"

# Seeding must happen BEFORE the daemon starts: dets is single-writer, and a
# second process opening the same files writes into a copy the running node
# never sees (see the comment on vigil_seed_token in scripts/lib.sh).
RESOURCE="${BASE_URL}/mcp"
AUTH_PASSWORD="smoke-test-password-not-a-secret"

RW_TOKEN="$(MIX_ENV=prod mix vigil.seed_token \
  --state-dir "$STATE" --resource "$RESOURCE" --scope vault --ttl-days 1 | tail -1)"
RO_TOKEN="$(MIX_ENV=prod mix vigil.seed_token \
  --state-dir "$STATE" --resource "$RESOURCE" --scope vault:read --ttl-days 1 | tail -1)"

if [ -n "$RW_TOKEN" ] && [ -n "$RO_TOKEN" ] && [ "$RW_TOKEN" != "$RO_TOKEN" ]; then
  pass "seeded distinct read/write and read-only tokens"
else
  fail "seeded distinct read/write and read-only tokens"
  exit 1
fi

export VIGIL_VAULT_PATH="$VAULT"
export VIGIL_STATE_DIR="$STATE"
export VIGIL_AUTH_PASSWORD="$AUTH_PASSWORD"
export VIGIL_PORT="$PORT"
export VIGIL_GIT_REMOTE="origin"
export VIGIL_ISSUER="$BASE_URL"
export VIGIL_RESOURCE="$RESOURCE"

"$RELEASE_BIN" start > "${WORK}/server.log" 2>&1 &
SERVER_PID=$!

healthy=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  if curl -fsS "${BASE_URL}/.well-known/oauth-protected-resource" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done

if [ "$healthy" = "1" ]; then
  pass "release boots and answers OAuth discovery within 60s"
else
  fail "release boots and answers OAuth discovery within 60s"
  echo "--- server log ---" >&2
  tail -50 "${WORK}/server.log" >&2 || true
  exit 1
fi

## ── 4. Read path ─────────────────────────────────────────────────────────

step "4/6  Read path"

status="$(curl -o /dev/null -s -w '%{http_code}' -X POST "${BASE_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"current","arguments":{}}}')"
assert_eq "unauthenticated MCP call is rejected with 401" "401" "$status"

current_response="$(mcp_call "$RW_TOKEN" current)"
if echo "$current_response" | mcp_is_error; then
  fail "current answers with a valid RW token" "$(mcp_why)"
else
  pass "current answers with a valid RW token"
fi

# Reading the diacritics note by its non-ASCII path is the actual locale guard.
read_response="$(mcp_call "$RO_TOKEN" read '{"id":"home/diacritics-äöü-café.md"}')"
if echo "$read_response" | mcp_is_error; then
  fail "read of a note with a non-ASCII filename succeeds" "$(mcp_why)"
else
  pass "read of a note with a non-ASCII filename succeeds"
fi

search_response="$(mcp_call "$RO_TOKEN" search '{"query":"vigil"}')"
if echo "$search_response" | mcp_is_error; then
  fail "search returns results" "$(mcp_why)"
else
  pass "search returns results"
fi

## ── 5. Write path: SkillKey, commit, push ────────────────────────────────

step "5/6  Write path"

# do_skill_read returns the current SkillKey even when the skill does not
# exist, which is what makes bootstrapping a fresh vault possible at all.
skill_key="$(mcp_call "$RW_TOKEN" skill_read '{"name":"vigil-vault-conventions"}' \
  | grep -o 'SkillKey: [0-9a-f]*' | head -1 | cut -d' ' -f2)"

if [ -n "$skill_key" ]; then
  pass "skill_read hands out a SkillKey"
else
  fail "skill_read hands out a SkillKey"
  exit 1
fi

write_response="$(mcp_call "$RO_TOKEN" create \
  "{\"path\":\"home/smoke-denied.md\",\"type\":\"reference\",\"content\":\"# Denied\",\"skill_key\":\"${skill_key}\"}")"
# The distinction matters: the read-only token must be *accepted* as a token
# (HTTP 200) and refused by the tool on scope grounds. A 401 here would mean
# the token was simply invalid and would prove nothing about scope enforcement.
if [ "$(mcp_status)" = "200" ] && echo "$write_response" | jq -e '.result.isError == true' >/dev/null 2>&1 &&
  [ ! -f "${VAULT}/home/smoke-denied.md" ]; then
  pass "read-only token is authenticated but refused by a write tool"
else
  fail "read-only token is authenticated but refused by a write tool" "$(mcp_why)"
fi

before_sha="$(git --git-dir="$UPSTREAM" rev-parse main)"

create_response="$(mcp_call "$RW_TOKEN" create \
  "{\"path\":\"home/smoke-note.md\",\"type\":\"reference\",\"content\":\"# Smoke note\\n\\nWritten by release_smoke.sh.\",\"skill_key\":\"${skill_key}\"}")"
if echo "$create_response" | mcp_is_error; then
  fail "create writes a note with a valid SkillKey" "$(mcp_why)"
else
  pass "create writes a note with a valid SkillKey"
fi

if [ -f "${VAULT}/home/smoke-note.md" ]; then
  pass "the note exists on disk"
else
  fail "the note exists on disk"
fi

after_sha="$(git --git-dir="$UPSTREAM" rev-parse main)"
if [ "$before_sha" != "$after_sha" ]; then
  pass "the write was committed AND pushed to the git remote"
else
  fail "the write was committed AND pushed to the git remote" \
    "remote is still at ${before_sha}"
fi

## ── 5b. The authorization flow a real client actually walks ──────────────

step "5b/6  OAuth: register, authorize, consent, token, refresh"

# Every token used so far was seeded out of band through `mix vigil.seed_token`
# — the path verify() and first access take. It is not the path Claude takes.
# Dynamic registration, /authorize, the consent page, PKCE, the code exchange
# and refresh rotation are covered by the unit suite and were never once run
# against a built release, which is exactly where a value that only exists in
# MIX_ENV=prod goes wrong.

REDIRECT_URI="https://claude.ai/api/mcp/auth_callback"

# PKCE (RFC 7636, S256): a verifier, and the base64url of its SHA-256.
CODE_VERIFIER="smoke-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
CODE_CHALLENGE="$(printf '%s' "$CODE_VERIFIER" |
  openssl dgst -binary -sha256 |
  openssl base64 |
  tr '+/' '-_' |
  tr -d '=\n')"

authorize_form() {
  curl -sS "$@" -X POST "${BASE_URL}/oauth/authorize" \
    --data-urlencode "response_type=code" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "redirect_uri=${REDIRECT_URI}" \
    --data-urlencode "code_challenge=${CODE_CHALLENGE}" \
    --data-urlencode "code_challenge_method=S256" \
    --data-urlencode "state=smoke-state" \
    --data-urlencode "scope=vault" \
    --data-urlencode "decision=allow" \
    --data-urlencode "password=${CONSENT_PASSWORD}"
}

# 1. Dynamic client registration (RFC 7591).
REGISTER_RESPONSE="$(curl -sS -X POST "${BASE_URL}/oauth/register" \
  -H "Content-Type: application/json" \
  -d "{\"client_name\":\"Smoke test client\",\"redirect_uris\":[\"${REDIRECT_URI}\"]}" || true)"
CLIENT_ID="$(echo "$REGISTER_RESPONSE" | jq -r '.client_id // empty')"

if [ -n "$CLIENT_ID" ]; then
  pass "registration returns a client_id"
else
  fail "registration returns a client_id" "$REGISTER_RESPONSE"
fi

AUTHORIZE_QUERY="response_type=code&client_id=${CLIENT_ID}&redirect_uri=$(
  printf '%s' "$REDIRECT_URI" | jq -sRr @uri
)&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&state=smoke-state&scope=vault"

# 2. The consent page. A GET renders it and issues nothing.
CONSENT_PAGE="$(curl -sS "${BASE_URL}/oauth/authorize?${AUTHORIZE_QUERY}" || true)"
if echo "$CONSENT_PAGE" | grep -q 'name="password"'; then
  pass "authorize renders the consent page"
else
  fail "authorize renders the consent page" "$(echo "$CONSENT_PAGE" | head -3)"
fi

# 3. A wrong password must not mint a code.
CONSENT_PASSWORD="definitely-not-the-password"
WRONG_LOCATION="$(authorize_form -o /dev/null -D - | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')"
if printf '%s' "$WRONG_LOCATION" | grep -q '[?&]code='; then
  fail "a wrong consent password mints no code" "Location: ${WRONG_LOCATION}"
else
  pass "a wrong consent password mints no code"
fi

# 4. Consent, and read the code out of the Location header.
CONSENT_PASSWORD="$AUTH_PASSWORD"
LOCATION="$(authorize_form -o /dev/null -D - | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')"

AUTH_CODE="$(printf '%s' "$LOCATION" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
RETURNED_STATE="$(printf '%s' "$LOCATION" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')"
RETURNED_ISS="$(printf '%s' "$LOCATION" | sed -n 's/.*[?&]iss=\([^&]*\).*/\1/p')"

if [ -n "$AUTH_CODE" ]; then
  pass "consent redirects to the client with a code"
else
  fail "consent redirects to the client with a code" "Location: ${LOCATION}"
fi

assert_eq "the state is handed back unchanged" "smoke-state" "$RETURNED_STATE"

# RFC 9207. The authorization-server metadata advertises this, so a client is
# entitled to reject a response that arrives without it.
if [ -n "$RETURNED_ISS" ]; then
  pass "the redirect carries the iss parameter (RFC 9207)"
else
  fail "the redirect carries the iss parameter (RFC 9207)" "Location: ${LOCATION}"
fi

# 5. Redeem the code with the verifier.
# curl already writes 000 into %{http_code} on a transport failure, so no
# `|| echo` is needed — appending one produced "000000". The body is truncated
# first so that a failed request cannot be read as the previous one's answer.
redeem_code() {
  : >"${WORK}/.token_body"
  curl -sS -o "${WORK}/.token_body" -w '%{http_code}' -X POST "${BASE_URL}/oauth/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${AUTH_CODE}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "redirect_uri=${REDIRECT_URI}" \
    --data-urlencode "code_verifier=${CODE_VERIFIER}" 2>/dev/null
}

REDEEM_STATUS="$(redeem_code)"
TOKEN_RESPONSE="$(cat "${WORK}/.token_body" 2>/dev/null || true)"
FLOW_ACCESS="$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"
FLOW_REFRESH="$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token // empty')"

assert_eq "the code exchange answers 200" "200" "$REDEEM_STATUS"

if [ -n "$FLOW_ACCESS" ] && [ -n "$FLOW_REFRESH" ]; then
  pass "the code redeems into an access and a refresh token"
else
  fail "the code redeems into an access and a refresh token" "$TOKEN_RESPONSE"
fi

assert_eq "the token type is Bearer" "Bearer" \
  "$(echo "$TOKEN_RESPONSE" | jq -r '.token_type // empty')"

# 6. The code is one-time use.
assert_eq "replaying the code is refused" "400" "$(redeem_code)"

# 7. The token the flow produced is accepted where it counts.
mcp_call "$FLOW_ACCESS" "current" > /dev/null
if [ "$(mcp_status)" = "200" ]; then
  pass "the flow's access token is accepted by /mcp"
else
  fail "the flow's access token is accepted by /mcp" "$(mcp_why)"
fi

# 8. Rotation.
refresh_with() {
  : >"${WORK}/.token_body"
  curl -sS -o "${WORK}/.token_body" -w '%{http_code}' -X POST "${BASE_URL}/oauth/token" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$1" \
    --data-urlencode "client_id=${CLIENT_ID}" 2>/dev/null
}

REFRESH_STATUS="$(refresh_with "$FLOW_REFRESH")"
REFRESH_RESPONSE="$(cat "${WORK}/.token_body" 2>/dev/null || true)"
ROTATED_ACCESS="$(echo "$REFRESH_RESPONSE" | jq -r '.access_token // empty')"
ROTATED_REFRESH="$(echo "$REFRESH_RESPONSE" | jq -r '.refresh_token // empty')"

assert_eq "the refresh exchange answers 200" "200" "$REFRESH_STATUS"

if [ -n "$ROTATED_ACCESS" ] && [ -n "$ROTATED_REFRESH" ] && [ "$ROTATED_REFRESH" != "$FLOW_REFRESH" ]; then
  pass "the refresh token rotates into a new pair"
else
  fail "the refresh token rotates into a new pair" "$REFRESH_RESPONSE"
fi

mcp_call "$ROTATED_ACCESS" "current" > /dev/null
if [ "$(mcp_status)" = "200" ]; then
  pass "the rotated access token is accepted by /mcp"
else
  fail "the rotated access token is accepted by /mcp" "$(mcp_why)"
fi

# 9. Replaying the spent refresh token revokes the family (RFC 9700 §4.14.2).
# This is the defence rotation exists for, and the one place it can be checked
# end to end: a replay is the moment the server learns that exactly one of two
# holders is an attacker, and it cannot tell which.
assert_eq "replaying the spent refresh token is refused" "400" "$(refresh_with "$FLOW_REFRESH")"

# Guarded: an empty ROTATED_ACCESS — step 8 having regressed and returned no
# token — also gets a 401, and would score the strongest assertion in this
# block as a pass it did not earn.
if [ -z "$ROTATED_ACCESS" ]; then
  fail "the replay revoked the whole token family" "no rotated token to revoke"
else
  mcp_call "$ROTATED_ACCESS" "current" > /dev/null
  if [ "$(mcp_status)" = "200" ]; then
    fail "the replay revoked the whole token family" "the rotated access token still works"
  else
    pass "the replay revoked the whole token family"
  fi
fi

## ── 6. reload, then shut down cleanly ────────────────────────────────────

step "6/6  Reload and shutdown"

reload_response="$(mcp_call "$RW_TOKEN" reload)"
if echo "$reload_response" | mcp_is_error; then
  fail "reload succeeds" "$(mcp_why)"
else
  pull_failed="$(echo "$reload_response" | mcp_payload '.pull_failed // empty' 2>/dev/null || true)"
  if [ -z "$pull_failed" ] || [ "$pull_failed" = "null" ]; then
    pass "reload reports no pull_failed"
  else
    fail "reload reports no pull_failed" "$pull_failed"
  fi
fi

# SIGTERM is what systemd sends on `systemctl stop` before ExecStop finishes,
# so a release that does not exit on it hangs the deploy. Checked explicitly.
kill "$SERVER_PID" 2>/dev/null || true
stopped=0
for _ in $(seq 1 20); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    stopped=1
    break
  fi
  sleep 1
done
if [ "$stopped" = "1" ]; then
  pass "release shuts down on SIGTERM within 20s"
else
  fail "release shuts down on SIGTERM within 20s"
fi
SERVER_PID=""
## ── Summary ──────────────────────────────────────────────────────────────

echo
echo "════════════════════════════════════════"
echo "  passed: ${PASS}   failed: ${FAIL}"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
