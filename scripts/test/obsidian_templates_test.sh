#!/usr/bin/env bash
# scripts/test/obsidian_templates_test.sh — how init_vault.sh installs the
# Obsidian templates.
#
# A new vault gets scripts/templates/obsidian/ as it is: `_templates/` with the
# Templater templates and their user script, and `Dashboard.md` at the root.
# A vault that already has one of those files keeps its own, and a second run
# adds only what is missing. Whether the installed vault gives the doctor
# anything to warn about is test/vigil/obsidian_templates_test.exs's to check.
#
# Everything happens in a temp directory. No root, no network.
#
# Usage: bash scripts/test/obsidian_templates_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATES="${REPO_ROOT}/scripts/templates/obsidian"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-obsidian-templates-test.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT INT TERM

VAULT="${WORK}/vault"
INSTALLED=(
  Dashboard.md
  _templates/_scripts/vigil_title.js
  _templates/decision.md
  _templates/event.md
  _templates/reference.md
)

# init_vault.sh commits; the identity and the signing setting come from the
# environment so no git config is touched.
init_vault() {
  GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1="obsidian templates test" \
    GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2="test@localhost" \
    bash "${REPO_ROOT}/scripts/init_vault.sh" "$VAULT" >/dev/null 2>&1
}

## ── 1. A new vault ───────────────────────────────────────────────────────

section "1/3  A new vault gets every template, committed"

init_vault
assert_eq "the installed files are the shipped ones" \
  "$(printf '%s\n' "${INSTALLED[@]}")" \
  "$(cd "$TEMPLATES" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
for file in "${INSTALLED[@]}"; do
  if cmp -s "${TEMPLATES}/${file}" "${VAULT}/${file}"; then
    pass "${file} is the template"
  else
    fail "${file} is the template"
  fi
  assert_eq "${file} is committed" "$file" "$(git -C "$VAULT" ls-files -- "$file")"
done
assert_eq "nothing is left uncommitted" "" "$(git -C "$VAULT" status --porcelain)"

## ── 2. A second run ──────────────────────────────────────────────────────

section "2/3  A second run changes nothing"

head_before="$(git -C "$VAULT" rev-parse HEAD)"
init_vault
assert_eq "no commit is made" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)"
assert_eq "nothing is changed" "" "$(git -C "$VAULT" status --porcelain)"

## ── 3. A vault with its own ──────────────────────────────────────────────

section "3/3  The owner's files are kept, a missing one is added"

echo "translated by the owner" >>"${VAULT}/_templates/event.md"
echo "the owner's dashboard" >"${VAULT}/Dashboard.md"
git -C "$VAULT" rm --quiet _templates/reference.md
git -C "$VAULT" -c commit.gpgsign=false -c user.name=owner -c user.email=owner@localhost \
  commit --quiet -am "make the templates my own"
own_event="$(cat "${VAULT}/_templates/event.md")"

init_vault
assert_eq "the owner's event template is untouched" "$own_event" \
  "$(cat "${VAULT}/_templates/event.md")"
assert_eq "the owner's dashboard is untouched" "the owner's dashboard" \
  "$(cat "${VAULT}/Dashboard.md")"
if cmp -s "${TEMPLATES}/_templates/reference.md" "${VAULT}/_templates/reference.md"; then
  pass "the removed reference template is installed again"
else
  fail "the removed reference template is installed again"
fi
assert_eq "and committed" "_templates/reference.md" \
  "$(git -C "$VAULT" show --name-only --format= HEAD)"

section "Its options"

# --help used to be taken for the vault directory, and a vault was created
# under that name.
mkdir -p "${WORK}/options"
set +e
(cd "${WORK}/options" && bash "${REPO_ROOT}/scripts/init_vault.sh" --help >"${WORK}/help.txt" 2>&1)
RC=$?
set -e
assert_eq "--help exits 0" "0" "$RC"
if grep -q "Usage\|init_vault.sh \[<vault dir>\]" "${WORK}/help.txt"; then
  pass "--help prints the usage"
else
  fail "--help prints the usage" "$(head -3 "${WORK}/help.txt")"
fi
set +e
(cd "${WORK}/options" && bash "${REPO_ROOT}/scripts/init_vault.sh" --vault x >/dev/null 2>&1)
RC=$?
set -e
assert_eq "an unknown option exits 2" "2" "$RC"
assert_eq "neither created anything" "" "$(ls -A "${WORK}/options")"

report
