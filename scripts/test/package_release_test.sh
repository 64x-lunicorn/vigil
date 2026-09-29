#!/usr/bin/env bash
# scripts/test/package_release_test.sh — what scripts/package_release.sh puts
# into a GitHub Release, and that it puts it there the same way every time.
#
# A tarball that is only reproducible on the machine that built it is not
# reproducible. So the same release directory is packaged twice from two
# copies that differ in everything a packager's machine leaks into an archive
# (file times, the order files were created in, the umask, where the copy
# lives), and the two archives must be the same bytes.
#
# The release is a stand-in (a bin/vigil, a COOKIE, a beam file): what is
# under test is the packaging, not `mix release`. Whether two real builds of
# one commit agree is scripts/test/reproducible_release.sh's to check.
#
# Everything happens in a temp directory. No root, no network. Needs GNU tar,
# as the script does.
#
# Usage: bash scripts/test/package_release_test.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE="${REPO_ROOT}/scripts/package_release.sh"

# shellcheck source=scripts/test/harness.sh
source "${SCRIPT_DIR}/harness.sh"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vigil-package-test.XXXXXX")" && pwd -P)"

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

# 2026-01-01T00:00:00Z
EPOCH=1767225600
NAME="vigil-9.9.9-otp27.3.4-linux-x86_64"

# A release as `mix release` leaves it, in miniature. The files are created in
# the order given, so a second call with another order makes a directory whose
# listing order differs.
make_release() {
  local dir="$1"
  shift
  mkdir -p "${dir}/bin" "${dir}/releases" "${dir}/lib/vigil-9.9.9/ebin"
  for file in "$@"; do
    case "$file" in
      bin/vigil) printf '#!/bin/sh\necho vigil\n' >"${dir}/${file}" && chmod 0755 "${dir}/${file}" ;;
      releases/COOKIE) printf 'secret' >"${dir}/${file}" && chmod 0400 "${dir}/${file}" ;;
      *) printf '%s\n' "$file" >"${dir}/${file}" ;;
    esac
  done
}

package() {
  SOURCE_DATE_EPOCH="$EPOCH" bash "$PACKAGE" "$@" >/dev/null
}

printf '{"bomFormat":"CycloneDX"}\n' >"${WORK}/bom.json"

## ── 1. The same release gives the same bytes ─────────────────────────────

section "1/5  Two packagings of one release are the same bytes"

make_release "${WORK}/a/release" bin/vigil releases/COOKIE lib/vigil-9.9.9/ebin/vigil.app lib/vigil-9.9.9/ebin/Elixir.Vigil.beam
package "${WORK}/a/release" "${WORK}/a/dist" "$NAME" "${WORK}/bom.json"

(
  umask 0002
  make_release "${WORK}/b/elsewhere/release" lib/vigil-9.9.9/ebin/Elixir.Vigil.beam lib/vigil-9.9.9/ebin/vigil.app releases/COOKIE bin/vigil
)
touch -t 203001020304 "${WORK}/b/elsewhere/release/bin/vigil" "${WORK}/b/elsewhere/release/lib/vigil-9.9.9/ebin/vigil.app"
package "${WORK}/b/elsewhere/release" "${WORK}/b/dist" "$NAME" "${WORK}/bom.json"

assert_eq "the tarballs have the same sha256" \
  "$(sha "${WORK}/a/dist/${NAME}.tar.gz")" "$(sha "${WORK}/b/dist/${NAME}.tar.gz")"
assert_eq "the checksum files are the same" \
  "$(cat "${WORK}/a/dist/${NAME}-SHA256SUMS")" "$(cat "${WORK}/b/dist/${NAME}-SHA256SUMS")"

## ── 2. What is inside ────────────────────────────────────────────────────

section "2/5  The tarball carries the release and the notices"

TARBALL="${WORK}/a/dist/${NAME}.tar.gz"
assert_eq "entries are the release plus the notices, sorted by name" \
  "$(printf '%s\n' ./ ./LICENSE ./THIRD_PARTY_NOTICES.md ./bin/ ./bin/vigil ./lib/ ./lib/vigil-9.9.9/ ./lib/vigil-9.9.9/ebin/ ./lib/vigil-9.9.9/ebin/Elixir.Vigil.beam ./lib/vigil-9.9.9/ebin/vigil.app ./releases/ ./releases/COOKIE)" \
  "$("$TAR" -tzf "$TARBALL")"

mkdir -p "${WORK}/x"
"$TAR" -xzf "$TARBALL" -C "${WORK}/x"
if cmp -s "${REPO_ROOT}/LICENSE" "${WORK}/x/LICENSE"; then
  pass "LICENSE is the repository's"
