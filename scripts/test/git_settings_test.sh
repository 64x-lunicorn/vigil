#!/usr/bin/env bash
# scripts/test/git_settings_test.sh — the vault's remote and branch, as the
# scripts read them.
#
# VIGIL_GIT_REMOTE and VIGIL_GIT_BRANCH are stated once, in the env file, and
# every script reads them from there (scripts/lib.sh: vault_git_remote,
# vault_git_branch). Before, `github` and `main` were written into init.sh,
# update.sh, verify() and the push safety net, and a vault on `master` failed
# every one of them with a git error. This checks the reading, the one script
# that does nothing but act on the two (push_pending.sh, against a real
# repository on `master`), that no script or deploy file names either
# value again, and that a vault that is a git worktree — `.git` a file, not a
# directory — is a clone to the scripts as it is to the server.
#
# Everything happens in a temp directory. No root, no network.
#
# Usage: bash scripts/test/git_settings_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-git-settings-test.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT INT TERM

export VIGIL_STATE_DIR="${WORK}/state"
export VIGIL_VAULT_DIR="${WORK}/state/vault"
export VIGIL_ENV_FILE="${WORK}/env"
# The unit's RuntimeDirectory=, where push_pending.sh takes its lock.
export RUNTIME_DIRECTORY="${WORK}/run"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
UPSTREAM="${WORK}/upstream.git"
mkdir -p "$VIGIL_STATE_DIR"

# flock is util-linux: present on the vault host and the CI runner, absent on
# macOS. A stand-in that always gets the lock keeps the test runnable there.
if ! command -v flock >/dev/null 2>&1; then
  mkdir -p "${WORK}/bin"
  printf '#!/bin/sh\nexit 0\n' >"${WORK}/bin/flock"
  chmod +x "${WORK}/bin/flock"
  export PATH="${WORK}/bin:${PATH}"
fi

# A vault on `master`, tracking `upstream/master` — neither of them a default.
git init --quiet --bare -b master "$UPSTREAM"
git init --quiet -b master "$VIGIL_VAULT_DIR"
git -C "$VIGIL_VAULT_DIR" config user.name "git settings test"
git -C "$VIGIL_VAULT_DIR" config user.email "test@localhost"
git -C "$VIGIL_VAULT_DIR" config commit.gpgsign false
echo "# note" >"${VIGIL_VAULT_DIR}/note.md"
git -C "$VIGIL_VAULT_DIR" add -A
git -C "$VIGIL_VAULT_DIR" commit --quiet -m "note"
git -C "$VIGIL_VAULT_DIR" remote add upstream "$UPSTREAM"
git -C "$VIGIL_VAULT_DIR" push --quiet -u upstream master

env_file() { printf '%s\n' "$@" >"$VIGIL_ENV_FILE"; }

# What lib.sh answers, asked in a fresh shell the way a script would ask it.
# as_vigil is the caller here: the service account is a stand-in.
ask() {
  bash -c '
    source "$1/scripts/lib.sh"
    trap - EXIT
    as_vigil() { "$@"; }
    "$2" "$VAULT"
  ' _ "$REPO_ROOT" "$1" 2>/dev/null
}

## ── 1. Reading the two settings ──────────────────────────────────────────

section "1/4  lib.sh reads both from the env file"

env_file "VIGIL_GIT_REMOTE=upstream" "VIGIL_GIT_BRANCH=master"
assert_eq "the remote is the env file's" "upstream" "$(ask vault_git_remote)"
assert_eq "the branch is the env file's" "master" "$(ask vault_git_branch)"

env_file 'VIGIL_GIT_REMOTE="upstream"' 'VIGIL_GIT_BRANCH="release"'
assert_eq "a quoted value is read without its quotes" "upstream" "$(ask vault_git_remote)"
assert_eq "a branch that is set is used as set" "release" "$(ask vault_git_branch)"

env_file "VIGIL_GIT_REMOTE=upstream"
assert_eq "unset, the branch is the checked-out one tracking the remote" "master" \
  "$(ask vault_git_branch)"

env_file "VIGIL_PORT=4000"
assert_eq "unset, the remote is the server's default" "github" "$(ask vault_git_remote)"
assert_eq "unset, a branch tracking another remote falls back to main" "main" \
  "$(ask vault_git_branch)"

rm -f "$VIGIL_ENV_FILE"
assert_eq "with no env file at all, the remote is the default" "github" "$(ask vault_git_remote)"

## ── 2. push_pending.sh on master ─────────────────────────────────────────

section "2/4  push_pending.sh pushes the configured branch to the configured remote"

push_pending() {
  bash "${REPO_ROOT}/scripts/push_pending.sh" >"${WORK}/out.txt" 2>&1
}

