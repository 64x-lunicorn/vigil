#!/usr/bin/env bash
# scripts/push_pending.sh — pushes the vault's commits when any are waiting.
#
# The push safety net (deploy/vigil-push.service, started by
# deploy/vigil-push.timer) runs this. vigil pushes on every write; when that
# push fails (GitHub briefly unreachable, say) the write still succeeds,
# answers `pushed: false`, and the commit waits locally for the next push.
# This is that next push if no write comes along to make it.
#
# Runs as the service user, under the service's sandbox, and never as root:
# the unit hands it the env file's settings in its environment (systemd reads
# /etc/vigil/env, which only root can), and a runtime directory only the
# service user can enter, where the lock lives. Run it by hand the same way:
#
#   sudo systemctl start vigil-push.service
#
# Pushes only when commits are pending, and takes a lock so two runs never
# overlap. The lock is this job's alone: vigil's own push does not take it.
# The vault's hooks are not run, and the push is given VIGIL_PUSH_TIMEOUT
# seconds. Prints nothing when there is nothing to push. Exits non-zero —
# which fails the unit, shows in the journal and starts its OnFailure= unit —
# when the push fails, and when commits have been waiting longer than
# VIGIL_PUSH_ALERT_AFTER minutes.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# A job that runs every 15 minutes has no run summary to give, and the journal
# would otherwise get one per run.
trap - EXIT

if [ "$(id -u)" -eq 0 ]; then
  err "push_pending.sh does not run as root. Start it as the service does: systemctl start vigil-push.service"
  exit 2
fi

# The caller is the service user already; su would need a privilege the
# sandbox does not give.
as_vigil() { "$@"; }

# The lock's directory is the unit's RuntimeDirectory=, which systemd creates
# for the service user with mode 0700 and removes when the run ends. Not /tmp
# or /run/lock: both are writable by every local user, who could create the
# lock first and hold it. A directory anyone but this user could write to is
# refused rather than used.
LOCK_DIR="${RUNTIME_DIRECTORY:-}"
if [ -z "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
  err "No runtime directory for the lock (RUNTIME_DIRECTORY is unset). Start it as the service does: systemctl start vigil-push.service"
  exit 2
fi
LOCK_DIR_MODE="$(stat -c '%a' "$LOCK_DIR" 2>/dev/null || stat -f '%Lp' "$LOCK_DIR")"
if [ ! -O "$LOCK_DIR" ] || [ $((8#${LOCK_DIR_MODE} & 8#022)) -ne 0 ]; then
  err "Refusing the lock directory ${LOCK_DIR}: it must belong to $(id -un) and be writable by nobody else (mode ${LOCK_DIR_MODE})."
  exit 2
fi
LOCK="${LOCK_DIR}/push.lock"

# The vault is where the env file says, as for the server.
VAULT_PATH="$(env_file_value VIGIL_VAULT_PATH)"
VAULT="${VAULT_PATH:-$VAULT}"
REMOTE="$(vault_git_remote)"
BRANCH="$(vault_git_branch "$VAULT")"

PUSH_TIMEOUT="$(env_file_value VIGIL_PUSH_TIMEOUT)"
PUSH_TIMEOUT="${PUSH_TIMEOUT:-120}"
ALERT_AFTER="$(env_file_value VIGIL_PUSH_ALERT_AFTER)"
ALERT_AFTER="${ALERT_AFTER:-60}"

# How many commits wait, or "?" when git cannot say (a remote-tracking branch
# that does not exist, say) — which is not nothing, so the push is tried and
# says what is wrong.
pending() {
  git -C "$VAULT" rev-list --count "${REMOTE}/${BRANCH}..${BRANCH}" 2>/dev/null || echo "?"
}

[ "$(pending)" = "0" ] && exit 0

# core.hooksPath=/dev/null: a pre-push hook in the vault is code whoever can
# write the vault chose, and it is not run. The ssh options are the ones
# Vigil.Git gives the server's own push, so a remote that stalls is noticed by
# ssh first; `timeout` bounds whatever ssh does not, and the unit's
# TimeoutStartSec= bounds the whole run.
PUSH_RC=0
(
  flock -n 9 || exit 0
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3" \
    timeout --kill-after=10 "$PUSH_TIMEOUT" \
    git -c core.hooksPath=/dev/null -C "$VAULT" push --quiet "$REMOTE" "$BRANCH"
) 9>"$LOCK" || PUSH_RC=$?

FAILED=0
if [ "$PUSH_RC" -eq 124 ] || [ "$PUSH_RC" -eq 137 ]; then
  err "git push ${REMOTE} ${BRANCH} did not finish within ${PUSH_TIMEOUT}s and was stopped."
  FAILED=1
elif [ "$PUSH_RC" -ne 0 ]; then
  err "git push ${REMOTE} ${BRANCH} failed (exit ${PUSH_RC})."
  FAILED=1
fi

# The alert on its own: whatever the reason — a push that keeps failing, a run
# that found the lock taken — commits that have waited too long are reported.
# The oldest waiting commit's committer date is when the wait began.
LEFT="$(pending)"
case "$LEFT" in
  0 | "?") ;;
  *)
    OLDEST="$(git -C "$VAULT" log --format=%ct "${REMOTE}/${BRANCH}..${BRANCH}" | tail -n 1)"
    WAITED_MINUTES=$((($(date +%s) - OLDEST) / 60))
    if [ "$WAITED_MINUTES" -ge "$ALERT_AFTER" ]; then
      err "${LEFT} vault commits have been unpushed for ${WAITED_MINUTES} minutes (VIGIL_PUSH_ALERT_AFTER=${ALERT_AFTER})."
      FAILED=1
    fi
    ;;
esac

exit "$FAILED"
