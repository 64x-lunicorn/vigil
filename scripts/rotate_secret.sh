#!/usr/bin/env bash
# scripts/rotate_secret.sh — replaces one of the two secrets in /etc/vigil/env
# and restarts the service on it: the consent password or the SkillKey
# secret, each on its own. Runs as root, against an installed service.
#
# Only the one line changes. Every other setting in the file stays as it is,
# and the file keeps its mode and owner. The new value is generated here,
# written to the file and never printed: not to the terminal, not to the
# journal, not to a trace under --verbose.
#
# A rotation revokes no token. A client that consented keeps its grant, and
# its tokens keep working; to end them too, revoke them with
# `scripts/grants.sh revoke-all` (docs/guide.md, "Rotating secrets").
#
# Usage: sudo ./scripts/rotate_secret.sh (password | skillkey)
#          [--dry-run] [--verbose] [--help]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
scripts/rotate_secret.sh — replace one secret in the env file and restart.

  password    a new consent password (VIGIL_AUTH_PASSWORD): the one typed on
              the consent page. Read it from the env file afterwards.
  skillkey    a new SkillKey secret (VIGIL_SKILLKEY_SECRET): every SkillKey
              handed out stops working; an assistant calls skill_read again.

  --dry-run   log what would change instead of changing it
  --verbose   extra debug output (set -x); the secret is never traced
  --help      this help

Every other setting in the env file is kept. A rotation revokes no token —
revoke those with: sudo ./scripts/grants.sh revoke-all
EOF
}

## ── Test seam ────────────────────────────────────────────────────────────

# With VIGIL_ROTATE_TEST_STUBS=1 root and systemd are stand-ins, so
# scripts/test/operator_secrets_test.sh can drive this script against a
# throwaway env file. What the test exists to check — which line changes,
# what is kept, that the service is restarted, what is printed and traced —
# is the code below, not a copy. Refused as root, as update.sh's seam is.
if [ "${VIGIL_ROTATE_TEST_STUBS:-0}" = "1" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    err "VIGIL_ROTATE_TEST_STUBS=1 refused: the test seam must never be live as root."
    exit 2
  fi
  require_root() { :; }
  systemctl() {
    case "${1:-}" in
      restart)
        : >"${PREFIX}/.service-active"
        echo "$@" >>"${PREFIX}/.systemctl.log"
        ;;
      is-active) [ -f "${PREFIX}/.service-active" ] ;;
      *) echo "$@" >>"${PREFIX}/.systemctl.log" ;;
    esac
  }
  wait_until_healthy() { systemctl is-active --quiet "$SERVICE"; }
fi

## ── Arguments ────────────────────────────────────────────────────────────

# Kept for require_root's hint, which repeats the command as it was given —
# the loop below shifts the secret's name out of "$@".
ORIGINAL_ARGS=("$@")

for a in "$@"; do
  if [ "$a" = "--help" ] || [ "$a" = "-h" ]; then
    trap - EXIT
    usage
    exit 0
  fi
done

WHICH=""
while [ $# -gt 0 ]; do
  case "$1" in
    password | skillkey)
      if [ -n "$WHICH" ]; then
        err "One secret per run: ${WHICH} or $1 (see --help)"
        exit 2
      fi
      WHICH="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verbose)
      # shellcheck disable=SC2034 # only relevant for set -x, no other reference needed
      VERBOSE=1
      set -x
      shift
      ;;
    *)
      err "Unknown argument: $1 (see --help)"
      exit 2
      ;;
  esac
done

case "$WHICH" in
  password)
    KEY="VIGIL_AUTH_PASSWORD"
    WHAT="the consent password"
    ;;
  skillkey)
    KEY="VIGIL_SKILLKEY_SECRET"
    WHAT="the SkillKey secret"
    ;;
  *)
    err "Name the secret to rotate: password or skillkey (see --help)"
    exit 2
    ;;
esac

## ── Step 1 — preflight ───────────────────────────────────────────────────

step "1/3  Preflight"
require_root "${ORIGINAL_ARGS[@]}"

if [ ! -f "$ENV_FILE" ]; then
  err "${ENV_FILE} does not exist — run init.sh first."
  exit 2
fi
require_command openssl
record_done "preflight passed"

## ── Step 2 — the new secret ──────────────────────────────────────────────

step "2/3  Replace ${KEY}"

# Generated and written with the tracing off, and handed to the file on stdin
# rather than as an argument. The line that set it is replaced; a file that
# had none (a host set up before the SkillKey secret existed) gets one.
hide_trace
NEW_SECRET="$(generate_secret)"
env_line "$KEY" "$NEW_SECRET" | env_file_update "$ENV_FILE"
NEW_SECRET=""
show_trace
record_done "replaced ${KEY} (${WHAT}) in ${ENV_FILE}, every other setting kept"

## ── Step 3 — restart ─────────────────────────────────────────────────────

step "3/3  Restart ${SERVICE}"

# restart, not start: a running service keeps the secret it started with.
# start_service clears the unit's failed-start count first, so a unit that
# gave up on an earlier start does not refuse this one.
if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] systemctl restart ${SERVICE}, wait for health"
else
  start_service restart
  wait_until_healthy || exit 1
fi
record_done "restarted ${SERVICE} on the new secret"

## ── What it did not do ───────────────────────────────────────────────────

echo
case "$WHICH" in
  password)
    echo "  The new consent password is in ${ENV_FILE}, and nowhere else:"
    echo "    sudo grep '^${KEY}=' ${ENV_FILE}"
    echo "  The old one no longer opens the consent page."
    ;;
  skillkey)
    echo "  Every SkillKey handed out under the old secret stops working. An"
    echo "  assistant gets a new one from skill_read, as after any rotation."
    ;;
esac
echo
echo "  Rotation revokes no token: every client that consented keeps its grant,"
echo "  and every token it holds keeps working. To end them as well:"
echo "    sudo ./scripts/grants.sh revoke-all"
echo
record_next_step "if the old secret may have been seen: sudo ./scripts/grants.sh revoke-all (rotation revokes no token)"

ok "rotate_secret.sh finished."
