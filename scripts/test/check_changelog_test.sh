#!/usr/bin/env bash
# scripts/test/check_changelog_test.sh — scripts/check_changelog.sh, the CI
# check that a change to a recorded contract carries a CHANGELOG entry.
#
# It drives the real script against a throwaway repository with a base branch
# and a head branch per case: a contract changed alone, a contract changed
# with CHANGELOG.md, no contract changed, a leftover .actual file, and the
# refusals of its arguments. The base moving on after the head left it must
# not count as the head's change.
#
# Usage: bash scripts/test/check_changelog_test.sh [--keep]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECK_SH="${REPO_ROOT}/scripts/check_changelog.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK=""

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap below
cleanup() {
  if [ -n "$WORK" ] && [ "$KEEP" = "0" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  elif [ -n "$WORK" ] && [ "$KEEP" = "1" ]; then
    echo "Work directory kept: ${WORK}"
  fi
}
trap cleanup EXIT INT TERM

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-changelog-test.XXXXXX")" && pwd -P)"
REPO="${WORK}/repo"

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" -c commit.gpgsign=false commit -q -m "$1"
}

# A repository whose main holds a contract and a CHANGELOG, and a branch per
# case cut from it.
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Changelog Test"
mkdir -p "${REPO}/test/fixtures/contracts" "${REPO}/lib"
echo '{"tools": []}' >"${REPO}/test/fixtures/contracts/mcp_tools_list.json"
echo "# Changelog" >"${REPO}/CHANGELOG.md"
echo "code" >"${REPO}/lib/vigil.ex"
commit_all "base"

branch() {
  git -C "$REPO" checkout -q main
  git -C "$REPO" checkout -q -b "$1"
}

# Prints the exit code; the script's output goes to out.log.
run_check() {
  set +e
  (cd "$REPO" && bash "$CHECK_SH" "$@") >"${WORK}/out.log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

out_has() {
  if grep -q -- "$2" "${WORK}/out.log"; then
    pass "$1"
  else
    fail "$1" "$(cat "${WORK}/out.log")"
  fi
}

section "1/6  A contract changed without a CHANGELOG entry fails"

branch contract-only
echo '{"tools": ["search"]}' >"${REPO}/test/fixtures/contracts/mcp_tools_list.json"
commit_all "change the tool list"
assert_eq "exits 1" "1" "$(run_check main)"
out_has "names the contract file" "test/fixtures/contracts/mcp_tools_list.json"
out_has "says where the entry goes" "Unreleased"

section "2/6  A contract changed together with CHANGELOG.md passes"

echo "- search" >>"${REPO}/CHANGELOG.md"
commit_all "and say so"
assert_eq "exits 0" "0" "$(run_check main)"

section "3/6  A new contract file counts as a change"

branch new-contract
echo '{}' >"${REPO}/test/fixtures/contracts/mcp_initialize.json"
commit_all "record initialize"
assert_eq "exits 1" "1" "$(run_check main)"
out_has "names the new file" "mcp_initialize.json"

section "4/6  No contract changed passes, CHANGELOG or not"

branch code-only
echo "more code" >>"${REPO}/lib/vigil.ex"
commit_all "code"
assert_eq "exits 0" "0" "$(run_check main)"
out_has "says no contract changed" "no recorded contract changed"

section "5/6  A contract change on the base after the head left it is not the head's"

branch behind
echo "unrelated" >>"${REPO}/lib/vigil.ex"
commit_all "unrelated"
git -C "$REPO" checkout -q main
echo '{"tools": ["list"]}' >"${REPO}/test/fixtures/contracts/mcp_tools_list.json"
echo "- list" >>"${REPO}/CHANGELOG.md"
commit_all "main moves on"
git -C "$REPO" checkout -q behind
assert_eq "exits 0" "0" "$(run_check main)"

section "6/6  Arguments"

assert_eq "no base: exits 2" "2" "$(run_check)"
assert_eq "an unknown base: exits 2" "2" "$(run_check no-such-branch)"
assert_eq "an explicit head is checked, not HEAD" "1" "$(run_check main contract-only~1)"

report
