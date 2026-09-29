#!/usr/bin/env bash
# scripts/test/reproducible_release.sh — do two builds of one commit give the
# same tarball?
#
# Builds the production release of HEAD twice, each time from a fresh export
# of the commit into the same path with an empty _build, packages both with
# scripts/package_release.sh, and compares them. The same path matters: the
# release workflow always builds in the same checkout directory, and compiled
# modules record where their source was.
#
# They are not the same bytes yet, and this names why. One file differs in
# every pair of builds, for a reason outside the packaging:
#
#   lib/tz-*/ebin/Elixir.Tz.PeriodsProvider.beam  tz compiles its build time
#                                                 into the module (compiled_at/0)
#
# (`mix release` also writes a new random releases/COOKIE for each build, but
# the tarball leaves it out.) The test passes when the two trees differ in
# exactly that file and in nothing else, so a new source of difference fails
# it instead of hiding behind the known one. docs/ci-cd.md ("Reproducibility") says the same for
# someone comparing a published tarball with their own build.
#
# Takes a few minutes: it compiles the dependencies twice. Uses the
# repository's deps/ when present (no network), `mix deps.get` otherwise.
#
# Usage: bash scripts/test/reproducible_release.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-reproducible.XXXXXX")" && pwd -P)"

# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT INT TERM

TAR=tar
command -v gtar >/dev/null 2>&1 && TAR=gtar

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
SRC="${WORK}/src"

build() {
  local round="$1"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$SRC"
  if [ -d "${REPO_ROOT}/deps" ]; then
    cp -R "${REPO_ROOT}/deps" "${SRC}/deps"
  else
    (cd "$SRC" && MIX_ENV=prod mix deps.get --only prod >/dev/null)
  fi
  echo "  building round ${round} ..."
  (cd "$SRC" && MIX_ENV=prod mix release --overwrite --path "${WORK}/release" >"${WORK}/build-${round}.log" 2>&1)
  bash "${REPO_ROOT}/scripts/package_release.sh" "${WORK}/release" "${WORK}/dist-${round}" vigil >/dev/null
  mkdir -p "${WORK}/tree-${round}"
  "$TAR" -xzf "${WORK}/dist-${round}/vigil.tar.gz" -C "${WORK}/tree-${round}"
  rm -rf "${WORK}/release"
}

section "1/2  Two builds of HEAD"

build 1
build 2

first="$(sha "${WORK}/dist-1/vigil.tar.gz")"
second="$(sha "${WORK}/dist-2/vigil.tar.gz")"
echo "  round 1: ${first}"
echo "  round 2: ${second}"

section "2/2  They differ only where a build is known to differ"

differing="$(cd "$WORK" && diff -rq tree-1 tree-2 | sed -n 's|^Files tree-1/\(.*\) and tree-2/.* differ$|\1|p' | sed 's|^lib/tz-[^/]*/|lib/tz-*/|' | LC_ALL=C sort || true)"
others="$(cd "$WORK" && diff -rq tree-1 tree-2 | grep -v '^Files ' || true)"

assert_eq "no file exists in only one of the builds" "" "$others"
if [ "$first" = "$second" ]; then
  pass "the tarballs are the same bytes"
else
  assert_eq "the differing files are exactly the known one" \
    "lib/tz-*/ebin/Elixir.Tz.PeriodsProvider.beam" \
    "$differing"
fi

report
