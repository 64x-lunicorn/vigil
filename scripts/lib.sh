#!/usr/bin/env bash
# scripts/lib.sh — shared library for setup.sh / init.sh / update.sh.
# Sourced via `source "$(dirname "$0")/lib.sh"`; has no execution path of its
# own.
#
# Exit codes (identical across all three scripts):
#   0  success
#   1  runtime error (unexpected — anything not explicitly 2/3/4)
#   2  preflight failed — nothing was changed
#   3  acceptance (verify()) failed — state has been described
#   4  user aborted
#
# Hard rule: log/warn/err NEVER receive a variable that can contain a secret.
# Secrets are printed straight to the terminal and never to journald.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "${0%.sh}")"
SCRIPT_START="$(date +%s)"
LAST_STEP="Start"

DRY_RUN="${DRY_RUN:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
VERBOSE="${VERBOSE:-0}"

DONE_ITEMS=()
WARNINGS=()
NEXT_STEPS=()

## ── The installation layout ──────────────────────────────────────────────
#
# Every path and account the shared functions below reach for, named once.
# update.sh named its own set in #140 and the functions here kept their
# literals, which meant an override reached half the script — so update.sh had
# to refuse the overrides outside its own test. They live here now, and that
# refusal is gone.
#
# The defaults are the production install. Overriding them is what
# scripts/test/verify_test.sh and scripts/test/update_test.sh do; nothing else
# should.
#
# Shell names are unprefixed on purpose. `source_env_for_verify` does
# `set -a; source "$ENV_FILE"`, and /etc/vigil/env owns the VIGIL_* namespace
# — a layout variable spelled VIGIL_STATE_DIR could be overwritten by the file
# it was used to find.
# The directives below are on the names a sourcing script reads but this file
# does not: ShellCheck cannot see across the `source` line.
PREFIX="${VIGIL_PREFIX:-/opt/vigil}"
STATE_DIR="${VIGIL_STATE_DIR:-/var/lib/vigil}"
# shellcheck disable=SC2034 # read by the sourcing script
VAULT="${VIGIL_VAULT_DIR:-${STATE_DIR}/vault}"
# shellcheck disable=SC2034 # read by the sourcing script
ENV_FILE="${VIGIL_ENV_FILE:-/etc/vigil/env}"
# shellcheck disable=SC2034 # read by the sourcing script
UNIT_FILE="${VIGIL_UNIT_FILE:-/etc/systemd/system/vigil.service}"

SERVICE="${VIGIL_SERVICE_NAME:-vigil}"
SERVICE_USER="${VIGIL_SERVICE_USER:-vigil}"
# shellcheck disable=SC2034 # read by the sourcing script
SERVICE_GROUP="${VIGIL_SERVICE_GROUP:-vigil}"

REPO="${PREFIX}/repo"
# shellcheck disable=SC2034 # read by the sourcing script
RELEASES="${PREFIX}/releases"
CURRENT="${PREFIX}/current"
# shellcheck disable=SC2034 # read by the sourcing script
PREVIOUS_RELEASE_FILE="${PREFIX}/.previous_release"

# What wait_until_healthy polls. Unauthenticated and answered before any token
# exists, which is what makes it usable as a readiness probe.
HEALTH_URL="${VIGIL_HEALTH_URL:-http://localhost:4000/.well-known/oauth-protected-resource}"

## ── Logging ──────────────────────────────────────────────────────────────

_timestamp() { date +%H:%M:%S; }

_journal() {
  # logger may be missing in containers/minimal systems — never abort over it.
  logger -t "vigil-${SCRIPT_NAME}" -- "$1" 2>/dev/null || true
}

log() {
  echo "[$(_timestamp)] ▸ $1"
  _journal "$1"
}

ok() {
  echo "[$(_timestamp)] ✓ $1"
  _journal "$1"
}

warn() {
  echo "[$(_timestamp)] ! $1" >&2
  _journal "WARNING: $1"
  WARNINGS+=("$1")
}

err() {
  echo "[$(_timestamp)] ✗ $1" >&2
  _journal "ERROR: $1"
}

step() {
  LAST_STEP="$1"
  echo
  echo "── $1 ──"
}

