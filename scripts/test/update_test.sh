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

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK=""

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
      echo "Dependency foo 1.0.0 is retired: security"
      exit 1
    else
      echo "No retired packages found"
    fi
    ;;
  deps.audit)
    echo "No vulnerabilities found."
    ;;
  vigil.slug_diff)
    # vigil.slug_diff --against <ids-file> <vault>: records the list the
    # running release gave, and answers a change when the test says so.
    echo "slug_diff saw: $(cat "${3:-/nonexistent}" 2>/dev/null) exclude=${VIGIL_EXCLUDE:-} env=${MIX_ENV:-}" >>"${FAKE_MIX_LOG}"
    if [ -f "${FAKE_SLUG_DIFF_CHANGES:-/nonexistent}" ]; then
      printf '2 chunk id change(s):\n\n  - note.md#oil-1\n  + note.md#oil-2\n'
      exit 1
    fi
    echo "No chunk id changes (1 ids compared)."
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
    if [ -f "${FAKE_MIX_RELEASE_FAILS:-/nonexistent}" ]; then
      echo "fake mix: the build failed" >&2
      exit 1
    fi
    mkdir -p "${path}/bin"
    cp "$(dirname "$0")/release-bin" "${path}/bin/vigil"
    ;;
esac
exit 0
MIX
  chmod +x "${BIN}/mix"

  # A release's bin/vigil, as the fake build above and make_release below
  # write it: `eval` is the only command update.sh gives it
  # outside systemd, and it answers with the chunk ids the running release
  # derives — one id naming the release, so the test can see whose list
  # reached the comparison. A release holding .no-chunk-ids is one built
  # before Vigil.Release.chunk_ids/0 existed, and says so the way `eval` does;
  # one holding .chunk-ids-crash fails for any other reason.
  cat >"${BIN}/release-bin" <<'REL'
#!/bin/sh
release="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "eval" ]; then
  if [ -f "${release}/.no-chunk-ids" ]; then
    echo "** (UndefinedFunctionError) function Vigil.Release.chunk_ids/0 is undefined (module Vigil.Release is not available)" >&2
    exit 1
  fi
  if [ -f "${release}/.chunk-ids-crash" ]; then
    echo "** (File.Error) could not read vault: permission denied" >&2
    exit 1
  fi
  echo "note.md#seen-by-$(basename "$release") vault=${VIGIL_VAULT_PATH:-}"
fi
exit 0
REL
  chmod +x "${BIN}/release-bin"
}

# A `systemd-analyze` that accepts every unit it is asked to verify and scores
# every sandbox as within the target, unless the test says otherwise. What
# update.sh asked it is logged, so the test can see which file was judged
# against which threshold.
build_fake_systemd_analyze() {
  mkdir -p "$BIN"
  cat >"${BIN}/systemd-analyze" <<'SA'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_SA_LOG}"
case "${1:-}" in
  security)
    if [ -f "${FAKE_SA_EXPOSED:-/nonexistent}" ]; then
      echo "→ Overall exposure level for vigil.service: 9.6 UNSAFE"
      exit 1
    fi
    echo "→ Overall exposure level for vigil.service: 2.0 OK"
    ;;
esac
exit 0
SA
  chmod +x "${BIN}/systemd-analyze"
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
  # The push safety net's units as this checkout ships them: update.sh
  # installs them on every update.
  for unit in vigil-push.service vigil-push.timer vigil-notify@.service; do
    cp "${REPO_ROOT}/deploy/${unit}" "${repo}/deploy/${unit}"
  done
  echo "v1" >"${repo}/version"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "v1"
  OLD_SHA="$(git -C "$repo" rev-parse --short HEAD)"
  echo "v2" >"${repo}/version"
  git -C "$repo" commit -qam "v2"
  NEW_SHA="$(git -C "$repo" rev-parse --short HEAD)"
  git -C "$repo" checkout -q "$OLD_SHA"
}

