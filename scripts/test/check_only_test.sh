#!/usr/bin/env bash
# scripts/test/check_only_test.sh — regression test: init.sh --check-only
# must be strictly read-only.
#
# Root cause it guards against: init.sh called
# `run_vault_adoption "$CHECK_VAULT" "pruefen"` (German for "check"), but every
# fix_vault_* function gates on the literal string "check". "pruefen" !=
# "check", so --check-only silently fell through to apply-mode behavior and
# could modify/commit the vault it was supposed to only inspect.
#
# Builds a throwaway git-backed fixture vault with one instance of each of
# the four automatically-fixable finding classes (missing .gitignore entries,
# one of them for a .trash/ already committed, wrong local git identity, a
# missing _domains.yml entry, wrong permissions),
# runs `init.sh --check-only --vault <fixture>` against it, and asserts the
# fixture is byte-for-byte, commit-for-commit, and permissions-for-permissions
# unchanged afterwards.
#
# init.sh normally requires root, a "vigil" system user, and a real
# /opt/vigil/repo checkout. VIGIL_INIT_TEST_STUBS=1 (see init.sh) replaces
# those with no-ops / the caller's own checkout for this run only; production
# behavior (that variable unset) is untouched.
#
# Usage: bash scripts/test/check_only_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INIT_SH="${REPO_ROOT}/scripts/init.sh"

PASS=0
FAIL=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   - ${description}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL - ${description}"
    echo "         expected: ${expected}"
    echo "         actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  ok   - ${description}"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL - ${description} (expected to find: ${needle})"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

VAULT="$(mktemp -d)"
trap 'rm -rf "$VAULT"' EXIT

# Wrong permissions on purpose — init.sh's fix wants owner vigil:vigil, mode
# 0750. fix_vault_permissions falls back to "?:?"/"?" wherever `stat -c`
# isn't GNU stat (e.g. macOS), which still mismatches "vigil:vigil"/"750", so
# the pending fix fires on every host this test runs on either way.
chmod 0700 "$VAULT"

## ── Build a fixture vault with one of each fixable finding ─────────────────

mkdir -p "${VAULT}/bike" "${VAULT}/gear"

cat >"${VAULT}/bike/note.md" <<'EOF'
---
type: reference
---
# Note

Text.
EOF

# "gear" has no matching key in _domains.yml — findings_json flags it with
# "is unknown to the runtime", which fix_vault_domains_yml turns into a
# pending/applied fix.
cat >"${VAULT}/_domains.yml" <<'EOF'
bike: ""
EOF

cat >"${VAULT}/gear/note.md" <<'EOF'
---
type: reference
---
# Gear Note

Text.
EOF

# A note saved as Windows-1252 (0xE9 is "é" there, and no UTF-8 on its
# own): the server skips it, and the report names it with the fix.
printf -- '---\ntype: reference\n---\n# Caf\351\n\nText.\n' >"${VAULT}/bike/windows-note.md"

# Markdown files the layout ignores: one a level too deep (a warning, with
# its fix), a root page (information only), and one under a dot directory
# (outside the vault model, never listed). That one is committed below, the
# way Obsidian Git commits a deleted note, so .trash/ is tracked.
mkdir -p "${VAULT}/bike/deep" "${VAULT}/.trash"
printf -- '# Too Deep\n' >"${VAULT}/bike/deep/too-deep.md"
printf -- '# Dashboard\n' >"${VAULT}/Dashboard.md"
printf -- '# Old\n' >"${VAULT}/.trash/old.md"

# Missing .gitignore entry: no .gitignore at all yet.

# On `master`, with no upstream yet, and the env file naming a remote that is
# not a default either: the upstream fix has to say both, read from there.
git -C "$VAULT" init -q -b master
ENV_FILE_UNDER_TEST="$(mktemp)"
trap 'rm -rf "$VAULT" "$ENV_FILE_UNDER_TEST"' EXIT
echo "VIGIL_GIT_REMOTE=upstream" >"$ENV_FILE_UNDER_TEST"
# Wrong local git identity on purpose — init.sh's fix wants
# "vigil"/"vigil@$(hostname)".
git -C "$VAULT" config user.name "Not Vigil"
git -C "$VAULT" config user.email "notvigil@example.com"
git -C "$VAULT" config commit.gpgsign false
git -C "$VAULT" add -A
git -C "$VAULT" commit -q -m "fixture: initial vault"

BEFORE_HEAD="$(git -C "$VAULT" rev-parse HEAD)"
BEFORE_LOG="$(git -C "$VAULT" log --oneline)"
BEFORE_STATUS="$(git -C "$VAULT" status --porcelain)"
BEFORE_GITIGNORE="$([ -f "${VAULT}/.gitignore" ] && cat "${VAULT}/.gitignore" || echo "<absent>")"
BEFORE_DOMAINS_YML="$(cat "${VAULT}/_domains.yml")"
BEFORE_USER_NAME="$(git -C "$VAULT" config user.name)"
BEFORE_USER_EMAIL="$(git -C "$VAULT" config user.email)"
BEFORE_VAULT_LS="$(ls -ld "$VAULT")"
BEFORE_TRACKED_TRASH="$(git -C "$VAULT" ls-files -- .trash)"

