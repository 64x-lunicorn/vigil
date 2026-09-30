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
# It fetches first, and refuses to push commits a force-push took off the
# remote, as vigil's own push does. The vault's hooks are not run, and the
# fetch and the push are each given VIGIL_PUSH_TIMEOUT seconds. Prints nothing
# when there is nothing to push. Exits non-zero — which fails the unit, shows
# in the journal and starts its OnFailure= unit — when the fetch or the push
# fails, when the push is refused, and when commits have been waiting longer
# than VIGIL_PUSH_ALERT_AFTER minutes.

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

# The two settings the server does not check, so they are checked here, and a
# bad one fails the run — which starts the notification — rather than being
# read as something else: a word in VIGIL_PUSH_ALERT_AFTER made the alert's
# comparison fail silently, so it never fired, and a timeout past the unit's
# TimeoutStartSec= (5 min) was cut short by systemd instead. The push's
# timeout leaves room for timeout's own --kill-after (10 s) inside those five
# minutes; the alert may wait up to a week.
PUSH_TIMEOUT_MAX=280
ALERT_AFTER_MAX=10080
# in_range <value> <max> — a whole number from 1 to max, without a sign or a
# leading zero, which $(( )) would read as octal.
in_range() {
  [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -le "$2" ]
}
if ! in_range "$PUSH_TIMEOUT" "$PUSH_TIMEOUT_MAX"; then
  err "VIGIL_PUSH_TIMEOUT must be a whole number of seconds from 1 to ${PUSH_TIMEOUT_MAX} (below the unit's TimeoutStartSec of 5 minutes), got \"${PUSH_TIMEOUT}\"."
  exit 2
fi
if ! in_range "$ALERT_AFTER" "$ALERT_AFTER_MAX"; then
  err "VIGIL_PUSH_ALERT_AFTER must be a whole number of minutes from 1 to ${ALERT_AFTER_MAX} (a week), got \"${ALERT_AFTER}\"."
  exit 2
fi

# How many commits wait, or "?" when git cannot say (a remote-tracking branch
# that does not exist, say) — which is not nothing, so the push is tried and
# says what is wrong.
pending() {
  git -C "$VAULT" rev-list --count "${REMOTE}/${BRANCH}..${BRANCH}" 2>/dev/null || echo "?"
}

[ "$(pending)" = "0" ] && exit 0

# rewritten — how many commits the branch holds that the remote once held and
# a force-push took away: the rule Vigil.Git.push/3 refuses on
# (docs/design.md, "The server stays in step with the remote"). The fork
# point is the newest commit of the branch the remote-tracking branch ever
# pointed at, by that ref's reflog (`git merge-base --fork-point`, what
# `git pull --rebase` asks); what lies before it and not on the
# remote-tracking branch any more, the remote no longer has. 0 when the
# reflog does not reach back that far.
rewritten() {
  local tracking="refs/remotes/${REMOTE}/${BRANCH}" fork
  fork="$(git -C "$VAULT" merge-base --fork-point "$tracking" "refs/heads/${BRANCH}" 2>/dev/null)" || {
    echo 0
    return 0
  }
  git -C "$VAULT" rev-list --count "${tracking}..${fork}" 2>/dev/null || echo 0
}

# Fetched first, then pushed. The remote is asked what it holds now: after a
# human took a commit off it with a force-push, the branch is ahead of the
# remote again, git would take the push as a fast-forward, and this run would
# put back what was removed. That is refused and reported instead, as vigil's
# own push refuses it — the fetch is forced (`+`), like the server's, so the
# remote-tracking branch says what the remote holds, and its reflog what it
# held before.
#
# core.hooksPath=/dev/null: a hook in the vault is code whoever can write the
# vault chose, and none is run. push.gpgSign=false: the service user has no
# key, and a signature asked for by the ambient configuration would fail the
# push. The ssh options are the ones Vigil.Git gives the server's own fetch
# and push, so a remote that stalls is noticed by ssh first; `timeout` bounds
# whatever ssh does not, each of the two on its own, and the unit's
# TimeoutStartSec= bounds the whole run.
#
# The subshell's exit code says which step ended it: 0 pushed (or the lock was
# taken), 110/111 the fetch timed out / failed, 112 the push was refused,
# anything else the push's own.
REWRITTEN=0
PUSH_RC=0
(
  flock -n 9 || exit 0
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
  rc=0
  timeout --kill-after=10 "$PUSH_TIMEOUT" \
    git -c core.hooksPath=/dev/null -C "$VAULT" fetch --quiet "$REMOTE" \
    "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}" || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    exit 110
  elif [ "$rc" -ne 0 ]; then
    exit 111
  fi
  count="$(rewritten)"
  if [ "$count" != "0" ]; then
    echo "$count" >"${LOCK_DIR}/rewritten"
    exit 112
  fi
  timeout --kill-after=10 "$PUSH_TIMEOUT" \
    git -c core.hooksPath=/dev/null -c push.gpgSign=false -C "$VAULT" push --quiet "$REMOTE" "$BRANCH"
) 9>"$LOCK" || PUSH_RC=$?

FAILED=0
case "$PUSH_RC" in
  0) ;;
  110)
    err "git fetch ${REMOTE} ${BRANCH} did not finish within ${PUSH_TIMEOUT}s and was stopped; nothing was pushed."
    FAILED=1
    ;;
  111)
    err "git fetch ${REMOTE} ${BRANCH} failed; nothing was pushed."
    FAILED=1
    ;;
  112)
    REWRITTEN="$(cat "${LOCK_DIR}/rewritten" 2>/dev/null || echo "?")"
    rm -f "${LOCK_DIR}/rewritten"
    err "The remote's history was rewritten: ${REWRITTEN} commit(s) this vault holds were taken off ${REMOTE}/${BRANCH} by a force-push, and pushing would put them back. Not pushed; decide by hand whether they go back (git -C ${VAULT} log ${REMOTE}/${BRANCH}..${BRANCH})."
    FAILED=1
    ;;
  124 | 137)
    err "git push ${REMOTE} ${BRANCH} did not finish within ${PUSH_TIMEOUT}s and was stopped."
    FAILED=1
    ;;
  *)
    err "git push ${REMOTE} ${BRANCH} failed (exit ${PUSH_RC})."
    FAILED=1
    ;;
esac

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