# A vault whose `upstream/master..master` count is 0, which is what preflight
# asks. Neither name is a default: the env file below states both, and a
# preflight that counted `github/main..main` instead could not count at all
# and would refuse every update here.
build_vault() {
  mkdir -p "$VAULT"
  git -C "$VAULT" init -q -b master
  git -C "$VAULT" config user.email test@example.com
  git -C "$VAULT" config user.name "Update Test"
  echo "# note" >"${VAULT}/note.md"
  git -C "$VAULT" add -A
  git -C "$VAULT" commit -q -m "note"
  git -C "$VAULT" update-ref refs/remotes/upstream/master HEAD
}

# One release directory, optionally one that does not come up. Each one
# carries the commit it was built from, as update.sh writes it: the running
# revision is read from there, not from the checkout.
make_release() {
  local name="$1" healthy="${2:-healthy}"
  mkdir -p "${PREFIX}/releases/${name}/bin"
  cp "${BIN}/release-bin" "${PREFIX}/releases/${name}/bin/vigil"
  git -C "${PREFIX}/repo" rev-parse "$OLD_SHA" >"${PREFIX}/releases/${name}/REVISION"
  [ "$healthy" = "broken" ] && touch "${PREFIX}/releases/${name}/.verify-fails"
  echo "${PREFIX}/releases/${name}"
}