## ── Run init.sh --check-only against it, with test stubs in place ─────────

set +e
OUTPUT="$(
  VIGIL_INIT_TEST_STUBS=1 \
    VIGIL_TEST_REPO_ROOT="$REPO_ROOT" \
    VIGIL_ENV_FILE="$ENV_FILE_UNDER_TEST" \
    bash "$INIT_SH" --check-only --vault "$VAULT" 2>&1
)"
EXIT_CODE=$?
set -e

echo "$OUTPUT"
echo

## ── Assertions ─────────────────────────────────────────────────────────────

echo "Assertions:"

AFTER_HEAD="$(git -C "$VAULT" rev-parse HEAD)"
AFTER_LOG="$(git -C "$VAULT" log --oneline)"
AFTER_STATUS="$(git -C "$VAULT" status --porcelain)"
AFTER_GITIGNORE="$([ -f "${VAULT}/.gitignore" ] && cat "${VAULT}/.gitignore" || echo "<absent>")"
AFTER_DOMAINS_YML="$(cat "${VAULT}/_domains.yml")"
AFTER_USER_NAME="$(git -C "$VAULT" config user.name)"
AFTER_USER_EMAIL="$(git -C "$VAULT" config user.email)"
AFTER_VAULT_LS="$(ls -ld "$VAULT")"
AFTER_TRACKED_TRASH="$(git -C "$VAULT" ls-files -- .trash)"

assert_eq "no new commit was created" "$BEFORE_HEAD" "$AFTER_HEAD"
assert_eq "commit log is unchanged" "$BEFORE_LOG" "$AFTER_LOG"
assert_eq "working tree has no staged/unstaged changes" "$BEFORE_STATUS" "$AFTER_STATUS"
assert_eq ".gitignore was not modified" "$BEFORE_GITIGNORE" "$AFTER_GITIGNORE"
assert_eq "_domains.yml was not modified" "$BEFORE_DOMAINS_YML" "$AFTER_DOMAINS_YML"
assert_eq "local git user.name was not changed" "$BEFORE_USER_NAME" "$AFTER_USER_NAME"
assert_eq "local git user.email was not changed" "$BEFORE_USER_EMAIL" "$AFTER_USER_EMAIL"
assert_eq "vault directory ownership/permissions were not touched" "$BEFORE_VAULT_LS" "$AFTER_VAULT_LS"
assert_eq "the tracked .trash/ is still in the index" "$BEFORE_TRACKED_TRASH" "$AFTER_TRACKED_TRASH"
assert_eq "exit code reports findings (3) rather than an error" "3" "$EXIT_CODE"

assert_contains "names the note that is not UTF-8, with its fix" "$OUTPUT" \
  "bike/windows-note.md: not valid UTF-8, so the server skips this note"
assert_contains "names the note at the wrong depth as a finding" "$OUTPUT" \
  "! bike/deep/too-deep.md: not at note depth"
assert_contains "names the root page as information only" "$OUTPUT" \
  "i Dashboard.md: at the vault root, in no domain, so the server ignores this file"
assert_contains "counts the two warnings, not the root page" "$OUTPUT" "Findings (2):"
case "$OUTPUT" in
  *".trash/old.md"*) assert_eq "does not list files under dot directories" "absent" "listed" ;;
  *) assert_eq "does not list files under dot directories" "absent" "absent" ;;
esac
assert_contains "reports the .gitignore fix as pending, not applied" "$OUTPUT" \
  "gitignore: add .obsidian/"
assert_contains "reports the .trash/ entry and its untracking as pending, not applied" "$OUTPUT" \
  "gitignore: add .trash/, and remove the already-tracked .trash directory from the index"
assert_contains "reports the git identity fix as pending, not applied" "$OUTPUT" \
  "git config: set local user.name/user.email/commit.gpgsign"
assert_contains "reports the upstream fix for the vault's branch and the env file's remote" "$OUTPUT" \
  "upstream: point master at upstream/master"
assert_contains "reports the permissions fix as pending, not applied" "$OUTPUT" \
  "permissions: chown -R vigil:vigil, chmod 0750"
# fix_vault_domains_yml itself needs GNU grep -P (PCRE), same as production
# (Debian). BSD grep (macOS) can't run that extraction at all, so skip this
# one assertion there rather than report a false failure unrelated to
# --check-only's read-only guarantee, which the other assertions already
# cover.
if printf '' | grep -oP '' >/dev/null 2>&1; then
  assert_contains "reports the _domains.yml fix as pending, not applied" "$OUTPUT" \
    "_domains.yml: add entry 'gear:"
else
  echo "  skip - _domains.yml pending-fix message (host grep lacks GNU -P/PCRE support)"
fi
assert_contains "labels the run as --check-only" "$OUTPUT" "Vault adoption (--check-only)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS (${PASS} assertions)"
  exit 0
else
  echo "FAIL (${FAIL} of $((PASS + FAIL)) assertions failed)"
  exit 1
fi
