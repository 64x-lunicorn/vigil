#!/usr/bin/env bash
# scripts/test/update_test.sh — acceptance test for the delivery mechanism.
#
# update.sh is the script that actually ships a change to the vault host, and
# until this file existed it was the one part of the pipeline nothing checked.
# Its rollback path in particular was code whose first execution would have
# been during a production incident: verify() goes red, the symlink has to move
# back, the service has to come up on the old release, and the operator has to
# be told which of the two situations they are in.
#
# What this covers that scripts/test/release_smoke.sh cannot: the smoke test
# proves a release boots and serves. It says nothing about switching between
# two of them — the order of stop/symlink/start, what `.previous_release`
# records, whether a red verify() actually rolls back, which exit code the
# operator sees, and which old releases the cleanup deletes.
#
# It drives the real scripts/update.sh against a throwaway prefix.
# VIGIL_UPDATE_TEST_STUBS=1 (see update.sh) replaces root, the service account,
# systemd and the booted release with file-backed stand-ins; the step sequence,
# the exit codes, the rollback decision and the retention rule under test are
# production code, not a copy of it. `mix` is a stub on PATH — building a real
# release per case would make this a ten-minute test that proves nothing extra,
# since the smoke test already proves a release builds and boots.
#
# Everything happens in a temp directory and is removed afterwards. No root, no
# systemd, no production paths, no network.
#
# Usage: bash scripts/test/update_test.sh [--keep]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UPDATE_SH="${REPO_ROOT}/scripts/update.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PASS=0
FAIL=0
WORK=""

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

# sha256sum on Linux, shasum on macOS. Named rather than inlined because the
# state fingerprint below is compared across three runs of update.sh.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# Two codes for one false positive: ShellCheck renamed it in 0.10, and a
# contributor may still be on a version that reports the old one. CI is pinned
# to 0.11 and only needs SC2329; the second code is for the local run.
# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap below
cleanup() {
  if [ -n "$WORK" ] && [ "$KEEP" = "0" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  elif [ -n "$WORK" ] && [ "$KEEP" = "1" ]; then
    echo "Work directory kept: ${WORK}"
  fi
}
trap cleanup EXIT INT TERM

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-update-test.XXXXXX")" && pwd -P)"
PREFIX="${WORK}/opt/vigil"
VAULT="${WORK}/var/lib/vigil/vault"
ENV_FILE="${WORK}/etc/vigil/env"
BIN="${WORK}/bin"

## ── The throwaway host ───────────────────────────────────────────────────

# A `mix` that records what it was asked to do and answers according to files
# the test writes, so a red `mix test` and a red audit are drivable without a
# BEAM anywhere near this.
build_fake_mix() {
  mkdir -p "$BIN"
  cat >"${BIN}/mix" <<'MIX'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${FAKE_MIX_LOG}"
case "${1:-}" in
  test)
    [ -f "${FAKE_MIX_TEST_FAILS:-/nonexistent}" ] && exit 1
    echo "42 tests, 0 failures"
    ;;
  hex.audit)
    if [ -f "${FAKE_MIX_AUDIT_CRITICAL:-/nonexistent}" ]; then
      echo "Dependency foo 1.0.0 has a CRITICAL advisory"
    else
      echo "No retired packages found"
    fi
    ;;
  release)
    # A release here is a directory with a bin/vigil in it, which is all the
    # switchover touches.
    path=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--path" ] && path="${2:-}"
      shift
    done
    if [ -z "$path" ]; then
      echo "fake mix: release without --path" >&2
      exit 1
    fi
    mkdir -p "${path}/bin"
    echo "#!/bin/sh" >"${path}/bin/vigil"
    chmod +x "${path}/bin/vigil"
    ;;
esac
exit 0
MIX
  chmod +x "${BIN}/mix"
}

# A code repo with two commits, so `--to` has something real to move between.
build_repo() {
  local repo="${PREFIX}/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Update Test"
  mkdir -p "${repo}/deploy"
  echo "[Unit]" >"${repo}/deploy/vigil.service"
  echo "v1" >"${repo}/version"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "v1"
  OLD_SHA="$(git -C "$repo" rev-parse --short HEAD)"
  echo "v2" >"${repo}/version"
  git -C "$repo" commit -qam "v2"
  NEW_SHA="$(git -C "$repo" rev-parse --short HEAD)"
  git -C "$repo" checkout -q "$OLD_SHA"
}