# A release switched to that never answers on /healthz, as opposed to one that
# answers and fails the acceptance check.
make_unbootable() {
  mkdir -p "${PREFIX}/releases/$1"
  touch "${PREFIX}/releases/$1/.boot-fails"
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
VIGIL_SKILLKEY_SECRET=not-a-real-secret-the-stubbed-release-never-reads-it
VIGIL_GIT_REMOTE=upstream
VIGIL_GIT_BRANCH=master
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
    VIGIL_PUSH_CRON_FILE="${WORK}/etc/cron.d/vigil-push-safety-net" \
    VIGIL_SERVICE_USER="$(id -un)" \
    VIGIL_SERVICE_GROUP="$(id -gn)" \
    FAKE_MIX_LOG="$FAKE_MIX_LOG" \
    FAKE_MIX_TEST_FAILS="${FAKE_MIX_TEST_FAILS:-/nonexistent}" \
    FAKE_MIX_AUDIT_CRITICAL="${FAKE_MIX_AUDIT_CRITICAL:-/nonexistent}" \
    FAKE_MIX_RELEASE_FAILS="${FAKE_MIX_RELEASE_FAILS:-/nonexistent}" \
    FAKE_SA_LOG="${WORK}/systemd-analyze.log" \
    FAKE_SA_EXPOSED="${FAKE_SA_EXPOSED:-/nonexistent}" \
    FAKE_SLUG_DIFF_CHANGES="${FAKE_SLUG_DIFF_CHANGES:-/nonexistent}" \
    bash "$UPDATE_SH" "$@" <"${UPDATE_STDIN:-/dev/null}" >"${WORK}/out.log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

current_release() { basename "$(readlink "${PREFIX}/current")"; }
checkout_sha() { git -C "${PREFIX}/repo" rev-parse --short HEAD; }

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
build_fake_systemd_analyze

## ── 1. The happy path ────────────────────────────────────────────────────

section "1/8  A healthy release is switched to"

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

section "2/8  A red verify() rolls back automatically"

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

section "3/8  A rollback that is also red is reported as such"

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

section "4/8  --rollback returns to the recorded release"

# `.previous_release` is produced by a real update rather than written by hand,
# so the round trip an operator actually performs is the one under test.
build_host
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "the update it rolls back exits 0" "0" "$RC"

RC="$(run_update --rollback --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the recorded previous release" "v0" "$(current_release)"
assert_eq "the service is running" "yes" "$(service_running)"

section "4b   --rollback after an automatic rollback refuses instead of claiming success"

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

section "5/8  A red suite does not reach the switchover"

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

section "5b   Unpushed vault commits abort the preflight"

build_host
echo "# unpushed" >"${VAULT}/later.md"
git -C "$VAULT" add -A
git -C "$VAULT" commit -q -m "not pushed"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 2 — nothing was touched" "2" "$RC"
assert_eq "current still points at the old release" "v0" "$(current_release)"

section "5b2  An env file without the SkillKey secret aborts the preflight"

# A host set up before VIGIL_SKILLKEY_SECRET existed. The new release would
# refuse to boot; step 6 would roll it back, but only after stopping the
# service, so preflight catches it first, and says what to add.
build_host
sed -i.bak '/^VIGIL_SKILLKEY_SECRET=/d' "$ENV_FILE"
rm -f "${ENV_FILE}.bak"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 2 — nothing was touched" "2" "$RC"
assert_eq "current still points at the old release" "v0" "$(current_release)"
assert_eq "the service was never stopped" "yes" "$(service_running)"
if grep -q "VIGIL_SKILLKEY_SECRET" "${WORK}/out.log" &&
  grep -q "openssl rand -base64 48" "${WORK}/out.log"; then
  pass "names the variable and how to generate one"
else
  fail "names the variable and how to generate one" "$(tail -3 "${WORK}/out.log")"
fi

## ── 5c. Persisted auth state survives the delivery ───────────────────────

section "5c   The OAuth tables are untouched by an update and by a rollback"

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

section "6/8  Cleanup keeps three releases and never the running one"

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

section "6b   Cleanup prunes a dot-directory left by an interrupted build"

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

section "7/8  Cleanup keeps the running release behind a symlinked prefix"

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

## ── 8. --update-unit ships the unit ──────────────────────────────────────

section "8/8  --update-unit installs the unit the target revision carries"

SHIPPED_UNIT="${REPO_ROOT}/deploy/vigil.service"

# A third commit whose deploy/vigil.service is the real one from this
# checkout, so what the test sees installed is the unit this change ships.
commit_shipped_unit() {
  local repo="${PREFIX}/repo"
  git -C "$repo" checkout -q main
  cp "$SHIPPED_UNIT" "${repo}/deploy/vigil.service"
  git -C "$repo" commit -qam "hardened unit"
  UNIT_SHA="$(git -C "$repo" rev-parse --short HEAD)"
  git -C "$repo" checkout -q "$OLD_SHA"
}

build_host
commit_shipped_unit
: >"${WORK}/systemd-analyze.log"
RC="$(run_update --to "$UNIT_SHA" --update-unit --non-interactive)"

assert_eq "exits 0" "0" "$RC"
if cmp -s "$SHIPPED_UNIT" "${WORK}/etc/vigil.service"; then
  pass "the installed unit is deploy/vigil.service of the target revision"
else
  fail "the installed unit is deploy/vigil.service of the target revision"
fi
assert_eq "the installed unit is 0644" "644" "$(mode_of "${WORK}/etc/vigil.service")"
if grep -qE "^security --offline=true --threshold=30 .*/vigil\.service$" "${WORK}/systemd-analyze.log"; then
  pass "its sandbox was scored against the 3.0 target before it was installed"
else
  fail "its sandbox was scored against the 3.0 target before it was installed" \
    "systemd-analyze calls: $(paste -sd'|' "${WORK}/systemd-analyze.log")"
fi

section "8b   Without --update-unit the unit is left alone"

build_host
commit_shipped_unit
RC="$(run_update --to "$UNIT_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
if [ -e "${WORK}/etc/vigil.service" ]; then
  fail "no unit was installed"
else
  pass "no unit was installed"
fi
if grep -q -- "--update-unit" "${WORK}/out.log"; then
  pass "says how to adopt the changed unit"
else
  fail "says how to adopt the changed unit" "$(tail -3 "${WORK}/out.log")"
fi

section "8c   A unit above the exposure target is refused"

build_host
commit_shipped_unit
FAKE_SA_EXPOSED="${WORK}/unit-is-exposed"
touch "$FAKE_SA_EXPOSED"
RC="$(run_update --to "$UNIT_SHA" --update-unit --non-interactive)"
FAKE_SA_EXPOSED=""

assert_eq "exits 1" "1" "$RC"
if [ -e "${WORK}/etc/vigil.service" ]; then
  fail "the exposed unit was not installed"
else
  pass "the exposed unit was not installed"
fi
assert_eq "current still points at the old release" "v0" "$(current_release)"
assert_eq "the service was never stopped" "yes" "$(service_running)"

section "8d   The shipped unit carries the sandbox"

# The options #217 asked for, one line each. `systemd-analyze security` on a
# host is the judgement; this is what keeps one of them from quietly going
# missing in between.
for directive in \
  "UMask=0077" \
  "Environment=ERL_CRASH_DUMP_SECONDS=0" \
  "LimitCORE=0" \
  "ReadOnlyPaths=-/var/lib/vigil/.ssh" \
  "ReadWritePaths=/var/lib/vigil" \
  "CapabilityBoundingSet=" \
  "AmbientCapabilities=" \
  "ProtectKernelTunables=true" \
  "ProtectKernelModules=true" \
  "ProtectKernelLogs=true" \
  "ProtectControlGroups=true" \
  "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
  "SystemCallFilter=@system-service" \
  "StartLimitIntervalSec=300" \
  "StartLimitBurst=5"; do
  if grep -qxF "$directive" "$SHIPPED_UNIT"; then
    pass "deploy/vigil.service sets ${directive}"
  else
    fail "deploy/vigil.service sets ${directive}"
  fi
done
if grep -q "^MemoryDenyWriteExecute=" "$SHIPPED_UNIT"; then
  fail "MemoryDenyWriteExecute stays off for the JIT"
else
  pass "MemoryDenyWriteExecute stays off for the JIT"
fi

## ── 9. The push safety net ───────────────────────────────────────────────

section "9/9  An update moves the push safety net from cron to the timer"

build_host
mkdir -p "${WORK}/etc/cron.d"
echo "*/15 * * * * root /opt/vigil/repo/scripts/push_pending.sh" \
  >"${WORK}/etc/cron.d/vigil-push-safety-net"
: >"${WORK}/systemd-analyze.log"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
if [ -e "${WORK}/etc/cron.d/vigil-push-safety-net" ]; then
  fail "the cron file is removed"
else
  pass "the cron file is removed"
fi
for unit in vigil-push.service vigil-push.timer vigil-notify@.service; do
  if cmp -s "${REPO_ROOT}/deploy/${unit}" "${WORK}/etc/${unit}"; then
    pass "${unit} is installed as shipped"
  else
    fail "${unit} is installed as shipped"
  fi
done
if grep -qx "enable --now vigil-push.timer" "${PREFIX}/.systemctl-units.log" 2>/dev/null &&
  grep -qx "daemon-reload" "${PREFIX}/.systemctl-units.log"; then
  pass "systemd is reloaded and the timer enabled and started"
else
  fail "systemd is reloaded and the timer enabled and started" \
    "systemctl calls: $(paste -sd'|' "${PREFIX}/.systemctl-units.log" 2>/dev/null)"
fi
if grep -qE "^security --offline=true --threshold=30 .*/vigil-push\.service$" "${WORK}/systemd-analyze.log"; then
  pass "the push unit's sandbox was scored against the 3.0 target"
else
  fail "the push unit's sandbox was scored against the 3.0 target" \
    "systemd-analyze calls: $(paste -sd'|' "${WORK}/systemd-analyze.log")"
fi

section "9b   A push unit above the exposure target stops the update before the switch"

build_host
FAKE_SA_EXPOSED="${WORK}/unit-is-exposed"
touch "$FAKE_SA_EXPOSED"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
FAKE_SA_EXPOSED=""

assert_eq "exits 1" "1" "$RC"
if [ -e "${WORK}/etc/vigil-push.service" ]; then
  fail "the exposed push unit was not installed"
else
  pass "the exposed push unit was not installed"
fi
assert_eq "current still points at the old release" "v0" "$(current_release)"
assert_eq "the service was never stopped" "yes" "$(service_running)"

## ── 10. The checkout follows the running release ────────────────────────

section "10   A failed build leaves the checkout on the running revision"

# Before, the checkout stayed on the target after a failed build, and the
# running revision was read from the checkout — so the same update, run again,
# found the target "running" and reported nothing to do.
build_host
FAKE_MIX_RELEASE_FAILS="${WORK}/build-fails"
touch "$FAKE_MIX_RELEASE_FAILS"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
FAKE_MIX_RELEASE_FAILS=""

assert_eq "exits 1" "1" "$RC"
assert_eq "current still points at the old release" "v0" "$(current_release)"
assert_eq "the service was never stopped" "yes" "$(service_running)"
assert_eq "the checkout is back on the running revision" "$OLD_SHA" "$(checkout_sha)"

section "10b  The same update, run again after a failed build, proceeds"

RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the new release" "$NEW_SHA" "$(current_release)"
if grep -q "nothing to do" "${WORK}/out.log"; then
  fail "does not report nothing to do" "$(grep "nothing to do" "${WORK}/out.log")"
else
  pass "does not report nothing to do"
fi
assert_eq "the checkout is on the new revision" "$NEW_SHA" "$(checkout_sha)"
assert_eq "the new release records the commit it was built from" \
  "$(git -C "${PREFIX}/repo" rev-parse "$NEW_SHA")" \
  "$(cat "${PREFIX}/releases/${NEW_SHA}/REVISION")"

section "10c  The running revision is read from the release, not the checkout"

# A checkout moved by hand, onto the target: the release still runs the old
# commit, so the update is not "nothing to do".
build_host
git -C "${PREFIX}/repo" checkout -q "$NEW_SHA"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the new release" "$NEW_SHA" "$(current_release)"

section "10d  After an automatic rollback the checkout matches the running release"

build_host
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "the failed update rolled back (exit 3)" "3" "$RC"
assert_eq "current points back at the previous release" "v0" "$(current_release)"
assert_eq "the checkout is on the running revision" "$OLD_SHA" "$(checkout_sha)"

rm -f "${BROKEN_TARGET}/.verify-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "the same update, run again once fixed, exits 0" "0" "$RC"
assert_eq "and switches to the new release" "$NEW_SHA" "$(current_release)"

section "10e  --rollback puts the checkout back on the release it returns to"

build_host
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "the update it rolls back exits 0" "0" "$RC"
RC="$(run_update --rollback --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the recorded previous release" "v0" "$(current_release)"
assert_eq "the checkout is on the revision of that release" "$OLD_SHA" "$(checkout_sha)"

section "10f  A release that never comes up is rolled back too"

# The health wait after the switch used to exit on its own, leaving the new
# release switched in and the service down. And a release that crashes on
# boot uses up the unit's start limit while it is waited for, so the start
# of the old release is refused unless the failed starts are cleared first:
# the stand-in systemctl logs that start as "refused".
build_host
make_unbootable "$NEW_SHA"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 3 — rolled back, service running" "3" "$RC"
assert_eq "current points back at the previous release" "v0" "$(current_release)"
assert_eq "the service is running again" "yes" "$(service_running)"
assert_eq "the service was cycled twice, ending on the old release" \
  "stop v0 | start ${NEW_SHA} | stop ${NEW_SHA} | start v0" "$(systemctl_calls)"
assert_eq "the checkout is on the running revision" "$OLD_SHA" "$(checkout_sha)"

section "10g  When the previous release does not come up either, that is said"

build_host
make_unbootable v0
make_unbootable "$NEW_SHA"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 1 — manual intervention" "1" "$RC"
if grep -q "Manual intervention needed" "${WORK}/out.log"; then
  pass "says manual intervention is needed"
else
  fail "says manual intervention is needed" "$(tail -3 "${WORK}/out.log")"
fi

section "10h  A start systemd refuses is rolled back, not the end of the run"

build_host
make_unbootable "$NEW_SHA"
rm -f "${PREFIX}/releases/${NEW_SHA}/.boot-fails"
touch "${PREFIX}/releases/${NEW_SHA}/.start-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 3 — rolled back, service running" "3" "$RC"
assert_eq "current points back at the previous release" "v0" "$(current_release)"
assert_eq "the service is running again" "yes" "$(service_running)"

section "10i  A release from before /healthz is one the rollback can go back to"

# vigil 0.2 answers /healthz with 404. Going back to it — automatically or with
# --rollback — is going back to a release that is up; switching to one is not.
build_host
touch "${PREFIX}/releases/v0/.no-healthz"
BROKEN_TARGET="${PREFIX}/releases/${NEW_SHA}"
mkdir -p "$BROKEN_TARGET"
touch "${BROKEN_TARGET}/.verify-fails"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "the automatic rollback to it exits 3, not 1" "3" "$RC"
assert_eq "current points back at it" "v0" "$(current_release)"
assert_eq "the service is running" "yes" "$(service_running)"

build_host
touch "${PREFIX}/releases/v0/.no-healthz"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "an update away from it exits 0" "0" "$RC"
RC="$(run_update --rollback --non-interactive)"
assert_eq "--rollback to it exits 0" "0" "$RC"
assert_eq "--rollback: current points at it" "v0" "$(current_release)"

build_host
make_unbootable "$NEW_SHA"
rm -f "${PREFIX}/releases/${NEW_SHA}/.boot-fails"
touch "${PREFIX}/releases/${NEW_SHA}/.no-healthz"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"
assert_eq "a release switched to without /healthz is rolled back (exit 3)" "3" "$RC"
assert_eq "current points back at the previous release" "v0" "$(current_release)"

## ── 11. --rebuild ────────────────────────────────────────────────────────

section "11   --rebuild builds the running commit into a new release and switches to it"

build_host
RC="$(run_update --rebuild --non-interactive)"

assert_eq "exits 0" "0" "$RC"
REBUILT="$(current_release)"
case "$REBUILT" in
  "${OLD_SHA}-"*) pass "the new release is named after the running commit" ;;
  *) fail "the new release is named after the running commit" "current: ${REBUILT}" ;;