record_done() { DONE_ITEMS+=("$1"); }
record_next_step() { NEXT_STEPS+=("$1"); }

## ── Error trap ───────────────────────────────────────────────────────────

error_trap() {
  local rc="$1" line_no="$2"
  err "Aborted at line ${line_no} (exit ${rc}). Last step: ${LAST_STEP}."
  err "No further changes were made."
}

trap 'error_trap $? $LINENO' ERR

## ── Final summary (always runs, including on abort) ──────────────────────

summary() {
  local rc=$?
  local duration=$(( $(date +%s) - SCRIPT_START ))
  local minutes=$(( duration / 60 ))
  local seconds=$(( duration % 60 ))
  local duration_text="${minutes}m ${seconds}s"

  echo
  echo "────────────────────────────────────────"
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ ${SCRIPT_NAME}.sh finished (${duration_text})"
  else
    echo "  ✗ ${SCRIPT_NAME}.sh aborted — exit ${rc} (${duration_text})"
  fi

  if [ "${#DONE_ITEMS[@]}" -gt 0 ]; then
    echo
    echo "  Done:"
    for e in "${DONE_ITEMS[@]}"; do echo "    • ${e}"; done
  fi

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "  Warnings (${#WARNINGS[@]}):"
    for w in "${WARNINGS[@]}"; do echo "    ! ${w}"; done
  fi

  if [ "${#NEXT_STEPS[@]}" -gt 0 ]; then
    echo
    echo "  Next:"
    local i=1
    for n in "${NEXT_STEPS[@]}"; do
      echo "    ${i}. ${n}"
      i=$((i + 1))
    done
  fi
  echo "────────────────────────────────────────"
}

trap summary EXIT

## ── Helpers ──────────────────────────────────────────────────────────────

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root. Fix: sudo $0 $*"
    exit 2
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command missing: $1. Fix: apt-get install -y <matching package>."
    exit 2
  fi
}

ask_yes_no() {
  local question="$1" default="${2:-y}" response prompt
  if [ "$NON_INTERACTIVE" = "1" ]; then
    [ "$default" = "y" ]
    return
  fi
  case "$default" in
    y) prompt="[Y/n]" ;;
    n) prompt="[y/N]" ;;
    *) prompt="[y/n]" ;;
  esac
  read -r -p "${question} ${prompt} " response
  response="${response:-$default}"
  case "$response" in
    y | Y | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the chosen value on stdout: value=$(ask_value "Prompt" "default")
ask_value() {
  local prompt="$1" default="$2" value
  if [ "$NON_INTERACTIVE" = "1" ]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "${prompt} [${default}]: " value
  printf '%s\n' "${value:-$default}"
}

# Requires the word "yes" to be typed — never a bare Enter. Under
# --non-interactive this aborts rather than silently assuming consent.
confirm_destructive() {
  local description="$1" response
  warn "$description"
  if [ "$NON_INTERACTIVE" = "1" ]; then
    err "Destructive action needs interactive confirmation, not available under --non-interactive: ${description}"
    return 1
  fi
  printf 'Type exactly "yes" to continue: '
  read -r response
  [ "$response" = "yes" ]
}

# as_vigil <cmd...>  — e.g. as_vigil git -C "$VAULT" fetch
#                        or   as_vigil bash -c 'cd ... && mix test'
# Always starts from the service account's home (the state dir), never from the caller's
# cwd. root often runs these scripts from directories vigil cannot access
# (/root/... for instance); without an explicit cd even a plain "git
# --version" fails with "Permission denied" while stat'ing the inherited
# working directory.
as_vigil() {
  local quoted
  quoted="$(printf '%q ' "$@")"
  # LANG/LC_ALL: without a UTF-8 locale the BEAM (mix test, mix release)
  # treats filenames as raw bytes instead of Unicode — vault fixtures with
  # non-ASCII names then fail with "no such file or directory" on a path
  # File.ls itself just returned. C.UTF-8 is part of glibc, no locale-gen
  # needed.
  su -s /bin/bash -c "cd ${STATE_DIR} && LANG=C.UTF-8 LC_ALL=C.UTF-8 ${quoted}" "$SERVICE_USER"
}

