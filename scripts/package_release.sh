#!/usr/bin/env bash
# scripts/package_release.sh — turns a built release into the files a GitHub
# Release carries.
#
#   scripts/package_release.sh <release-dir> <dist-dir> <name> [<sbom>]
#
# Writes into <dist-dir>:
#
#   <name>.tar.gz       the release, with LICENSE and THIRD_PARTY_NOTICES.md
#                       at its root
#   <name>-mix.lock     the exact dependency set it was built from
#   <name>.cdx.json     the CycloneDX SBOM, when <sbom> is given
#   <name>-SHA256SUMS   the checksums of the three
#
# The tarball is deterministic: the same release directory gives the same
# bytes, whenever and wherever it is packaged. Entries are sorted by name,
# every entry carries the time SOURCE_DATE_EPOCH names (the commit time of
# HEAD when it is unset), owner and group are 0 with no names, and gzip
# records neither a file name nor a time. Modes are kept as the release has
# them except that nothing is group- or world-writable, so the packager's
# umask cannot leak into the archive.
#
# releases/COOKIE is left out. It is Erlang distribution's only credential,
# and a public tarball would hand the same one to every host that installed
# it; a release without one writes its own on the first bin/vigil command
# (rel/env.sh.eex).
#
# What it cannot make equal is a release directory that differs itself; see
# "Reproducibility" in docs/ci-cd.md for what two builds of one commit still
# differ in. release.yml runs this script, and so can anyone, to check a
# published tarball against a local build.
#
# Needs GNU tar (`gtar` on macOS) for --sort, --mtime and --owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 <release-dir> <dist-dir> <name> [<sbom>]" >&2
  exit 2
}

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
RELEASE="$1"
DIST="$2"
NAME="$3"
SBOM="${4:-}"

if [ ! -x "${RELEASE}/bin/vigil" ]; then
  echo "error: ${RELEASE} is not a built release (no bin/vigil)" >&2
  exit 1
fi
if [ -n "$SBOM" ] && [ ! -f "$SBOM" ]; then
  echo "error: no SBOM at ${SBOM}" >&2
  exit 1
fi

TAR=""
for candidate in gtar tar; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version 2>/dev/null | grep -q 'GNU tar'; then
    TAR="$candidate"
    break
  fi
done
if [ -z "$TAR" ]; then
  echo "error: GNU tar is required (on macOS: brew install gnu-tar)" >&2
  exit 1
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct)}"
case "$EPOCH" in
  '' | *[!0-9]*)
    echo "error: SOURCE_DATE_EPOCH must be seconds since the epoch, got '${EPOCH}'" >&2
    exit 1
    ;;
esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vigil-package.XXXXXX")"
# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap installed below
cleanup() { rm -rf "${STAGE:?}"; }
trap cleanup EXIT INT TERM

# A copy, so the notices can be added without touching the release directory.
cp -Rp "${RELEASE}/." "${STAGE}/"
install -m 0644 "${REPO_ROOT}/LICENSE" "${STAGE}/LICENSE"
install -m 0644 "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${STAGE}/THIRD_PARTY_NOTICES.md"
rm -f "${STAGE}/releases/COOKIE"

mkdir -p "$DIST"
LC_ALL=C "$TAR" \
  --format=gnu \
  --sort=name \
  --mtime="@${EPOCH}" \
  --owner=0 --group=0 --numeric-owner \
  --mode=go-w \
  -cf - -C "$STAGE" . | gzip -n -9 >"${DIST}/${NAME}.tar.gz"

cp "${REPO_ROOT}/mix.lock" "${DIST}/${NAME}-mix.lock"
subjects=("${NAME}.tar.gz" "${NAME}-mix.lock")
if [ -n "$SBOM" ]; then
  cp "$SBOM" "${DIST}/${NAME}.cdx.json"
  subjects+=("${NAME}.cdx.json")
fi

(cd "$DIST" && sha256 "${subjects[@]}" >"${NAME}-SHA256SUMS")
cat "${DIST}/${NAME}-SHA256SUMS"