# A vault whose `github/main..main` count is 0, which is what preflight asks.
build_vault() {
  mkdir -p "$VAULT"
  git -C "$VAULT" init -q -b main
  git -C "$VAULT" config user.email test@example.com
  git -C "$VAULT" config user.name "Update Test"
  echo "# note" >"${VAULT}/note.md"
  git -C "$VAULT" add -A
  git -C "$VAULT" commit -q -m "note"
  git -C "$VAULT" update-ref refs/remotes/github/main HEAD
}

# One release directory, optionally one that does not come up.
make_release() {
  local name="$1" healthy="${2:-healthy}"
  mkdir -p "${PREFIX}/releases/${name}/bin"
  echo "#!/bin/sh" >"${PREFIX}/releases/${name}/bin/vigil"
  [ "$healthy" = "broken" ] && touch "${PREFIX}/releases/${name}/.verify-fails"
  echo "${PREFIX}/releases/${name}"
}

# Everything the authorization server has persisted lives beside the vault, in
# the state dir. update.sh must never write there: the tokens in these files
# are what an already-connected client authenticates with, and a delivery that
# resets them is a delivery that silently logs Claude out.
STATE_DIR=""

seed_oauth_state() {
  STATE_DIR="$(dirname "$VAULT")"
  mkdir -p "$STATE_DIR"
  for table in clients codes tokens; do
    echo "pretend-dets-${table}-written-before-the-update" \
      >"${STATE_DIR}/oauth_${table}.dets"
    # 0600, as Vigil.OAuth.Store opens them: these hold bearer tokens, and a
    # fingerprint over default permissions could not tell a widening apart.
    chmod 600 "${STATE_DIR}/oauth_${table}.dets"
  done
  # Deliberately also seeded, and deliberately outside the fingerprint below.
  echo "17" >"${STATE_DIR}/.last_chunks"
}

# The three dets files, with their permissions, as one comparable string.
#
# Scoped to oauth_*.dets rather than the whole state dir: verify() writes the
# fresh chunk count to .last_chunks on every real update and every rollback
# (scripts/lib.sh), so a whole-directory assertion would be green here only
# because this harness stubs verify() out, and would turn red for intended
# behaviour the moment it did not.
#
# Mode is part of the fingerprint: these files hold bearer tokens, they are
# chmod 0600 by the store, and "untouched" has to mean the permissions too.
state_fingerprint() {
  find "$STATE_DIR" -maxdepth 1 -type f -name 'oauth_*.dets' -print |
    sort |
    while IFS= read -r file; do
      printf '%s %s %s\n' \
        "$(basename "$file")" \
        "$(sha256_of "$file" | cut -d' ' -f1)" \
        "$(mode_of "$file")"
    done
}

# stat is spelled differently on the two platforms this runs on.
mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

build_host() {
  rm -rf "${WORK:?}/opt" "${WORK:?}/var" "${WORK:?}/etc"
  mkdir -p "$PREFIX/releases" "$(dirname "$ENV_FILE")"
  build_repo
  build_vault
  cat >"$ENV_FILE" <<ENV
VIGIL_RESOURCE=https://vault.example/mcp
VIGIL_PORT=4000
ENV
  local first
  first="$(make_release v0)"
  ln -sfn "$first" "${PREFIX}/current"
  : >"${PREFIX}/.service-active"
  FAKE_MIX_LOG="${WORK}/mix.log"
  : >"$FAKE_MIX_LOG"
  seed_oauth_state
}