# run_step "<description>" -- <cmd...>  — honours --dry-run consistently.
run_step() {
  local description="$1"
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] ${description}: $*"
    return 0
  fi
  log "$description"
  "$@"
}

# write_file_atomically <path> <mode> <owner> <content>
# temp file in the same directory + mv, never a half-written file.
write_file_atomically() {
  local path="$1" mode="$2" owner="$3" content="$4" tmp
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] write file: ${path} (mode ${mode}, owner ${owner})"
    return 0
  fi
  tmp="$(mktemp "${path}.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

# wait_until_healthy — waits up to 30s for the local endpoint to answer.
# Required after every systemctl start/restart, BEFORE anything tries to talk
# to the node (bearer call or `bin/vigil rpc`) — otherwise that fails with
# "noconnection"/connection refused because the BEAM has not finished booting.
wait_until_healthy() {
  local i=0
  while ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      err "Service did not become healthy within 30s. journalctl -u ${SERVICE} -n 50:"
      journalctl -u "$SERVICE" -n 50 --no-pager >&2
      return 1
    fi
    sleep 1
  done
  ok "Service is up and answering."
}

## ── Token bootstrap (shared by init.sh/update.sh) ────────────────────────

# vigil_seed_token <resource> <scope>  — prints the new token on stdout.
#
# If the service is already running this must NOT go through
# `mix vigil.seed_token`: that starts a second, standalone BEAM process which
# opens the same dets files the running Vigil.OAuth.Store already holds open.
# dets is not built for multi-process access, so the freshly seeded token ends
# up in a copy the running service never sees and every call with it fails
# with 401. Seed through `bin/vigil rpc` in the already-running node instead —
# same process, no concurrency. If the service is not running yet (first-time
# setup before the first start), the standalone path via the code checkout is
# fine and only needs fetched deps, no release binary.
#
# Both paths mint through `Vigil.OAuth.Token`, which owns the token record —
# an rpc expression that writes the map itself is how this one came to be a
# variant that carried no grant_id.
vigil_seed_token() {
  local resource="$1" scope="$2"
  if systemctl is-active --quiet "$SERVICE"; then
    local ausdruck
    ausdruck="IO.puts(Vigil.OAuth.Token.issue_out_of_band(\"${resource}\", \"${scope}\", 3650 * 86400, System.system_time(:second)))"
    as_vigil "${CURRENT}/bin/vigil" rpc "$ausdruck" | tail -1
  else
    # shellcheck disable=SC2016 # $1..$3 are expanded by the inner bash -c, not here
    as_vigil bash -c 'cd "$1" && MIX_ENV=prod mix vigil.seed_token --state-dir "$2" --resource "$3" --scope "$4" --ttl-days 3650' \
      _ "$REPO" "$STATE_DIR" "$resource" "$scope" | tail -1
  fi
}

## ── MCP calls used by verify() ───────────────────────────────────────────

# mcp_call <base_url> <token> <tool> [<json_args>]  → prints the raw JSON-RPC
# response on stdout.
mcp_call() {
  local base_url="$1" token="$2" tool="$3"
  # Do NOT write this as "${4:-{}}": bash closes the parameter expansion at
  # the FIRST closing brace after ":-", so a literal "{}" default is parsed as
  # "{" and a stray "}" is left dangling in the string — every call WITH a
  # real 4th argument then got a surplus "}" appended to the JSON (broken
  # JSON, answered by the server with "Parse error"). And do NOT write it as
  # `local args="$4"` either: without a 4th argument $4 is an unbound
  # parameter, and with set -u (active, see the top of this file) that kills
  # the entire shell without any error message, from inside verify().
  # "${4:-}" (empty default) avoids both traps at once. Both found empirically
  # in a Docker test.
  local args="${4:-}"
  if [ -z "$args" ]; then
    args="{}"
  fi
  local session_id="verify-$$-${RANDOM}"
  curl -fsS -X POST "${base_url}/mcp" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "mcp-session-id: ${session_id}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}"
}

# True for a tool-level isError:true AND for a JSON-RPC-level error (a parse
# error, say, if the JSON we sent was broken) — from verify()'s point of view
# both mean "that did not work".
mcp_is_error() {
  jq -e '(.result.isError == true) or (.error != null)' >/dev/null 2>&1
}

