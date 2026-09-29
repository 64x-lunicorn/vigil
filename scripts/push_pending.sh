#!/usr/bin/env bash
# scripts/push_pending.sh — pushes the vault's commits when any are waiting.
#
# The push safety net (deploy/vigil-push-safety-net.cron) runs this. vigil
# pushes on every write; when that push fails (GitHub briefly unreachable,
# say) the write still succeeds, answers `pushed: false`, and the commit waits
# locally for the next push. This is that next push if no write comes along to
# make it.
#
# Pushes only when commits are pending, and takes a lock so two runs never
# overlap. The lock is this job's alone: vigil's own push does not take it.
# Prints nothing when there is nothing to push; a failed push prints git's
# answer and exits non-zero.
#
# Runs as root: the remote and the branch are read from the env file
# (vault_git_remote, vault_git_branch in lib.sh), which only root can read,
# and the push runs as the service user.
#
# Usage: sudo ./scripts/push_pending.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# A job that runs every 15 minutes has no run summary to give, and the journal
# would otherwise get one per run.
trap - EXIT

# Not /tmp: root opening a file there that another user owns is refused under
# fs.protected_regular, and the lock the old cron line took is one.
LOCK="${VIGIL_PUSH_LOCK:-/run/lock/vigil-push.lock}"

# With VIGIL_PUSH_TEST_STUBS=1 the service account is the caller, so
# scripts/test/push_pending_test.sh can run this against a throwaway vault
# without root. Refused as root, like update.sh's seam.
if [ "${VIGIL_PUSH_TEST_STUBS:-0}" = "1" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    err "VIGIL_PUSH_TEST_STUBS=1 refused: the test seam must never be live as root."
    exit 2
  fi
  as_vigil() { "$@"; }
else
  require_root "$@"
fi

REMOTE="$(vault_git_remote)"
BRANCH="$(vault_git_branch "$VAULT")"

PENDING="$(as_vigil git -C "$VAULT" rev-list --count "${REMOTE}/${BRANCH}..${BRANCH}")"
[ "$PENDING" = "0" ] && exit 0

(
  flock -n 9 || exit 0
  as_vigil git -C "$VAULT" push --quiet "$REMOTE" "$BRANCH"
) 9>"$LOCK"
