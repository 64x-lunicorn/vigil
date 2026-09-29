#!/usr/bin/env bash
# scripts/test/obsidian_dirs_test.sh — how vault adoption keeps Obsidian's
# device-local directories, `.obsidian/` and `.trash/`, out of the vault's
# history.
#
# init.sh's adoption phase hands this to ignore_obsidian_dirs (scripts/lib.sh)
# and lists what it prints in its summary, under "Applied automatically" or,
# with --check-only, "Would be applied". The function is driven for real here
# against throwaway git vaults; as_vigil runs its command as the caller, since
# there is no "vigil" user. That --check-only leaves a vault untouched as a
# whole is scripts/test/check_only_test.sh's to check. A new vault gets its
# .gitignore from init_vault.sh instead, which must name the same directories.
#
# Usage: bash scripts/test/obsidian_dirs_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

# lib.sh's run summary describes a deployment script's run; this suite's
# verdict is `report`'s.
trap - EXIT

as_vigil() { "$@"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vigil-obsidian-dirs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# new_vault <name> — a committed vault with a note, an Obsidian settings file
# and a note in Obsidian's trash, all three tracked.
new_vault() {
  local vault="${WORK}/$1"
  mkdir -p "${vault}/bike" "${vault}/.obsidian" "${vault}/.trash"
  printf -- '---\ntype: reference\n---\n# Note\n' >"${vault}/bike/note.md"
  printf '{}\n' >"${vault}/.obsidian/app.json"
  printf -- '# Deleted\n' >"${vault}/.trash/deleted.md"
  git -C "$vault" init -q
  git -C "$vault" add -A
  git -C "$vault" -c user.name=test -c user.email=test@local -c commit.gpgsign=false \
    commit -q -m "fixture"
  echo "$vault"
}

## ── 1. A vault whose .gitignore names .obsidian/ but not .trash/ ─────────

section "1/5  .trash/ missing from .gitignore and tracked"

vault="$(new_vault ignores-obsidian)"
# No trailing newline: the entry must still land on a line of its own.
printf '.DS_Store\n.obsidian/' >"${vault}/.gitignore"
git -C "$vault" rm -r -q --cached -- .obsidian

output="$(ignore_obsidian_dirs "$vault" apply)"

assert_eq "reports that .trash/ was added and untracked, and nothing about .obsidian/" \
  "added .trash/ to .gitignore (and removed the already-tracked .trash directory from the index)" \
  "$output"
assert_eq "appends .trash/ to .gitignore on a line of its own" \
  "$(printf '.DS_Store\n.obsidian/\n.trash/')" "$(cat "${vault}/.gitignore")"
assert_eq "no longer tracks anything under .trash/" "" "$(git -C "$vault" ls-files -- .trash)"
assert_eq "stages the removal for the adoption commit" \
  "D  .trash/deleted.md" "$(git -C "$vault" status --porcelain -- .trash)"
if [ -f "${vault}/.trash/deleted.md" ]; then
  pass "leaves the deleted note on disk"
else
  fail "leaves the deleted note on disk"
fi
assert_eq "still tracks the notes" "bike/note.md" "$(git -C "$vault" ls-files -- bike)"

## ── 2. A vault with no .gitignore at all ─────────────────────────────────

section "2/5  no .gitignore"

vault="$(new_vault no-gitignore)"
output="$(ignore_obsidian_dirs "$vault" apply)"

assert_eq "reports both directories" \
  "$(printf '%s\n%s' \
    "added .obsidian/ to .gitignore (and removed the already-tracked .obsidian directory from the index)" \
    "added .trash/ to .gitignore (and removed the already-tracked .trash directory from the index)")" \
  "$output"
assert_eq "writes a .gitignore with both" "$(printf '.obsidian/\n.trash/')" "$(cat "${vault}/.gitignore")"
assert_eq "tracks neither any more" "" "$(git -C "$vault" ls-files -- .obsidian .trash)"

## ── 3. A second run ──────────────────────────────────────────────────────

section "3/5  a vault already in order"

git -C "$vault" add -- .gitignore
git -C "$vault" -c user.name=test -c user.email=test@local -c commit.gpgsign=false \
  commit -q -m "adoption"
before="$(cat "${vault}/.gitignore")"
output="$(ignore_obsidian_dirs "$vault" apply)"

assert_eq "reports nothing" "" "$output"
assert_eq "leaves .gitignore as it was" "$before" "$(cat "${vault}/.gitignore")"

## ── 4. check ─────────────────────────────────────────────────────────────

section "4/5  check mode"

vault="$(new_vault check)"
printf '.trash/\n' >"${vault}/.gitignore"
output="$(ignore_obsidian_dirs "$vault" check)"

assert_eq "reports what it would do for each directory" \
  "$(printf '%s\n%s' \
    "gitignore: add .obsidian/, and remove the already-tracked .obsidian directory from the index" \
    "gitignore: add .trash/, and remove the already-tracked .trash directory from the index")" \
  "$output"
assert_eq "changes no .gitignore" ".trash/" "$(cat "${vault}/.gitignore")"
assert_eq "untracks nothing" "?? .gitignore" "$(git -C "$vault" status --porcelain)"

## ── 5. A new vault ───────────────────────────────────────────────────────

section "5/5  init_vault.sh"

vault="${WORK}/new"
GIT_CONFIG_COUNT=3 \
  GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1="obsidian dirs test" \
  GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2="test@localhost" \
  bash "${REPO_ROOT}/scripts/init_vault.sh" "$vault" >/dev/null 2>&1
output="$(ignore_obsidian_dirs "$vault" check)"

assert_eq "its .gitignore already names every directory adoption would add" "" "$output"

report