esac
if [ -x "${PREFIX}/releases/${REBUILT}/bin/vigil" ]; then
  pass "the new release directory was built"
else
  fail "the new release directory was built"
fi
assert_eq "it records the commit it was built from" \
  "$(git -C "${PREFIX}/repo" rev-parse "$OLD_SHA")" \
  "$(cat "${PREFIX}/releases/${REBUILT}/REVISION")"
assert_eq "the previous release is recorded" "${PREFIX}/releases/v0" \
  "$(cat "${PREFIX}/.previous_release")"
assert_eq "stopped on the old release, started on the rebuilt one" \
  "stop v0 | start ${REBUILT}" "$(systemctl_calls)"
assert_eq "the checkout is on the running revision" "$OLD_SHA" "$(checkout_sha)"

section "11b  A second --rebuild builds yet another release, and --rollback returns"

RC="$(run_update --rebuild --non-interactive)"
assert_eq "exits 0" "0" "$RC"
if [ "$(current_release)" != "$REBUILT" ]; then
  pass "switched to a release directory of its own"
else
  fail "switched to a release directory of its own" "current: $(current_release)"
fi
RC="$(run_update --rollback --non-interactive)"
assert_eq "--rollback exits 0" "0" "$RC"
assert_eq "and returns to the first rebuild" "$REBUILT" "$(current_release)"

