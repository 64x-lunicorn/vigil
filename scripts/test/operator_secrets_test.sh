#!/usr/bin/env bash
# scripts/test/operator_secrets_test.sh — the operator scripts never expose a
# secret, and an operator's answer stays a value.
#
# Where a secret used to leak: verify() handed bearer tokens to curl as
# arguments, which every local user reads in `ps`; --verbose traced the env
# file as update.sh sourced it, and every token; answers typed into init.sh
# were spliced into `bash -c` strings and into the env file root sources. And
# there was no way to rotate one secret without init.sh --force rewriting the
# whole file. What is checked here:
#
#   1. no token and no SkillKey is ever a word in curl's argument vector —
#      a curl on PATH records what it was given, and a real curl sends what
#      a local listener then reads back;
#   2. a run under --verbose traces no secret: verify(), update.sh sourcing
#      the env file, rotate_secret.sh;
#   3. a quote, a $(…) or a backtick in an answer ends up as that value, in
#      the env file and as an argument to the service account's command;
#   4. rotate_secret.sh replaces one line, keeps every other, restarts the
#      service, and says it revokes no token;
#   5. what init.sh --force keeps: env_file_update's rules, and the restart.
#
# Everything happens in a temp directory. No root, no systemd, no network but
# loopback.
#
# Usage: bash scripts/test/operator_secrets_test.sh

# The stand-ins go on PATH inside subshells only, on purpose: the suite itself
# keeps the real tools.
# shellcheck disable=SC2030,SC2031

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-secrets-test.XXXXXX")" && pwd -P)"
SERVER_PID=""

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "${WORK:?}"
}

BIN="${WORK}/bin"
mkdir -p "$BIN"

export VIGIL_PREFIX="${WORK}/opt/vigil"
export VIGIL_STATE_DIR="${WORK}/state"
export VIGIL_VAULT_DIR="${WORK}/state/vault"
export VIGIL_ENV_FILE="${WORK}/env"
export VIGIL_SERVICE_NAME="vigil-under-test"
mkdir -p "$VIGIL_PREFIX" "${VIGIL_VAULT_DIR}/admin"

# The values no output may contain. Distinct enough that a match is never an
# accident.
RW_TOKEN="rw-TOKEN-4f1c2e"
RO_TOKEN="ro-TOKEN-9b7d31"
SKILL_KEY="c0ffee5ecret"
PASSWORD="pw-SECRET-7a1e0b99c4"
SKILLKEY_SECRET="sk-SECRET-2d6f5a81e3"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"
# lib.sh installs `trap summary EXIT`; this suite's verdict is `report`'s.
trap cleanup EXIT INT TERM

# How many bytes a base64 value decodes to, or 0 if it is not base64.
decoded_bytes() {
  printf '%s\n' "$1" | openssl base64 -d 2>/dev/null | wc -c | tr -d ' '
}

# not_in <description> <file> <value...> — none of the values appears in file.
not_in() {
  local description="$1" file="$2" value found=""
  shift 2
  for value in "$@"; do
    if grep -qF -- "$value" "$file"; then
      found="${found:+${found}, }${value}"
    fi
  done
  if [ -z "$found" ]; then
    pass "$description"
  else
    fail "$description" "found: ${found}"
  fi
}

## ── A curl on PATH that records what it is given ─────────────────────────

# Each call's argument vector, one word per line, and what it read on stdin.
# It answers as the server would: the initialize response's headers when
# asked to dump them, a tool result otherwise, a status code when asked for
# one.
CURL_LOG="${WORK}/curl"
mkdir -p "$CURL_LOG"
cat >"${BIN}/curl" <<'CURL'
#!/usr/bin/env bash
n="$(ls "$CURL_LOG" | wc -l | tr -d ' ')"
printf '%s\n' "$@" >"${CURL_LOG}/${n}.argv"
reads_stdin=0 dumps_headers=0 wants_status=0
for a in "$@"; do
  case "$a" in
    -K) reads_stdin=1 ;;
    -D) dumps_headers=1 ;;
    *http_code*) wants_status=1 ;;
  esac
done
if [ "$reads_stdin" = "1" ]; then cat >"${CURL_LOG}/${n}.stdin"; fi
if [ "$dumps_headers" = "1" ]; then
  printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: sid-7\r\n\r\n'
elif [ "$wants_status" = "1" ]; then
  printf '200'
else
  printf '%s' '{"result":{"content":[{"type":"text","text":"{\"result\":{\"content\":\"SkillKey: c0ffee5ecret\"}}"}],"isError":false}}'
