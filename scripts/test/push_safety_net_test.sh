#!/usr/bin/env bash
# scripts/test/push_safety_net_test.sh — the push safety net: a sandboxed
# timer that pushes what is pending and says so when it cannot.
#
# It was a cron line run as root that named the vault path, took its lock in
# world-writable /tmp, ran the vault's hooks, had no timeout and failed
# silently. What replaced it is three units in deploy/ and scripts/push_pending.sh;
# this checks the script against real repositories (the lock, the hooks, a
# remote that stalls, a push that fails, commits that waited too long, the
# settings the unit hands it in its environment), the units' text, and
# install_push_timer in lib.sh, which init.sh and update.sh install them with.
#
# systemd is not here: `systemctl` and `systemd-analyze` are stand-ins on PATH
# that record what they were asked, as in update_test.sh. What only a real
# host shows — the unit's score, OnFailure= firing, the runtime directory
# systemd makes — is not claimed here.
#
# Everything happens in a temp directory. No root, no network.
#
# Usage: bash scripts/test/push_safety_net_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUSH_SH="${REPO_ROOT}/scripts/push_pending.sh"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-push-test.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() {
  chmod -R u+rwx "${WORK:?}" 2>/dev/null || true
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM

BIN="${WORK}/bin"
mkdir -p "$BIN"
export PATH="${BIN}:${PATH}"

# flock is util-linux: present on the vault host and the CI runner, absent on
# macOS. A stand-in that always gets the lock keeps the test runnable there.
if ! command -v flock >/dev/null 2>&1; then
  printf '#!/bin/sh\nexit 0\n' >"${BIN}/flock"
  chmod +x "${BIN}/flock"
fi

# An ssh that connects and then never answers: a remote that stalls.
cat >"${BIN}/ssh" <<'SSH'
#!/bin/sh
exec sleep 60
SSH
chmod +x "${BIN}/ssh"

export VIGIL_STATE_DIR="${WORK}/state"
export VIGIL_ENV_FILE="${WORK}/env"
VAULT="${WORK}/state/vault"
UPSTREAM="${WORK}/upstream.git"
RUN_DIR="${WORK}/run"
OUT="${WORK}/out.txt"

git init --quiet --bare -b master "$UPSTREAM"
git init --quiet -b master "$VAULT"
git -C "$VAULT" config user.name "push test"
git -C "$VAULT" config user.email "test@localhost"
git -C "$VAULT" config commit.gpgsign false
echo "# note" >"${VAULT}/note.md"
git -C "$VAULT" add -A
git -C "$VAULT" commit --quiet -m "note"
git -C "$VAULT" remote add upstream "$UPSTREAM"
git -C "$VAULT" push --quiet -u upstream master
# A remote whose ssh never answers, with a remote-tracking branch to count
# against.
git -C "$VAULT" remote add stalled "ssh://git@stalled.invalid/vault.git"
git -C "$VAULT" update-ref refs/remotes/stalled/master HEAD
# One that is not there at all.
git -C "$VAULT" remote add gone "${WORK}/gone.git"
git -C "$VAULT" update-ref refs/remotes/gone/master HEAD

env_file() {
  printf '%s\n' "VIGIL_VAULT_PATH=${VAULT}" "$@" >"$VIGIL_ENV_FILE"
}

# A commit waiting to be pushed; with an argument, committed that many
# seconds ago.
commit_pending() {
  local name="pending-$RANDOM.md" when
  echo "# pending" >"${VAULT}/${name}"
  git -C "$VAULT" add -A
  if [ -n "${1:-}" ]; then
    when="$(($(date +%s) - $1)) +0000"
    GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" \
      git -C "$VAULT" commit --quiet -m "pending"
  else
    git -C "$VAULT" commit --quiet -m "pending"
  fi
}

# Runs push_pending.sh the way the unit does: as the service user (here, the
# caller), with the runtime directory systemd made. Prints the exit code.
push() {
  local rc
  set +e
  RUNTIME_DIRECTORY="${RUNTIME_DIRECTORY-$RUN_DIR}" bash "$PUSH_SH" >"$OUT" 2>&1
  rc=$?
  set -e
  echo "$rc"
}

upstream_head() { git --git-dir="$UPSTREAM" rev-parse master; }
vault_head() { git -C "$VAULT" rev-parse HEAD; }

says() {
  if grep -q -- "$2" "$OUT"; then
    pass "$1"
  else
    fail "$1" "output: $(tr '\n' ' ' <"$OUT")"
  fi
}

## ── 1. The lock ──────────────────────────────────────────────────────────

section "1/7  The lock is taken where no other user can create or hold it"

env_file "VIGIL_GIT_REMOTE=upstream" "VIGIL_GIT_BRANCH=master"
mkdir -m 0700 "$RUN_DIR"
commit_pending