section "11c  --rebuild does not combine with --to or --rollback"

build_host
RC="$(run_update --rebuild --to "$NEW_SHA" --non-interactive)"
assert_eq "--rebuild --to exits 2" "2" "$RC"
RC="$(run_update --rebuild --rollback --non-interactive)"
assert_eq "--rebuild --rollback exits 2" "2" "$RC"
assert_eq "current is unchanged" "v0" "$(current_release)"

## ── 12. Chunk ids ────────────────────────────────────────────────────────

section "12   The running release's chunk ids are compared with the target's"

build_host
echo "VIGIL_EXCLUDE=private" >>"$ENV_FILE"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "no change: exits 0" "0" "$RC"
assert_eq "and switches" "$NEW_SHA" "$(current_release)"
if grep -q "^slug_diff saw: note.md#seen-by-v0 vault=${VAULT} exclude=private env=prod$" "$FAKE_MIX_LOG"; then
  pass "the running release's list of the vault, with its exclusions, reached the target's comparison"
else
  fail "the running release's list of the vault, with its exclusions, reached the target's comparison" \
    "mix log: $(grep slug_diff "$FAKE_MIX_LOG" || echo none)"
fi

section "12b  A change is refused under --non-interactive without --accept-id-changes"

build_host
touch "${WORK}/slug-diff-changes"
RC="$(FAKE_SLUG_DIFF_CHANGES="${WORK}/slug-diff-changes" run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 2" "2" "$RC"
assert_eq "current is unchanged" "v0" "$(current_release)"
assert_eq "the service was never cycled" "(none)" "$(systemctl_calls)"
assert_eq "the checkout is back on the running revision" "$OLD_SHA" "$(checkout_sha)"
if grep -q -- "- note.md#oil-1" "${WORK}/out.log" && grep -q -- "--accept-id-changes" "${WORK}/out.log"; then
  pass "names the ids that would move and the flag that accepts it"