# mcp_payload <jq-filter>  — for SUCCESS responses: result.content[0].text is
# itself JSON (tool result + envelope); the filter is applied to that.
mcp_payload() {
  jq -r '.result.content[0].text' | jq -r "$1"
}

# mcp_error_text  — for ERROR responses (isError:true): result.content[0].text
# is a plain string there, NOT JSON, so a second jq parse over it (which
# mcp_payload does) fails. Hence a separate, simple function rather than
# abusing mcp_payload with a raw '.'.
mcp_error_text() {
  jq -r '.result.content[0].text // .error.message // empty'
}

## ── verify() — the central acceptance function ───────────────────────────
#
# Expects to be set: VIGIL_VAULT, VIGIL_RW_TOKEN, VIGIL_RO_TOKEN,
# VIGIL_RESOURCE (public MCP endpoint URL, e.g. https://vault.example.org/mcp),
# VIGIL_LOCAL_URL (e.g. http://localhost:4000), VIGIL_GIT_REMOTE,
# VIGIL_ALLOW_UNPROTECTED (0/1).
# Returns 0 when every mandatory check passes, 1 otherwise.

# Each check is a function of its own: it prints its verdict and answers 0 or
# 1, and verify() is the loop over them. That is what scripts/test/verify_test.sh
# needs — the acceptance function the whole rollback decision hangs on used to
# be one 210-line block that could only be run against a real vault host, so
# the one thing nothing could test was the thing that decides whether a
# delivery stands or is rolled back.
#
# Two values are shared, and are the globals they always were: VIGIL_SKILL_KEY,
# fetched once up front, and VIGIL_TEST_DOMAIN, which check 7 discovers and
# checks 9, 10 and 12 reuse.

# The SkillKey the checks that make a deliberate write attempt (7, 10, 12)
# need. Check 9 deliberately omits it.
verify_fetch_skill_key() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "skill_read" '{"name":"vigil-vault-conventions"}' 2>/dev/null || true)"
  # sed rather than `grep -oP`: PCRE is a GNU extension, and verify() has to be
  # runnable off the vault host for scripts/test/verify_test.sh to exist at all.
  VIGIL_SKILL_KEY="$(echo "$response" | mcp_payload '.result.content' 2>/dev/null |
    sed -n 's/.*SkillKey: \([0-9a-f][0-9a-f]*\).*/\1/p' | head -1 || true)"
}

# 1. Service active
verify_service_active() {
  if systemctl is-active --quiet "$SERVICE"; then
    echo "  ✓ [1] systemctl is-active ${SERVICE}"
  else
    echo "  ✗ [1] Service is not running — journalctl -u ${SERVICE} -n 50"
    return 1
  fi
}

# 2. Public endpoint answers with 403 (Cloudflare Access)
verify_public_endpoint_protected() {
  if [ "$VIGIL_ALLOW_UNPROTECTED" = "1" ]; then
    warn "verify() [2] skipped (--allow-unprotected): Cloudflare Access check not performed."
    return 0
  fi

  local status
  status="$(curl -o /dev/null -s -w '%{http_code}' "${VIGIL_RESOURCE}" || echo "000")"
  if [ "$status" = "403" ]; then
    echo "  ✓ [2] Public endpoint answers with 403 (Cloudflare Access active)"
  else
    echo "  ✗ [2] Public endpoint answers with ${status} instead of 403."
    if [ "$status" = "401" ]; then
      echo "        401 means the request reaches Elixir — Cloudflare Access is NOT in front."
    elif [ "$status" = "200" ]; then
      echo "        200 means the endpoint is completely unprotected."
    fi
    return 1
  fi
}

# 3. Local call with a valid RW token
verify_local_call_answers() {
  if mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "current" >/dev/null 2>&1; then
    echo "  ✓ [3] Local call with a valid RW token answers"
  else
    echo "  ✗ [3] Service does not answer a valid token (${VIGIL_LOCAL_URL}/mcp)"
    return 1
  fi
}