env_file "VIGIL_GIT_REMOTE=upstream" "VIGIL_GIT_BRANCH=master"
before="$(git --git-dir="$UPSTREAM" rev-parse master)"
if push_pending; then
  pass "nothing pending: exits 0"
else
  fail "nothing pending: exits 0" "$(cat "${WORK}/out.txt")"
fi
assert_eq "nothing pending: prints nothing" "" "$(cat "${WORK}/out.txt")"
assert_eq "nothing pending: the remote is untouched" "$before" "$(git --git-dir="$UPSTREAM" rev-parse master)"

echo "# later" >"${VIGIL_VAULT_DIR}/later.md"
git -C "$VIGIL_VAULT_DIR" add -A
git -C "$VIGIL_VAULT_DIR" commit --quiet -m "later"
if push_pending; then
  pass "a pending commit: exits 0"
else
  fail "a pending commit: exits 0" "$(cat "${WORK}/out.txt")"
fi
assert_eq "a pending commit is pushed to upstream/master" \
  "$(git -C "$VIGIL_VAULT_DIR" rev-parse HEAD)" "$(git --git-dir="$UPSTREAM" rev-parse master)"

echo "# third" >"${VIGIL_VAULT_DIR}/third.md"
git -C "$VIGIL_VAULT_DIR" add -A
git -C "$VIGIL_VAULT_DIR" commit --quiet -m "third"
env_file "VIGIL_GIT_REMOTE=upstream"
push_pending || true
assert_eq "with the branch unset, the checked-out branch is pushed" \
  "$(git -C "$VIGIL_VAULT_DIR" rev-parse HEAD)" "$(git --git-dir="$UPSTREAM" rev-parse master)"

env_file "VIGIL_GIT_REMOTE=nowhere" "VIGIL_GIT_BRANCH=master"
if push_pending; then
  fail "a remote the vault does not have fails the run"
else
  pass "a remote the vault does not have fails the run"
fi

## ── 3. Nothing restates them ─────────────────────────────────────────────

section "3/4  No script or deploy file names the remote or the branch"

# A git command, a ref or an env line naming `github` or `main` as the vault's
# remote or branch. github.com, the host, is not a remote name. Not matched,
# because each is the one statement of what it states: the two defaults in
# lib.sh, which are assignments rather than git commands; the example env
# file, which documents what init.sh writes; and update.sh's `origin/main`,
# which is the code repository's branch, not the vault's.
hardcoded="$(
  cd "$REPO_ROOT" &&
    grep -nE '(git[^|;&#]*[[:space:]/"'"'"'](github|main)([[:space:]"'"'"']|$))|((github|origin)?/main\.\.)|((github|origin)/main)|(VIGIL_GIT_(REMOTE|BRANCH)="?(github|main))|(-qx (github|main))' \
      scripts/*.sh deploy/* 2>/dev/null |
    grep -v 'github\.com' |
    grep -v '^deploy/vigil\.env\.example:' |
    grep -vE '^scripts/update\.sh:[0-9]+:(TARGET_REF=|  --to )' || true
)"
assert_eq "no hard-coded remote or branch in scripts/ or deploy/" "" "$hardcoded"

## ── 4. A worktree is a clone ─────────────────────────────────────────────

section "4/4  A vault that is a git worktree is a clone to every script"

# The server takes a vault whose `.git` is a file (Vigil.Git.clone?/1): a
# worktree. init_vault.sh used to find no `.git` directory there and run `git
# init` over it; init.sh to read no branch from it and to clone into it.
WORKTREE="${WORK}/worktree-vault"
git -C "$VIGIL_VAULT_DIR" worktree add --quiet -b drafts "$WORKTREE"
output="$(GIT_CONFIG_COUNT=3 \
  GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1="git settings test" \
  GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2="test@localhost" \
  VIGIL_GIT_BRANCH=elsewhere bash "${REPO_ROOT}/scripts/init_vault.sh" "$WORKTREE" 2>&1)"
case "$output" in
  *"initialized git repository"*) fail "init_vault.sh does not initialise a worktree again" "$output" ;;
  *) pass "init_vault.sh does not initialise a worktree again" ;;
esac
assert_eq "the worktree stays on its branch" "drafts" \
  "$(git -C "$WORKTREE" symbolic-ref --short HEAD)"

# And no script asks for a `.git` directory where a clone is meant.
directory_tests="$(cd "$REPO_ROOT" && grep -nE '\-d [^]]*\.git"?[[:space:]]*\]' scripts/*.sh || true)"
assert_eq "no script tests for a .git directory rather than a .git" "" "$directory_tests"

report