fi
CURL
chmod +x "${BIN}/curl"

## ── 1. Tokens never reach curl as arguments ──────────────────────────────

section "1/5  No token and no SkillKey is a word curl is given"

(
  export PATH="${BIN}:${PATH}" CURL_LOG
  mcp_call "http://localhost:4000" "$RW_TOKEN" create \
    "{\"path\":\"admin/x.md\",\"skill_key\":\"${SKILL_KEY}\"}" >/dev/null
)

cat "${CURL_LOG}"/*.argv >"${WORK}/all-argv"
cat "${CURL_LOG}"/*.stdin >"${WORK}/all-stdin" 2>/dev/null || : >"${WORK}/all-stdin"
assert_eq "mcp_call makes two requests: initialize, then the call" "2" \
  "$(find "$CURL_LOG" -name '*.argv' | wc -l | tr -d ' ')"
not_in "the token and the SkillKey are in no argument vector" "${WORK}/all-argv" "$RW_TOKEN" "$SKILL_KEY"
if grep -qF "header = \"Authorization: Bearer ${RW_TOKEN}\"" "${WORK}/all-stdin"; then
  pass "the bearer reaches curl as a config on its stdin"
else
  fail "the bearer reaches curl as a config on its stdin" "$(cat "${WORK}/all-stdin")"
fi
if grep -qF "mcp-session-id: sid-7" "${WORK}/all-stdin"; then
  pass "the call is made in the session initialize opened"
else
  fail "the call is made in the session initialize opened"
fi

# The whole of verify(), with only what is not curl stood in for.
rm -f "${CURL_LOG}"/*
(
  export PATH="${BIN}:${PATH}" CURL_LOG
  # shellcheck disable=SC2329 # called by verify() in lib.sh
  systemctl() { [ "${1:-}" = "is-active" ]; }
  # shellcheck disable=SC2329
  journalctl() { echo "vigil: 1 domains (admin), 1 notes, 3 chunks"; }
  # shellcheck disable=SC2329
  as_vigil() {
    case "${1:-} ${4:-}" in
      "git rev-list") echo 0 ;;
      *) "$@" ;;
    esac
  }
  VIGIL_VAULT="$VIGIL_VAULT_DIR" VIGIL_RW_TOKEN="$RW_TOKEN" VIGIL_RO_TOKEN="$RO_TOKEN"
  VIGIL_RESOURCE="https://vault.example/mcp" VIGIL_LOCAL_URL="http://localhost:4000"
  VIGIL_ALLOW_UNPROTECTED=0
  verify >/dev/null 2>&1 || true
)
cat "${CURL_LOG}"/*.argv >"${WORK}/all-argv"
calls="$(find "$CURL_LOG" -name '*.argv' | wc -l | tr -d ' ')"
if [ "$calls" -ge 20 ]; then
  pass "verify() was driven through curl (${calls} calls)"
else
  fail "verify() was driven through curl" "only ${calls} calls"
fi
not_in "no token and no SkillKey in any argument vector verify() gave curl" \
  "${WORK}/all-argv" "$RW_TOKEN" "$RO_TOKEN" "$SKILL_KEY"

# The config syntax is curl's own, so a real curl reads it back: a listener
# on loopback records what arrived. Skipped where there is no python3.
if command -v python3 >/dev/null 2>&1; then
  cat >"${WORK}/listener.py" <<'PY'
import http.server, json, sys
port_file, log_file = sys.argv[1], sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(log_file, "a") as f:
            f.write(json.dumps({"authorization": self.headers.get("Authorization"),
                                "session": self.headers.get("mcp-session-id"),
                                "body": body}) + "\n")
        out = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", "sid-real")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
  python3 "${WORK}/listener.py" "${WORK}/port" "${WORK}/requests" &
  SERVER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "${WORK}/port" ] && break
    sleep 0.2
  done
  # A body with the characters curl's config syntax escapes: a quote and a
  # backslash, inside a JSON string.
  body_args='{"content":"a \"quoted\" line\\nand a backslash \\\\","skill_key":"'"${SKILL_KEY}"'"}'
  mcp_call "http://127.0.0.1:$(cat "${WORK}/port")" "$RW_TOKEN" create "$body_args" >/dev/null
  kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  assert_eq "a real curl sends the bearer read from its config" "Bearer ${RW_TOKEN}" \
    "$(tail -1 "${WORK}/requests" | jq -r .authorization)"
  assert_eq "and the session id" "sid-real" "$(tail -1 "${WORK}/requests" | jq -r .session)"
  assert_eq "and the body, byte for byte" \
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create\",\"arguments\":${body_args}}}" \
    "$(tail -1 "${WORK}/requests" | jq -r .body)"
else
  echo "  (python3 not found: the round trip through a real curl is skipped)"
fi

## ── 2. --verbose traces no secret ────────────────────────────────────────

section "2/5  --verbose traces no secret"

# verify() under set -x, as init.sh and update.sh run it with --verbose.
rm -f "${CURL_LOG}"/*
(
  export PATH="${BIN}:${PATH}" CURL_LOG
  # shellcheck disable=SC2329 # called by verify() in lib.sh
  systemctl() { [ "${1:-}" = "is-active" ]; }
  # shellcheck disable=SC2329
  journalctl() { :; }
  # shellcheck disable=SC2329
  as_vigil() { "$@"; }
  VIGIL_VAULT="$VIGIL_VAULT_DIR" VIGIL_RESOURCE="https://vault.example/mcp"
  VIGIL_LOCAL_URL="http://localhost:4000" VIGIL_ALLOW_UNPROTECTED=0
  # Assigned before the trace starts, as the scripts do now.
  VIGIL_RW_TOKEN="$RW_TOKEN" VIGIL_RO_TOKEN="$RO_TOKEN"
  set -x
  verify || true
  case "$-" in *x*) echo "TRACING-STILL-ON" ;; esac
) >"${WORK}/verify-trace.txt" 2>&1
if grep -q '^+' "${WORK}/verify-trace.txt"; then
  pass "the run was traced"
else
  fail "the run was traced"
fi
not_in "verify() under set -x traces no token and no SkillKey" "${WORK}/verify-trace.txt" \
  "$RW_TOKEN" "$RO_TOKEN" "$SKILL_KEY"
if grep -q "TRACING-STILL-ON" "${WORK}/verify-trace.txt"; then
  pass "verify() turns the tracing back on when it is done"
else
  fail "verify() turns the tracing back on when it is done"
fi

# update.sh --rollback --verbose: it sources the env file and seeds two
# tokens. The test seam's seeded token is "test-token".
RELEASES="${VIGIL_PREFIX}/releases"
mkdir -p "${RELEASES}/r1/bin" "${RELEASES}/r2/bin"
ln -sfn "${RELEASES}/r2" "${VIGIL_PREFIX}/current"
echo "${RELEASES}/r1" >"${VIGIL_PREFIX}/.previous_release"
: >"${VIGIL_PREFIX}/.service-active"
cat >"$VIGIL_ENV_FILE" <<EOF
VIGIL_RESOURCE=https://vault.example/mcp
VIGIL_AUTH_PASSWORD=${PASSWORD}
VIGIL_SKILLKEY_SECRET=${SKILLKEY_SECRET}
EOF
set +e
VIGIL_UPDATE_TEST_STUBS=1 VIGIL_SERVICE_USER="$(id -un)" VIGIL_SERVICE_GROUP="$(id -gn)" \
  bash "${REPO_ROOT}/scripts/update.sh" --rollback --verbose \
  >"${WORK}/update-trace.txt" 2>&1 </dev/null
RC=$?
set -e
assert_eq "update.sh --rollback --verbose runs through" "0" "$RC"
if grep -q "^+.*source" "${WORK}/update-trace.txt"; then
  pass "update.sh was traced"
else
  fail "update.sh was traced" "$(head -5 "${WORK}/update-trace.txt")"
fi
not_in "update.sh --verbose traces neither the env file's secrets nor the tokens" \
  "${WORK}/update-trace.txt" "$PASSWORD" "$SKILLKEY_SECRET" "test-token"

# rotate_secret.sh --verbose: neither the old secret nor the new one.
rotate() {
  set +e
  VIGIL_ROTATE_TEST_STUBS=1 bash "${REPO_ROOT}/scripts/rotate_secret.sh" "$@" \
    >"${WORK}/rotate-out.txt" 2>&1 </dev/null
  RC=$?
  set -e
}
rotate password --verbose
assert_eq "rotate_secret.sh password --verbose exits 0" "0" "$RC"
NEW_PASSWORD="$(sed -n 's/^VIGIL_AUTH_PASSWORD=//p' "$VIGIL_ENV_FILE")"
if grep -q '^+' "${WORK}/rotate-out.txt"; then
  pass "rotate_secret.sh was traced"
else
  fail "rotate_secret.sh was traced"
fi
not_in "rotate_secret.sh --verbose traces neither the old password nor the new one" \
  "${WORK}/rotate-out.txt" "$PASSWORD" "$NEW_PASSWORD" "$SKILLKEY_SECRET"

## ── 3. An answer stays a value ───────────────────────────────────────────

section "3/5  A quote in an operator's answer does not break out"

MARK="${WORK}/broke-out"
hostile=(
  "the vault owner"
  "O'Brien"
  "say \"hi\""
  "\$(touch ${MARK})"
  "\`touch ${MARK}\`"
  "back\\slash and \\\$ and \\\""
  "x'; touch ${MARK}; echo '"
  "x\"; touch ${MARK}; echo \""
  "a;b && c | d > e"
)

for value in "${hostile[@]}"; do
  env_line VIGIL_VAULT_OWNER "$value" >"$VIGIL_ENV_FILE"
  sourced="$(bash -c 'set -a; source "$1"; printf "%s" "$VIGIL_VAULT_OWNER"' _ "$VIGIL_ENV_FILE" 2>&1)"
  assert_eq "sourced as root sources it, the env file gives back: ${value}" "$value" "$sourced"
  assert_eq "env_file_value gives back: ${value}" "$value" "$(env_file_value VIGIL_VAULT_OWNER)"
done
if [ -e "$MARK" ]; then
  fail "no answer ran a command when the env file was sourced"
else
  pass "no answer ran a command when the env file was sourced"
fi

if env_line VIGIL_TZ "$(printf 'a\nVIGIL_BIND=0.0.0.0')" >/dev/null 2>&1; then
  fail "an answer with a line break is refused, not written as a second setting"
else
  pass "an answer with a line break is refused, not written as a second setting"
fi

assert_eq "a plain value is written bare" "VIGIL_TZ=Europe/Berlin" "$(env_line VIGIL_TZ Europe/Berlin)"

# as_vigil runs its command through runuser: a runuser on PATH that checks
# the account and runs what it was handed, as the account would.
cat >"${BIN}/runuser" <<'RUNUSER'
#!/usr/bin/env bash
[ "$1" = "-u" ] && [ "$2" = "$EXPECTED_USER" ] && [ "$3" = "--" ] || {
  echo "runuser called as: $*" >&2
  exit 99
}
shift 3
exec "$@"
RUNUSER
chmod +x "${BIN}/runuser"

for value in "${hostile[@]}"; do
  got="$(PATH="${BIN}:${PATH}" EXPECTED_USER="$SERVICE_USER" as_vigil printf '%s|%s' "$value" "second")"
  assert_eq "as_vigil hands over as one argument: ${value}" "${value}|second" "$got"
done
if [ -e "$MARK" ]; then
  fail "no answer ran a command through as_vigil"
else
  pass "no answer ran a command through as_vigil"
fi
assert_eq "as_vigil starts in the state dir" "$VIGIL_STATE_DIR" \
  "$(PATH="${BIN}:${PATH}" EXPECTED_USER="$SERVICE_USER" as_vigil pwd -P)"

# What the shell cannot run: nothing splices a value into a string a second
# shell parses, and nothing switches user with su. The one `bash -c "…"` left
# is init.sh's --check-only test seam, which runs a fixed script it has only
# pointed at another checkout, with the script's arguments passed on.
# shellcheck disable=SC2016 # the needle is init.sh's text, not an expansion
spliced="$(grep -nE 'bash -c "' "${REPO_ROOT}"/scripts/*.sh | grep -vF 'bash -c "$script" "$@"' || true)"
assert_eq "no script splices a value into bash -c \"…\"" "" "$spliced"
su_calls="$(grep -nE '(^|[^a-z_])su -' "${REPO_ROOT}"/scripts/*.sh | grep -vE '^[^:]*:[0-9]+: *#' || true)"
assert_eq "no script switches to the service account with su" "" "$su_calls"

## ── 4. rotate_secret.sh ──────────────────────────────────────────────────

section "4/5  rotate_secret.sh replaces one secret and restarts"

# An env file the way a host has it after a while: init.sh's lines, settings
# the operator added, a comment, a quoted value.
write_env() {
  cat >"$VIGIL_ENV_FILE" <<EOF
# written by init.sh, then edited by hand
VIGIL_VAULT_PATH=/var/lib/vigil/vault
VIGIL_PORT=4000
VIGIL_ISSUER=https://vault.example.org
VIGIL_AUTH_PASSWORD=${PASSWORD}
VIGIL_SKILLKEY_SECRET=${SKILLKEY_SECRET}
VIGIL_ALLOWED_ORIGINS=http://localhost:6274
VIGIL_PUSH_TIMEOUT=300
VIGIL_VAULT_OWNER="the vault owner"
EOF
  chmod 0640 "$VIGIL_ENV_FILE"
}

# Every line but the one named, in order.
others() { grep -v "^$1=" "$VIGIL_ENV_FILE"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

for which in password skillkey; do
  case "$which" in
    password) key=VIGIL_AUTH_PASSWORD old="$PASSWORD" ;;
    skillkey) key=VIGIL_SKILLKEY_SECRET old="$SKILLKEY_SECRET" ;;
  esac
  write_env
  before="$(others "$key")"
  rm -f "${VIGIL_PREFIX}/.systemctl.log" "${VIGIL_PREFIX}/.service-active"

  rotate "$which"
  assert_eq "${which}: exits 0" "0" "$RC"
  new="$(sed -n "s/^${key}=//p" "$VIGIL_ENV_FILE")"
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    pass "${which}: ${key} has a new value"
  else
    fail "${which}: ${key} has a new value" "got '${new}'"
  fi
  bytes="$(decoded_bytes "$new")"
  if [ "$bytes" -ge 32 ]; then
    pass "${which}: the new value is at least 32 random bytes (${bytes})"
  else
    fail "${which}: the new value is at least 32 random bytes" "got ${bytes}"
  fi
  assert_eq "${which}: set on one line" "1" "$(grep -c "^${key}=" "$VIGIL_ENV_FILE")"
  assert_eq "${which}: every other line is kept, in order" "$before" "$(others "$key")"
  assert_eq "${which}: the file keeps its mode" "640" "$(file_mode "$VIGIL_ENV_FILE")"
  assert_eq "${which}: no temp file is left beside it" "" \
    "$(find "$(dirname "$VIGIL_ENV_FILE")" -maxdepth 1 -name "$(basename "$VIGIL_ENV_FILE").*")"
  assert_eq "${which}: its failed-start count is cleared, then it is restarted" \
    "$(printf 'reset-failed %s\nrestart %s' "$VIGIL_SERVICE_NAME" "$VIGIL_SERVICE_NAME")" \
    "$(cat "${VIGIL_PREFIX}/.systemctl.log" 2>/dev/null)"
  if grep -q "Rotation revokes no token" "${WORK}/rotate-out.txt" &&
    grep -q "scripts/grants.sh revoke-all" "${WORK}/rotate-out.txt"; then
    pass "${which}: says rotation revokes no token, and how to revoke them"
  else
    fail "${which}: says rotation revokes no token, and how to revoke them"
  fi
  not_in "${which}: prints neither the old value nor the new one" "${WORK}/rotate-out.txt" "$old" "$new"
done

write_env
grep -v '^VIGIL_SKILLKEY_SECRET=' "$VIGIL_ENV_FILE" >"${WORK}/no-skillkey"
cat "${WORK}/no-skillkey" >"$VIGIL_ENV_FILE"
rotate skillkey
assert_eq "a file with no SkillKey secret gets one" "1" "$(grep -c '^VIGIL_SKILLKEY_SECRET=' "$VIGIL_ENV_FILE")"
assert_eq "appended after every line it had" "$(cat "${WORK}/no-skillkey")" \
  "$(grep -v '^VIGIL_SKILLKEY_SECRET=' "$VIGIL_ENV_FILE")"

write_env
cp "$VIGIL_ENV_FILE" "${WORK}/env-before"
rm -f "${VIGIL_PREFIX}/.systemctl.log"
rotate password --dry-run
assert_eq "--dry-run exits 0" "0" "$RC"
assert_eq "--dry-run changes nothing" "$(cat "${WORK}/env-before")" "$(cat "$VIGIL_ENV_FILE")"
assert_eq "--dry-run restarts nothing" "" "$(cat "${VIGIL_PREFIX}/.systemctl.log" 2>/dev/null)"

for bad in "" "token" "password skillkey" "password --force"; do
  IFS=' ' read -r -a words <<<"$bad"
  rotate "${words[@]+"${words[@]}"}"
  assert_eq "'${bad}' is refused with exit 2" "2" "$RC"
done
assert_eq "the refused runs changed nothing" "$(cat "${WORK}/env-before")" "$(cat "$VIGIL_ENV_FILE")"

# Without the seam and without root, the refusal repeats the command to run
# under sudo — with the secret's name, which the argument loop had shifted
# out of "$@" by the time it was printed.
if [ "$(id -u)" -ne 0 ]; then
  set +e
  bash "${REPO_ROOT}/scripts/rotate_secret.sh" skillkey --dry-run >"${WORK}/rotate-out.txt" 2>&1 </dev/null
  RC=$?
  set -e
  assert_eq "as another user than root: exit 2" "2" "$RC"
  if grep -q "Fix: sudo .*rotate_secret.sh skillkey --dry-run" "${WORK}/rotate-out.txt"; then
    pass "the sudo hint repeats the whole command"
  else
    fail "the sudo hint repeats the whole command" "$(grep -i sudo "${WORK}/rotate-out.txt" || echo none)"
  fi
fi

rm -f "$VIGIL_ENV_FILE"
rotate password
assert_eq "no env file: exit 2" "2" "$RC"

## ── 5. What init.sh --force keeps ────────────────────────────────────────

section "5/5  init.sh --force keeps every setting it does not decide"

write_env
printf 'VIGIL_ISSUER=https://other.example.org\nVIGIL_TZ=UTC\n' |
  env_file_update "$VIGIL_ENV_FILE"
assert_eq "a named setting is replaced where it stood" "VIGIL_ISSUER=https://other.example.org" \
  "$(sed -n '4p' "$VIGIL_ENV_FILE")"
assert_eq "a new one is appended" "VIGIL_TZ=UTC" "$(tail -1 "$VIGIL_ENV_FILE")"
assert_eq "settings nobody named are kept" "VIGIL_PUSH_TIMEOUT=300" "$(grep '^VIGIL_PUSH_TIMEOUT=' "$VIGIL_ENV_FILE")"
assert_eq "comments are kept" "# written by init.sh, then edited by hand" "$(head -1 "$VIGIL_ENV_FILE")"

printf 'VIGIL_PORT=4000\nVIGIL_PORT=4001\n' >>"$VIGIL_ENV_FILE"
printf 'VIGIL_PORT=5000\n' | env_file_update "$VIGIL_ENV_FILE"
assert_eq "a setting on two lines ends up on one" "VIGIL_PORT=5000" "$(grep '^VIGIL_PORT=' "$VIGIL_ENV_FILE")"

printf 'VIGIL_PUSH_TIMEOUT=120\nVIGIL_BIND=127.0.0.1\n' |
  env_file_update "$VIGIL_ENV_FILE" --add-missing
assert_eq "--add-missing keeps a value the file has" "VIGIL_PUSH_TIMEOUT=300" \
  "$(grep '^VIGIL_PUSH_TIMEOUT=' "$VIGIL_ENV_FILE")"
assert_eq "--add-missing adds one it does not" "VIGIL_BIND=127.0.0.1" "$(tail -1 "$VIGIL_ENV_FILE")"
assert_eq "the file keeps its mode" "640" "$(file_mode "$VIGIL_ENV_FILE")"

if printf 'not a setting\n' | env_file_update "$VIGIL_ENV_FILE" 2>/dev/null; then
  fail "a line that sets nothing is refused"
else
  pass "a line that sets nothing is refused"
fi

# init.sh's step 4 needs root, a "vigil" user and a booted host, so what is
# asserted is its text, as secrets_test.sh does.
init_text="$(cat "${REPO_ROOT}/scripts/init.sh")"
has() {
  case "$init_text" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected in init.sh: $2" ;;
  esac
}
# shellcheck disable=SC2016 # init.sh's own text
has "init.sh replaces the settings it decides" 'env_file_update "$ENV_FILE" <<<"$ENV_DECIDED"'
# shellcheck disable=SC2016
has "and only adds its defaults where the file has none" \
  'env_file_update "$ENV_FILE" --add-missing <<<"$ENV_DEFAULTS"'
has "init.sh restarts the service, so replaced secrets are live" "  start_service restart"
if printf '%s\n' "$init_text" | grep -qE '^ *(systemctl|start_service) start( vigil)?$'; then
  fail "init.sh no longer only starts it"
else
  pass "init.sh no longer only starts it"
fi

guide="$(cat "${REPO_ROOT}/docs/guide.md")"
case "$guide" in
  *"## Rotating secrets"*"scripts/rotate_secret.sh"*"grants.sh revoke-all"*)
    pass "docs/guide.md has a Rotating secrets section naming both scripts" ;;
  *) fail "docs/guide.md has a Rotating secrets section naming both scripts" ;;
esac

report