# 4. Git remote reachable
verify_git_remote_reachable() {
  if as_vigil git -C "$VIGIL_VAULT" ls-remote "$VIGIL_GIT_REMOTE" >/dev/null 2>&1; then
    echo "  ✓ [4] git ls-remote ${VIGIL_GIT_REMOTE} succeeded"
  else
    echo "  ✗ [4] git ls-remote ${VIGIL_GIT_REMOTE} failed — host key or deploy key missing"
    return 1
  fi
}

# 5. reload → no pull_failed
verify_reload_pulls() {
  local reload_response pull_failed
  reload_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "reload")"
  pull_failed="$(echo "$reload_response" | mcp_payload '.result.pull_failed // empty')"
  if [ -z "$pull_failed" ]; then
    echo "  ✓ [5] reload → no pull_failed"
  else
    echo "  ✗ [5] reload reports pull_failed: ${pull_failed}"
    return 1
  fi
}

# 6. Chunk count has not dropped (warning, not an abort)
verify_chunk_count() {
  local last_chunks_file="${STATE_DIR}/.last_chunks"
  local chunks_now chunks_before=0

  # awk rather than `grep -oP ... | tail -1`: same reason as the SkillKey above,
  # and it takes the last match itself.
  chunks_now="$(journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null |
    awk 'match($0, /[0-9]+ Chunks/) {
           s = substr($0, RSTART, RLENGTH); sub(/ Chunks$/, "", s); last = s
         }
         END { if (last != "") print last }' || true)"
  if [ -f "$last_chunks_file" ]; then
    chunks_before="$(cat "$last_chunks_file")"
  fi
  if [ -n "$chunks_now" ]; then
    if [ "$chunks_now" -ge "$chunks_before" ]; then
      echo "  ✓ [6] Chunk count ${chunks_now} ≥ previous ${chunks_before}"
    else
      warn "verify() [6]: chunk count dropped from ${chunks_before} to ${chunks_now} — possible parser regression."
    fi
    if [ "$DRY_RUN" != "1" ]; then
      echo "$chunks_now" >"$last_chunks_file"
    fi
  else
    warn "verify() [6]: could not read the chunk count from journalctl."
  fi
}

# 7. Write a test note → success (implies push, see write_and_commit), then delete it
#
# The domain is deliberately NOT hardcoded: init.sh asks for the domain
# list interactively, so a fixed "admin/" (or "journal/") would make
# verify() fail on any vault without that domain — and check 12 below needs
# the same directory to exist physically. Instead: try every domain
# directory in the vault and take the first one where a create actually goes
# through. That also skips domains with a naming.pattern (journal/ with
# YYYY-MM-DD.md, say) that an ad-hoc test path cannot satisfy, without
# having to parse _domains.yml in bash.
verify_write_and_push() {
  local create_response delete_response
  local test_path="" last_error="no domain directories found in the vault"
  VIGIL_TEST_DOMAIN=""

  local candidate
  for candidate in $(as_vigil ls -1 "$VIGIL_VAULT" 2>/dev/null || true); do
    [ -d "${VIGIL_VAULT}/${candidate}" ] || continue
    case "$candidate" in skills | .* | _*) continue ;; esac

    local attempt_path="${candidate}/verify-test-$$.md"
    create_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
      "{\"path\":\"${attempt_path}\",\"type\":\"reference\",\"content\":\"# Verify-Test\\ntemp\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"

    if echo "$create_response" | mcp_is_error; then
      last_error="$(echo "$create_response" | mcp_error_text 2>/dev/null || echo "$create_response")"
    else
      test_path="$attempt_path"
      VIGIL_TEST_DOMAIN="$candidate"
      break
    fi
  done

  if [ -z "$test_path" ]; then
    echo "  ✗ [7] Could not write a test note in any domain. Last error: ${last_error}"
    return 1
  fi

  echo "  ✓ [7] Test note written and pushed (domain: ${VIGIL_TEST_DOMAIN})"
  delete_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "delete_note" \
    "{\"path\":\"${test_path}\",\"confirm\":true,\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"
  if echo "$delete_response" | mcp_is_error; then
    warn "verify() [7]: test note could not be deleted again, please clean up manually: ${test_path}"
  fi
}