# Runs the real update.sh against the throwaway host. Prints its exit code.
run_update() {
  set +e
  env \
    PATH="${BIN}:${PATH}" \
    VIGIL_UPDATE_TEST_STUBS=1 \
    VIGIL_PREFIX="${PREFIX_OVERRIDE:-$PREFIX}" \
    VIGIL_VAULT_DIR="$VAULT" \
    VIGIL_ENV_FILE="$ENV_FILE" \
    VIGIL_UNIT_FILE="${WORK}/etc/vigil.service" \
    VIGIL_SERVICE_USER="$(id -un)" \
    VIGIL_SERVICE_GROUP="$(id -gn)" \
    FAKE_MIX_LOG="$FAKE_MIX_LOG" \
    FAKE_MIX_TEST_FAILS="${FAKE_MIX_TEST_FAILS:-/nonexistent}" \
    FAKE_MIX_AUDIT_CRITICAL="${FAKE_MIX_AUDIT_CRITICAL:-/nonexistent}" \
    bash "$UPDATE_SH" "$@" >"${WORK}/out.log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

current_release() { basename "$(readlink "${PREFIX}/current")"; }

# The recorded start/stop calls as one line: "stop v0 | start 7a1b2c3". Each
# entry carries what `current` pointed at when the call was made, so the line
# shows both that the service was cycled and that the symlink moved while it
# was down.
systemctl_calls() {
  if [ ! -f "${PREFIX}/.systemctl.log" ]; then
    echo "(none)"
    return
  fi
  sed "s|${PREFIX}/releases/||" "${PREFIX}/.systemctl.log" | paste -sd'|' - | sed 's/|/ | /g'
}
service_running() { [ -f "${PREFIX}/.service-active" ] && echo yes || echo no; }

build_fake_mix

## ── 1. The happy path ────────────────────────────────────────────────────

step "1/7  A healthy release is switched to"

build_host
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the new release" "$NEW_SHA" "$(current_release)"
assert_eq "the service is running" "yes" "$(service_running)"
assert_eq "the previous release is recorded" "${PREFIX}/releases/v0" \
  "$(cat "${PREFIX}/.previous_release")"

assert_eq "stopped on the old release, started on the new one" \
  "stop v0 | start ${NEW_SHA}" "$(systemctl_calls)"

if grep -q "^test$" "$FAKE_MIX_LOG"; then
  pass "the suite was run before switching over"
else
  fail "the suite was run before switching over" "mix log: $(tr '\n' ',' <"$FAKE_MIX_LOG")"
fi

## ── 2. A release that does not come up is rolled back ────────────────────

step "2/7  A red verify() rolls back automatically"

build_host
# The release update.sh is about to build is the one that will not come up.
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"

RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 3 — rolled back, service running" "3" "$RC"
assert_eq "current points back at the previous release" "v0" "$(current_release)"
assert_eq "the service is running again" "yes" "$(service_running)"
assert_eq "the service was cycled twice, ending on the old release" \
  "stop v0 | start ${NEW_SHA} | stop ${NEW_SHA} | start v0" "$(systemctl_calls)"

## ── 3. When the rollback does not come up either ─────────────────────────

step "3/7  A rollback that is also red is reported as such"

build_host
rm -rf "${PREFIX}/releases/v0"
make_release v0 broken >/dev/null
ln -sfn "${PREFIX}/releases/v0" "${PREFIX}/current"
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"

RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 1 — manual intervention" "1" "$RC"
if grep -q "Manual intervention needed" "${WORK}/out.log"; then
  pass "says manual intervention is needed"
else
  fail "says manual intervention is needed" "$(tail -3 "${WORK}/out.log")"
fi

## ── 4. --rollback ────────────────────────────────────────────────────────

step "4/7  --rollback returns to the recorded release"

# `.previous_release` is produced by a real update rather than written by hand,
# so the round trip an operator actually performs is the one under test.
build_host
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "the update it rolls back exits 0" "0" "$RC"

RC="$(run_update --rollback --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the recorded previous release" "v0" "$(current_release)"
assert_eq "the service is running" "yes" "$(service_running)"

step "4b   --rollback after an automatic rollback refuses instead of claiming success"

# After an automatic rollback `current` and `.previous_release` name the same
# release. Without a guard `--rollback` symlinked current onto itself, restarted
# and reported success, which is the worst possible answer to an operator
# reaching for it after a failed deploy.
build_host
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "the failed update rolled back (exit 3)" "3" "$RC"

RC="$(run_update --rollback --non-interactive)"
assert_eq "exits 2 — nothing to roll back to" "2" "$RC"
assert_eq "current is unchanged" "v0" "$(current_release)"
if grep -q "nothing to roll back to" "${WORK}/out.log"; then
  pass "says there is nothing to roll back to"
else
  fail "says there is nothing to roll back to" "$(tail -3 "${WORK}/out.log")"
fi

## ── 5. Refusals leave the running service alone ──────────────────────────

step "5/7  A red suite does not reach the switchover"

build_host
FAKE_MIX_TEST_FAILS="${WORK}/tests-are-red"
touch "$FAKE_MIX_TEST_FAILS"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
FAKE_MIX_TEST_FAILS=""

assert_eq "exits 1" "1" "$RC"
assert_eq "current still points at the old release" "v0" "$(current_release)"
assert_eq "the service was never stopped" "yes" "$(service_running)"
assert_eq "the code repo was put back on the running revision" "$OLD_SHA" \
  "$(git -C "${PREFIX}/repo" rev-parse --short HEAD)"

step "5b   Unpushed vault commits abort the preflight"

build_host
echo "# unpushed" >"${VAULT}/later.md"
git -C "$VAULT" add -A
git -C "$VAULT" commit -q -m "not pushed"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 2 — nothing was touched" "2" "$RC"
assert_eq "current still points at the old release" "v0" "$(current_release)"

## ── 5c. Persisted auth state survives the delivery ───────────────────────

step "5c   The OAuth tables are untouched by an update and by a rollback"

# What this pins is the delivery mechanism, not the records: no BEAM runs here,
# so the files are stand-ins. That an access token written by the *previous
# version* still validates under the new one is a question about the records
# and is pinned in test/vigil/oauth/store_compatibility_test.exs.

build_host
BEFORE="$(state_fingerprint)"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "the update exits 0" "0" "$RC"
assert_eq "the tables are byte-identical after the update" "$BEFORE" "$(state_fingerprint)"

# And again through the path that moves the symlink twice.
build_host
BEFORE="$(state_fingerprint)"
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "the failed update rolled back (exit 3)" "3" "$RC"
assert_eq "the tables are byte-identical after the rollback" "$BEFORE" "$(state_fingerprint)"

## ── 6. Cleanup keeps current, previous and one more ──────────────────────

step "6/7  Cleanup keeps three releases and never the running one"

build_host
for old in old1 old2 old3; do
  make_release "$old" >/dev/null
  # Distinct mtimes, newest last: the retention rule is "newest first".
  touch -t "2401010$((RANDOM % 9 + 1))00" "${PREFIX}/releases/${old}"
done
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
KEPT="$(find "${PREFIX}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_eq "three release directories remain" "3" "$KEPT"

if [ -d "${PREFIX}/releases/${NEW_SHA}" ]; then
  pass "the running release was kept"
else
  fail "the running release was kept"
fi
if [ -d "${PREFIX}/releases/v0" ]; then
  pass "the previous release was kept"
else
  fail "the previous release was kept"
fi

step "6b   Cleanup prunes a dot-directory left by an interrupted build"

# The retention rule has to select "directories directly under releases/",
# which a bare glob of non-hidden entries does not give you: a `.tmp-` left by
# an interrupted build would never be a candidate and would accumulate
# forever. update.sh also refuses to treat a symlink in releases/ as a
# candidate, restoring what `find -type d` selected; that half is not asserted
# here, because no arrangement of this fixture made the assertion go red when
# the guard was removed, and an assertion that cannot fail pins nothing.
build_host
make_release old1 >/dev/null
mkdir -p "${PREFIX}/releases/.tmp-interrupted"
touch -t 202401010000 "${PREFIX}/releases/.tmp-interrupted"

RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
if [ -d "${PREFIX}/releases/.tmp-interrupted" ]; then
  fail "the interrupted build was pruned"
else
  pass "the interrupted build was pruned"
fi

## ── 7. A prefix reached through a symlink ────────────────────────────────

step "7/7  Cleanup keeps the running release behind a symlinked prefix"

# The regression this pins: the cleanup compared `readlink -f` output against
# the unresolved directory listing, so with any symlink in the prefix nothing
# matched and neither the running release nor the rollback target was
# protected — leaving `update.sh --rollback` with nothing to roll back to.
build_host
make_release old1 >/dev/null
make_release old2 >/dev/null
ln -sfn "$PREFIX" "${WORK}/vigil-link"
PREFIX_OVERRIDE="${WORK}/vigil-link"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
PREFIX_OVERRIDE=""

assert_eq "exits 0" "0" "$RC"
if [ -d "${PREFIX}/releases/${NEW_SHA}" ]; then
  pass "the running release survived the cleanup"
else
  fail "the running release survived the cleanup" \
    "left: $(find "${PREFIX}/releases" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ' ')"
fi
if [ -d "${PREFIX}/releases/v0" ]; then
  pass "the previous release survived the cleanup"
else
  fail "the previous release survived the cleanup"
fi

## ── Summary ──────────────────────────────────────────────────────────────

echo
echo "──────────────────────────────────────────"
echo "  passed: ${PASS}    failed: ${FAIL}"
echo "──────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Last update.sh output:"
  tail -30 "${WORK}/out.log" || true
  exit 1
fi
exit 0
