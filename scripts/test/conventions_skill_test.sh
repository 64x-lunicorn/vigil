#!/usr/bin/env bash
# scripts/test/conventions_skill_test.sh — how init.sh installs the
# conventions skill.
#
# The server refuses to write `vigil-vault-conventions` through MCP
# (docs/design.md, "skills/ — one repository, two systems"), so init.sh puts
# it into the vault the way a hand edit arrives: as a commit, pushed to the
# vault's remote (scripts/lib.sh: install_conventions_skill). This checks the
# commit, the push, that a vault's own skill is kept, and what a failed push
# is reported as — against real repositories, with the service account a
# stand-in.
#
# Everything happens in a temp directory. No root, no network.
#
# Usage: bash scripts/test/conventions_skill_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${REPO_ROOT}/scripts/templates/vigil-vault-conventions.md"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-conventions-skill-test.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT INT TERM

UPSTREAM="${WORK}/upstream.git"
VAULT="${WORK}/vault"

git init --quiet --bare -b main "$UPSTREAM"
git init --quiet -b main "$VAULT"
git -C "$VAULT" config user.name "conventions skill test"
git -C "$VAULT" config user.email "test@localhost"
git -C "$VAULT" config commit.gpgsign false
echo "# note" >"${VAULT}/note.md"
git -C "$VAULT" add -A
git -C "$VAULT" commit --quiet -m "note"
git -C "$VAULT" remote add github "$UPSTREAM"
git -C "$VAULT" push --quiet -u github main

# install_conventions_skill as a script would call it, in a fresh shell.
install() {
  bash -c '
    source "$1/scripts/lib.sh"
    trap - EXIT
    as_vigil() { "$@"; }
    install_conventions_skill "$2" "$3" "$4" main
  ' _ "$REPO_ROOT" "$VAULT" "$TEMPLATE" "$1" 2>/dev/null
}

## ── 1. A vault without one ───────────────────────────────────────────────

section "1/4  A vault without the skill gets the template, committed and pushed"

assert_eq "reports it pushed" "pushed" "$(install github)"
if cmp -s "$TEMPLATE" "${VAULT}/skills/vigil-vault-conventions.md"; then
  pass "the file is the template"
else
  fail "the file is the template"
fi
assert_eq "the commit holds the skill and nothing else" "skills/vigil-vault-conventions.md" \
  "$(git -C "$VAULT" show --name-only --format= HEAD)"
assert_eq "the commit is on the remote" \
  "$(git -C "$VAULT" rev-parse HEAD)" "$(git --git-dir="$UPSTREAM" rev-parse main)"
assert_eq "nothing is left uncommitted" "" "$(git -C "$VAULT" status --porcelain)"

## ── 2. A vault with its own ──────────────────────────────────────────────

section "2/4  A vault's own skill is kept as it is"

echo "tuned by the owner" >>"${VAULT}/skills/vigil-vault-conventions.md"
git -C "$VAULT" commit --quiet -am "tune the conventions"
own="$(cat "${VAULT}/skills/vigil-vault-conventions.md")"
head_before="$(git -C "$VAULT" rev-parse HEAD)"

assert_eq "reports it kept" "kept" "$(install github)"
assert_eq "the file is untouched" "$own" "$(cat "${VAULT}/skills/vigil-vault-conventions.md")"
assert_eq "no commit is made" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)"

## ── 3. A push that fails ─────────────────────────────────────────────────

section "3/4  A failed push leaves the commit and says so"

git -C "$VAULT" rm --quiet skills/vigil-vault-conventions.md
git -C "$VAULT" commit --quiet -m "remove the conventions"
assert_eq "reports it only committed" "committed" "$(install nowhere)"
assert_eq "the commit is made all the same" "skills/vigil-vault-conventions.md" \
  "$(git -C "$VAULT" show --name-only --format= HEAD)"

## ── 4. A commit that fails ───────────────────────────────────────────────

section "4/4  A vault it cannot write to is reported, not taken for a commit"

git -C "$VAULT" rm --quiet skills/vigil-vault-conventions.md
git -C "$VAULT" commit --quiet -m "remove the conventions again"
head_before="$(git -C "$VAULT" rev-parse HEAD)"
# git removed the emptied directory with the file; a read-only one stands in.
mkdir -p "${VAULT}/skills"
chmod 0555 "${VAULT}/skills"
assert_eq "reports it failed" "failed" "$(install github)"
chmod 0755 "${VAULT}/skills"
assert_eq "no commit is made" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)"

report