# 8. No pending local commits
verify_nothing_unpushed() {
  local pending
  pending="$(as_vigil git -C "$VIGIL_VAULT" rev-list --count "${VIGIL_GIT_REMOTE}/main..main" 2>/dev/null || echo "?")"
  if [ "$pending" = "0" ]; then
    echo "  ✓ [8] No pending local commits in the vault"
  else
    echo "  ✗ [8] ${pending} local commits not pushed"
    return 1
  fi
}

# 9. Write attempt without skill_key → error
# Path and domain are irrelevant here: the SkillKey gate in Vigil.MCP.Tools
# fires before any Store validation, so the call must never reach the
# domain at all.
verify_skill_key_enforced() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN:-admin}/verify-nope-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\"}")"
  if echo "$response" | mcp_is_error && echo "$response" | mcp_error_text 2>/dev/null | grep -qi "SkillKey"; then
    echo "  ✓ [9] Writing without skill_key is rejected"
  else
    echo "  ✗ [9] SkillKey is not enforced"
    return 1
  fi
}

# 10. Write attempt with the RO token → permission error
verify_read_only_token_refused() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RO_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN:-admin}/verify-ro-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"
  if echo "$response" | mcp_is_error; then
    echo "  ✓ [10] Write attempt with the RO token is rejected"
  else
    echo "  ✗ [10] Role separation is not working — the RO token could write"
    return 1
  fi
}

# 11. Domain drift between _domains.yml and the actual directories
verify_no_domain_drift() {
  if journalctl -u "$SERVICE" -n 50 --no-pager 2>/dev/null | grep -q "has no entry in _domains.yml\|has no matching directory"; then
    echo "  ✗ [11] Domain drift between _domains.yml and vault directories (see journalctl -u ${SERVICE})"
    return 1
  else
    echo "  ✓ [11] No domain drift in the recent logs"
  fi
}

# 12. Provoke a write error, then check read/search still answer (the key check)
# Uses the demonstrably writable domain determined in check 7.
verify_survives_write_error() {
  if [ -z "${VIGIL_TEST_DOMAIN:-}" ]; then
    echo "  ✗ [12] skipped — check 7 found no writable domain"
    return 1
  fi

  local check12_ok=1
  local test_domain_dir="${VIGIL_VAULT}/${VIGIL_TEST_DOMAIN}"

  # The directory is made unwritable on purpose, so it has to be restored even
  # if something between here and the restore aborts. The path is expanded into
  # the trap when the trap is set, rather than read from a local when it fires:
  # a RETURN trap that names a local runs after that local is gone.
  local quoted_dir
  quoted_dir="$(printf '%q' "$test_domain_dir")"
  # shellcheck disable=SC2064 # expanding now is the point — see above
  trap "chmod 0750 ${quoted_dir} 2>/dev/null || true" RETURN

  chmod 0555 "$test_domain_dir" 2>/dev/null || check12_ok=0
  mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN}/verify-crash-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}" \
    >/dev/null 2>&1 || true
  chmod 0750 "$test_domain_dir" 2>/dev/null || true
  trap - RETURN

  if mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "search" '{"query":"vigil"}' >/dev/null 2>&1; then
    echo "  ✓ [12] Write error provoked, read/search still answer afterwards"
  else
    echo "  ✗ [12] Crash safety not effective — the Store dies on a write error"
    check12_ok=0
  fi

  [ "$check12_ok" = "1" ]
}

# The checks, in the order they run. Named here so the list is one thing rather
# than a sequence buried in a 210-line function — and so a test can ask for the
# list rather than repeat it.
VIGIL_VERIFY_CHECKS=(
  verify_service_active
  verify_public_endpoint_protected
  verify_local_call_answers
  verify_git_remote_reachable
  verify_reload_pulls
  verify_chunk_count
  verify_write_and_push
  verify_nothing_unpushed
  verify_skill_key_enforced
  verify_read_only_token_refused
  verify_no_domain_drift
  verify_survives_write_error
)

verify() {
  local all_ok=1
  local check

  echo
  echo "=== verify() ==="

  verify_fetch_skill_key

  for check in "${VIGIL_VERIFY_CHECKS[@]}"; do
    "$check" || all_ok=0
  done

  echo
  if [ "$all_ok" = "1" ]; then
    ok "verify(): all mandatory checks passed."
    return 0
  else
    err "verify(): at least one mandatory check failed."
    return 1
  fi
}