else
  fail "LICENSE is the repository's"
fi
if cmp -s "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${WORK}/x/THIRD_PARTY_NOTICES.md"; then
  pass "THIRD_PARTY_NOTICES.md is the repository's"
else
  fail "THIRD_PARTY_NOTICES.md is the repository's"
fi
if [ ! -e "${WORK}/a/release/LICENSE" ]; then
  pass "the release directory itself is left as it was"
else
  fail "the release directory itself is left as it was"
fi

## ── 3. What a packager's machine could have leaked ──────────────────────

section "3/5  Owner, time and mode are the archive's, not the machine's"

listing="$(TZ=UTC "$TAR" --numeric-owner --full-time -tvzf "$TARBALL")"
assert_eq "every entry is owned by 0/0" \
  "0/0" "$(printf '%s\n' "$listing" | awk '{print $2}' | sort -u)"
assert_eq "every entry carries SOURCE_DATE_EPOCH" \
  "2026-01-01 00:00:00" "$(printf '%s\n' "$listing" | awk '{print $4" "$5}' | sort -u)"
assert_eq "releases/COOKIE keeps its 0400" \
  "-r--------" "$(printf '%s\n' "$listing" | awk '$6 == "./releases/COOKIE" {print $1}')"
assert_eq "bin/vigil stays executable, and a umask 0002 build leaves nothing group-writable" \
  "-rwxr-xr-x" "$(printf '%s\n' "$listing" | awk '$6 == "./bin/vigil" {print $1}')"
# RFC 1952: bytes 4-7 are MTIME, and FLG (byte 3) has FNAME at 0x08.
assert_eq "gzip records no time and no file name" \
  "00 00000000" "$(od -An -tx1 -j3 -N5 "$TARBALL" | tr -d ' \n' | sed 's/^\(..\)/\1 /')"

## ── 4. The other assets ─────────────────────────────────────────────────

section "4/5  Lock, SBOM and checksums"

if cmp -s "${REPO_ROOT}/mix.lock" "${WORK}/a/dist/${NAME}-mix.lock"; then
  pass "the lock file is the repository's"
else
  fail "the lock file is the repository's"
fi
if cmp -s "${WORK}/bom.json" "${WORK}/a/dist/${NAME}.cdx.json"; then
  pass "the SBOM is the one handed in"
else
  fail "the SBOM is the one handed in"
fi
assert_eq "SHA256SUMS names the tarball, the lock and the SBOM" \
  "$(printf '%s\n' "${NAME}.tar.gz" "${NAME}-mix.lock" "${NAME}.cdx.json")" \
  "$(awk '{print $2}' "${WORK}/a/dist/${NAME}-SHA256SUMS")"
expected="$(sha "$TARBALL")"
assert_eq "SHA256SUMS holds the tarball's checksum" \
  "$expected" "$(awk -v n="${NAME}.tar.gz" '$2 == n {print $1}' "${WORK}/a/dist/${NAME}-SHA256SUMS")"

package "${WORK}/a/release" "${WORK}/c/dist" "$NAME"
assert_eq "without an SBOM, there is none and the checksums leave it out" \
  "$(printf '%s\n' "${NAME}-SHA256SUMS" "${NAME}-mix.lock" "${NAME}.tar.gz")" \
  "$(cd "${WORK}/c/dist" && LC_ALL=C ls)"

## ── 5. Refusals ─────────────────────────────────────────────────────────

section "5/5  It refuses what it cannot package faithfully"

if SOURCE_DATE_EPOCH="$EPOCH" bash "$PACKAGE" "${WORK}/nowhere" "${WORK}/d" "$NAME" >/dev/null 2>&1; then
  fail "a directory without bin/vigil is refused"
else
  pass "a directory without bin/vigil is refused"
fi
if SOURCE_DATE_EPOCH="yesterday" bash "$PACKAGE" "${WORK}/a/release" "${WORK}/d" "$NAME" >/dev/null 2>&1; then
  fail "a SOURCE_DATE_EPOCH that is not a number is refused"
else
  pass "a SOURCE_DATE_EPOCH that is not a number is refused"
fi
if SOURCE_DATE_EPOCH="$EPOCH" bash "$PACKAGE" "${WORK}/a/release" "${WORK}/d" "$NAME" "${WORK}/no-bom.json" >/dev/null 2>&1; then
  fail "a missing SBOM is refused"
else
  pass "a missing SBOM is refused"
fi

report
