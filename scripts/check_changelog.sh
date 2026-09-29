#!/usr/bin/env bash
# scripts/check_changelog.sh — a change to a published interface carries a
# CHANGELOG entry.
#
# The files under test/fixtures/contracts/ are the recorded contracts: the MCP
# tool list, the initialize result, the shape of every tool's result and the
# two OAuth metadata documents (test/support/contract_snapshot.ex). Changing
# one changes what connected clients are handed, and docs/compatibility.md
# says every such change is named in CHANGELOG.md, under "Unreleased". This
# holds a range of commits to that: when it touches a contract file and not
# CHANGELOG.md, it fails and names the files.
#
# CI runs it on a pull request against the base branch, and on a merge-group
# run against the queue's base. Locally:
#
#   bash scripts/check_changelog.sh <the branch the pull request targets>
#
# Usage: scripts/check_changelog.sh <base> [<head>]   (head defaults to HEAD)
# Exit codes: 0 fine, 1 a contract changed without an entry, 2 usage or an
#             unknown revision.

set -euo pipefail
IFS=$'\n\t'

CONTRACTS_DIR="test/fixtures/contracts/"
CHANGELOG="CHANGELOG.md"

if [ $# -lt 1 ] || [ $# -gt 2 ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0 <base> [<head>]" >&2
  exit 2
fi
BASE="$1"
HEAD="${2:-HEAD}"

for rev in "$BASE" "$HEAD"; do
  if ! git rev-parse --verify --quiet --end-of-options "${rev}^{commit}" >/dev/null; then
    echo "check_changelog: unknown revision: ${rev}" >&2
    exit 2
  fi
done

# Three dots: what the head changed since it left the base, not what the base
# gained in the meantime.
changed="$(git diff --name-only "${BASE}...${HEAD}")"

contracts="$(printf '%s\n' "$changed" | grep "^${CONTRACTS_DIR}" | grep -v '\.actual$' || true)"
if [ -z "$contracts" ]; then
  echo "check_changelog: no recorded contract changed."
  exit 0
fi

if printf '%s\n' "$changed" | grep -qx "$CHANGELOG"; then
  echo "check_changelog: a recorded contract changed, and ${CHANGELOG} with it:"
  printf '%s\n' "$contracts" | sed 's/^/  /'
  exit 0
fi

echo "check_changelog: a recorded contract changed without an entry in ${CHANGELOG}:" >&2
printf '%s\n' "$contracts" | sed 's/^/  /' >&2
echo "Every connected client sees this change. Name it under \"## [Unreleased]\" in ${CHANGELOG}, and read docs/compatibility.md for whether it is a major, minor or patch change." >&2
exit 1