else
  fail "names the ids that would move and the flag that accepts it" "$(tail -5 "${WORK}/out.log")"
fi

section "12c  --accept-id-changes switches anyway"

build_host
RC="$(FAKE_SLUG_DIFF_CHANGES="${WORK}/slug-diff-changes" run_update --to "$NEW_SHA" --non-interactive --accept-id-changes)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the new release" "$NEW_SHA" "$(current_release)"

section "12d  Asked interactively, no aborts and yes switches"

build_host
echo "n" >"${WORK}/answer"
RC="$(FAKE_SLUG_DIFF_CHANGES="${WORK}/slug-diff-changes" UPDATE_STDIN="${WORK}/answer" run_update --to "$NEW_SHA")"
assert_eq "declined: exits 4" "4" "$RC"
assert_eq "declined: current is unchanged" "v0" "$(current_release)"
assert_eq "declined: the service was never cycled" "(none)" "$(systemctl_calls)"

build_host
echo "y" >"${WORK}/answer"
RC="$(FAKE_SLUG_DIFF_CHANGES="${WORK}/slug-diff-changes" UPDATE_STDIN="${WORK}/answer" run_update --to "$NEW_SHA")"
assert_eq "accepted: exits 0" "0" "$RC"
assert_eq "accepted: current points at the new release" "$NEW_SHA" "$(current_release)"
rm -f "${WORK}/slug-diff-changes"