RC="$(RUNTIME_DIRECTORY="" push)"
assert_eq "without a runtime directory: exits 2" "2" "$RC"
says "without a runtime directory: says how to start it" "systemctl start vigil-push.service"
assert_eq "without a runtime directory: nothing is pushed" "false" \
  "$([ "$(upstream_head)" = "$(vault_head)" ] && echo true || echo false)"

for mode in 0777 0770 0702; do
  chmod "$mode" "$RUN_DIR"
  RC="$(push)"
  assert_eq "a runtime directory at ${mode}: refused (exit 2)" "2" "$RC"
done
says "the refusal names the directory's mode" "writable by nobody else"
if [ -e "${RUN_DIR}/push.lock" ]; then
  fail "a refused directory gets no lock file"
else
  pass "a refused directory gets no lock file"
fi
chmod 0700 "$RUN_DIR"

RC="$(push)"
assert_eq "a runtime directory at 0700: exits 0" "0" "$RC"
assert_eq "the pending commit is pushed" "$(vault_head)" "$(upstream_head)"
if [ -f "${RUN_DIR}/push.lock" ]; then
  pass "the lock is taken in the runtime directory"
else
  fail "the lock is taken in the runtime directory" "$(ls -la "$RUN_DIR")"
fi

## ── 2. Hooks ─────────────────────────────────────────────────────────────

section "2/7  The vault's hooks are not run"

# A pre-push hook that would refuse the push and leave a mark.
cat >"${VAULT}/.git/hooks/pre-push" <<HOOK
#!/bin/sh
touch "${WORK}/hook-ran"
exit 1
HOOK
chmod +x "${VAULT}/.git/hooks/pre-push"
commit_pending

RC="$(push)"
assert_eq "exits 0" "0" "$RC"
assert_eq "the commit is pushed past a refusing hook" "$(vault_head)" "$(upstream_head)"
if [ -e "${WORK}/hook-ran" ]; then
  fail "the pre-push hook did not run"
else
  pass "the pre-push hook did not run"
fi
rm -f "${VAULT}/.git/hooks/pre-push"

## ── 3. A remote that stalls ──────────────────────────────────────────────

section "3/7  A stalled remote fails the run within its timeout"

env_file "VIGIL_GIT_REMOTE=stalled" "VIGIL_GIT_BRANCH=master" "VIGIL_PUSH_TIMEOUT=2"
STARTED="$(date +%s)"
RC="$(push)"
TOOK=$(($(date +%s) - STARTED))

assert_eq "exits 1" "1" "$RC"
if [ "$TOOK" -lt 15 ]; then
  pass "returns within the timeout, not the stall (${TOOK}s)"
else
  fail "returns within the timeout, not the stall" "took ${TOOK}s"
fi
says "says the push was stopped after its timeout" "did not finish within 2s"

## ── 4. A push that fails ─────────────────────────────────────────────────

section "4/7  A failed push fails the run and says so"

env_file "VIGIL_GIT_REMOTE=gone" "VIGIL_GIT_BRANCH=master"
RC="$(push)"
assert_eq "exits 1" "1" "$RC"
says "names the remote and the branch" "git push gone master failed"
if grep -q "unpushed for" "$OUT"; then
  fail "a fresh commit raises no waiting alert"
else
  pass "a fresh commit raises no waiting alert"
fi

## ── 5. Commits that waited too long ──────────────────────────────────────

section "5/7  Commits unpushed longer than VIGIL_PUSH_ALERT_AFTER are reported"

git -C "$VAULT" update-ref refs/remotes/gone/master "$(upstream_head)"
commit_pending 7200

env_file "VIGIL_GIT_REMOTE=gone" "VIGIL_GIT_BRANCH=master"
RC="$(push)"
assert_eq "two hours against the default hour: exits 1" "1" "$RC"
says "two hours against the default hour: says how long they waited" "unpushed for 1[0-9][0-9] minutes"

env_file "VIGIL_GIT_REMOTE=gone" "VIGIL_GIT_BRANCH=master" "VIGIL_PUSH_ALERT_AFTER=180"
RC="$(push)"
if grep -q "unpushed for" "$OUT"; then
  fail "two hours against three: no waiting alert"
else
  pass "two hours against three: no waiting alert"
fi

env_file "VIGIL_GIT_REMOTE=upstream" "VIGIL_GIT_BRANCH=master"
RC="$(push)"
assert_eq "once the push goes through: exits 0, whatever the age" "0" "$RC"

## ── 6. The settings the unit hands over ──────────────────────────────────

section "6/7  An env file only root can read is read from the environment"

if [ "$(id -u)" -eq 0 ]; then
  pass "skipped: root reads every file"