section "12e  A running release that cannot list its ids is not compared, and that is said"

build_host
touch "${PREFIX}/releases/v0/.no-chunk-ids"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 0" "0" "$RC"
assert_eq "current points at the new release" "$NEW_SHA" "$(current_release)"
if grep -q "cannot list its chunk ids" "${WORK}/out.log"; then
  pass "says the switch was not compared"
else
  fail "says the switch was not compared" "$(grep -i chunk "${WORK}/out.log" || echo none)"
fi
if grep -q "slug_diff" "$FAKE_MIX_LOG"; then
  fail "the target was not asked to compare against nothing"
else
  pass "the target was not asked to compare against nothing"
fi

section "12e2 A running release that fails to list its ids stops the run"

# Only a release too old to be asked is let through uncompared. Any other
# failure — the one fs.protected_regular=2 made of root writing the list into
# a file the service account had made in /tmp, say — used to read the same.
build_host
touch "${PREFIX}/releases/v0/.chunk-ids-crash"
RC="$(run_update --to "$NEW_SHA" --non-interactive)"

assert_eq "exits 1" "1" "$RC"
assert_eq "current is unchanged" "v0" "$(current_release)"
assert_eq "the service was never cycled" "(none)" "$(systemctl_calls)"
if grep -q "permission denied" "${WORK}/out.log" && grep -q "could not list its chunk ids" "${WORK}/out.log"; then
  pass "shows what the release said and that the switch is not made"
else
  fail "shows what the release said and that the switch is not made" "$(grep -i chunk "${WORK}/out.log" || echo none)"
fi

# The list reaches the comparison through a file the service account writes;
# the root shell never opens one it did not create itself.
# shellcheck disable=SC2016 # the needle is update.sh's text, not an expansion
if grep -nE '>>? *"\$running_ids"' "$UPDATE_SH"; then
  fail "update.sh never redirects into the service account's ids file"
else
  pass "update.sh never redirects into the service account's ids file"
fi

section "12f  --rebuild moves no id and compares nothing"

build_host
RC="$(run_update --rebuild --non-interactive)"
assert_eq "exits 0" "0" "$RC"
if grep -q "slug_diff" "$FAKE_MIX_LOG"; then
  fail "no comparison for the running commit"
else
  pass "no comparison for the running commit"
fi

## ── Summary ──────────────────────────────────────────────────────────────

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Last update.sh output:"
  tail -30 "${WORK}/out.log" || true
fi

report