else
  env_file "VIGIL_GIT_REMOTE=gone" "VIGIL_GIT_BRANCH=gone-branch"
  chmod 000 "$VIGIL_ENV_FILE"
  commit_pending
  RC="$(VIGIL_VAULT_PATH="$VAULT" VIGIL_GIT_REMOTE=upstream VIGIL_GIT_BRANCH=master push)"
  chmod 600 "$VIGIL_ENV_FILE"
  assert_eq "exits 0" "0" "$RC"
  assert_eq "pushes to the remote and branch EnvironmentFile= exported" \
    "$(vault_head)" "$(upstream_head)"
fi

## ── 7. The units, and installing them ────────────────────────────────────

section "7/7  The units, and install_push_timer"

SERVICE_UNIT="${REPO_ROOT}/deploy/vigil-push.service"
for directive in \
  "Type=oneshot" \
  "User=vigil" \
  "Group=vigil" \
  "EnvironmentFile=/etc/vigil/env" \
  "RuntimeDirectory=vigil-push" \
  "RuntimeDirectoryMode=0700" \
  "ExecStart=/opt/vigil/repo/scripts/push_pending.sh" \
  "TimeoutStartSec=5min" \
  "OnFailure=vigil-notify@%N.service"; do
  if grep -qxF "$directive" "$SERVICE_UNIT"; then
    pass "vigil-push.service sets ${directive}"
  else
    fail "vigil-push.service sets ${directive}"
  fi
done

# The sandbox is the service's, copied unchanged (#217): from its heading to
# the end of [Service].
sandbox_of() { sed -n '/^# ── Sandbox/,/^\[Install\]/p' "$1" | sed '/^\[Install\]/d;${/^$/d;}'; }
if [ -n "$(sandbox_of "${REPO_ROOT}/deploy/vigil.service")" ] &&
  [ "$(sandbox_of "${REPO_ROOT}/deploy/vigil.service")" = "$(sandbox_of "$SERVICE_UNIT")" ]; then
  pass "vigil-push.service carries vigil.service's sandbox block unchanged"
else
  fail "vigil-push.service carries vigil.service's sandbox block unchanged" \
    "$(diff <(sandbox_of "${REPO_ROOT}/deploy/vigil.service") <(sandbox_of "$SERVICE_UNIT") | head -5)"
fi

TIMER_UNIT="${REPO_ROOT}/deploy/vigil-push.timer"
for directive in "Unit=vigil-push.service" "OnUnitInactiveSec=15min" "WantedBy=timers.target"; do
  if grep -qxF "$directive" "$TIMER_UNIT"; then
    pass "vigil-push.timer sets ${directive}"
  else
    fail "vigil-push.timer sets ${directive}"
  fi
done
if grep -q "^ExecStart=.*%i" "${REPO_ROOT}/deploy/vigil-notify@.service"; then
  pass "vigil-notify@.service names the failed unit"
else
  fail "vigil-notify@.service names the failed unit"
fi
if [ -e "${REPO_ROOT}/deploy/vigil-push-safety-net.cron" ]; then
  fail "the cron file is no longer shipped"
else
  pass "the cron file is no longer shipped"
fi

# install_push_timer, driven for real against a throwaway systemd directory.
cat >"${BIN}/systemctl" <<'SC'
#!/usr/bin/env bash
echo "$@" >>"${FAKE_SYSTEMCTL_LOG}"
SC
cat >"${BIN}/systemd-analyze" <<'SA'
#!/usr/bin/env bash
echo "$@" >>"${FAKE_SA_LOG}"
case "${1:-}" in
  verify)
    [ -f "${FAKE_SA_BROKEN:-/nonexistent}" ] && echo "vigil-push.service: Unknown key name 'Nonsense'"
    ;;
  security)
    if [ -f "${FAKE_SA_EXPOSED:-/nonexistent}" ]; then
      echo "→ Overall exposure level for vigil-push.service: 9.6 UNSAFE"
      exit 1
    fi
    echo "→ Overall exposure level for vigil-push.service: 2.1 OK"
    ;;
esac
exit 0
SA
chmod +x "${BIN}/systemctl" "${BIN}/systemd-analyze"

SYSTEMD="${WORK}/systemd"
CRON="${WORK}/cron.d/vigil-push-safety-net"

# Installs from this checkout's deploy/ in a fresh shell, as init.sh and
# update.sh do. Prints the exit code.
install_units() {
  local rc
  set +e
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash -c, not here
  env VIGIL_UNIT_FILE="${SYSTEMD}/vigil.service" VIGIL_PUSH_CRON_FILE="$CRON" \
    FAKE_SYSTEMCTL_LOG="${WORK}/systemctl.log" FAKE_SA_LOG="${WORK}/sa.log" \
    bash -c 'source "$1/scripts/lib.sh"; trap - EXIT; install_push_timer "$1/deploy"' \
    _ "$REPO_ROOT" >"$OUT" 2>&1
  rc=$?
  set -e
  echo "$rc"
}

fresh_host() {
  rm -rf "$SYSTEMD" "$(dirname "$CRON")"
  mkdir -p "$SYSTEMD" "$(dirname "$CRON")"
  echo "*/15 * * * * root /opt/vigil/repo/scripts/push_pending.sh" >"$CRON"
  : >"${WORK}/systemctl.log"
  : >"${WORK}/sa.log"
}

fresh_host
RC="$(install_units)"
assert_eq "installs: exits 0" "0" "$RC"
for unit in vigil-push.service vigil-push.timer vigil-notify@.service; do
  if cmp -s "${REPO_ROOT}/deploy/${unit}" "${SYSTEMD}/${unit}"; then
    pass "installs ${unit} as shipped"
  else
    fail "installs ${unit} as shipped"
  fi
done
if [ -e "$CRON" ]; then
  fail "removes the cron file"
else
  pass "removes the cron file"
fi
assert_eq "reloads systemd, then enables and starts the timer" \
  "daemon-reload|enable --now vigil-push.timer" "$(paste -sd'|' "${WORK}/systemctl.log")"
if grep -qE "^security --offline=true --threshold=30 .*/vigil-push\.service$" "${WORK}/sa.log"; then
  pass "scores the push unit against the 3.0 target"
else
  fail "scores the push unit against the 3.0 target" "$(paste -sd'|' "${WORK}/sa.log")"
fi

RC="$(install_units)"
assert_eq "a second run, with no cron file left: exits 0" "0" "$RC"

for refusal in exposed broken; do
  fresh_host
  touch "${WORK}/${refusal}"
  if [ "$refusal" = "exposed" ]; then
    RC="$(FAKE_SA_EXPOSED="${WORK}/exposed" install_units)"
  else
    RC="$(FAKE_SA_BROKEN="${WORK}/broken" install_units)"
  fi
  rm -f "${WORK}/${refusal}"
  assert_eq "a ${refusal} unit: returns 1" "1" "$RC"
  if [ -n "$(ls -A "$SYSTEMD")" ] || [ ! -e "$CRON" ] || [ -s "${WORK}/systemctl.log" ]; then
    fail "a ${refusal} unit: nothing installed, the cron file kept, systemd untouched"
  else
    pass "a ${refusal} unit: nothing installed, the cron file kept, systemd untouched"
  fi
done

# The notification template runs on every failure and is not scored: what is
# asked of it is that it runs as a dynamic user, as the shipped one does.
fresh_host
cp -R "${REPO_ROOT}/deploy" "${WORK}/deploy-root-notify"
sed -i.bak 's/^DynamicUser=yes$/User=root/' "${WORK}/deploy-root-notify/vigil-notify@.service"
set +e
# shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c, not here
env VIGIL_UNIT_FILE="${SYSTEMD}/vigil.service" VIGIL_PUSH_CRON_FILE="$CRON" \
  FAKE_SYSTEMCTL_LOG="${WORK}/systemctl.log" FAKE_SA_LOG="${WORK}/sa.log" \
  bash -c 'source "$1/scripts/lib.sh"; trap - EXIT; install_push_timer "$2"' \
  _ "$REPO_ROOT" "${WORK}/deploy-root-notify" >"$OUT" 2>&1
RC=$?
set -e
assert_eq "a notification unit with User=root: returns 1" "1" "$RC"
if [ -n "$(ls -A "$SYSTEMD")" ] || [ ! -e "$CRON" ]; then
  fail "a notification unit with User=root: nothing installed, the cron file kept"
else
  pass "a notification unit with User=root: nothing installed, the cron file kept"
fi
if grep -qx "DynamicUser=yes" "${REPO_ROOT}/deploy/vigil-notify@.service"; then
  pass "the shipped vigil-notify@.service runs as a dynamic user"
else
  fail "the shipped vigil-notify@.service runs as a dynamic user"
fi

# shellcheck disable=SC2016 # the text init.sh contains, not an expansion
if grep -q 'prepare_push_units "${SCRIPT_DIR}/../deploy"' "${REPO_ROOT}/scripts/init.sh" &&
  grep -q '^install_push_units$' "${REPO_ROOT}/scripts/init.sh" &&
  ! grep -q "cron" <(grep -v '^ *#' "${REPO_ROOT}/scripts/init.sh"); then
  pass "init.sh installs the timer and writes no cron file"
else
  fail "init.sh installs the timer and writes no cron file"
fi

report
