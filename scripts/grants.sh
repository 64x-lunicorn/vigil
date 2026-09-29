#!/usr/bin/env bash
# scripts/grants.sh — list and revoke what the authorization server has
# granted: the grants, the registered clients, one grant, every grant, or a
# client together with its grants. Runs as root, against the running service.
#
# A grant is one authorization — a consent, or a token seeded by init.sh — and
# it is the unit of revocation: revoking one takes its access and refresh
# tokens at once, and both are refused from the next request on.
#
# Usage: sudo ./scripts/grants.sh list
#        sudo ./scripts/grants.sh clients
#        sudo ./scripts/grants.sh revoke <grant-id>
#        sudo ./scripts/grants.sh revoke-all [--yes]
#        sudo ./scripts/grants.sh delete-client <client-id>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# One command, one answer: lib.sh's run summary is for the multi-step scripts.
trap - EXIT

usage() {
  cat <<'EOF'
scripts/grants.sh — list and revoke grants and clients (docs/guide.md,
"Revoking access"). Talks to the running service; prints no token value.

  list                       every live grant: id, client, scope, issued, expiry
  clients                    every registered client and how many grants it holds
  revoke <grant-id>          revoke one grant: its access and refresh tokens
  revoke-all [--yes]         revoke every grant, seeded tokens included; asks
                             to type "yes" unless --yes is given
  delete-client <client-id>  delete a client and revoke every grant it holds
  --help                     this help
EOF
}

## ── Test seam ────────────────────────────────────────────────────────────

# With VIGIL_GRANTS_TEST_STUBS=1 root, the service account and systemd are
# stand-ins, so scripts/test/grants_test.sh can drive this script against a
# fake release that records what it was asked to evaluate. What the test
# exists to check — the arguments accepted, the confirmation, what is sent to
# the node and the exit status read back — is the code below, not a copy.
# Refused as root, as update.sh's seam is: `sudo` resets the environment, a
# root shell does not.
if [ "${VIGIL_GRANTS_TEST_STUBS:-0}" = "1" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    err "VIGIL_GRANTS_TEST_STUBS=1 refused: the test seam must never be live as root."
    exit 2
  fi
  require_root() { :; }
  as_vigil() { "$@"; }
  systemctl() { [ "${1:-}" = "is-active" ] && [ -f "${PREFIX}/.service-active" ]; }
fi

## ── Arguments ────────────────────────────────────────────────────────────

COMMAND="${1:-}"
case "$COMMAND" in
  --help | -h)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
  list | clients)
    [ $# -eq 1 ] || {
      err "${COMMAND} takes no arguments (see --help)"
      exit 2
    }
    ;;
  revoke | delete-client)
    [ $# -eq 2 ] && [ -n "$2" ] || {
      err "${COMMAND} needs exactly one id (see --help)"
      exit 2
    }
    ;;
  revoke-all)
    [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = "--yes" ]; } || {
      err "revoke-all takes only --yes (see --help)"
      exit 2
    }
    ;;
  *)
    err "Unknown command: ${COMMAND} (see --help)"
    exit 2
    ;;
esac

require_root "$@"

if ! systemctl is-active --quiet "$SERVICE"; then
  err "${SERVICE} is not running. The grants live in the running node; start it first: systemctl start ${SERVICE}"
  exit 2
fi

if [ "$COMMAND" = "revoke-all" ]; then
  if [ "${2:-}" != "--yes" ]; then
    confirm_destructive "Revoking every grant: every client must consent again, and every seeded token stops working." ||
      exit 4
  fi
  # --yes is this script's, not a word the node knows.
  set -- revoke-all
fi

## ── The call into the node ───────────────────────────────────────────────

# Through `bin/vigil rpc`, in the running node — never a second BEAM opening
# the dets files beside it (see vigil_seed_token in lib.sh). The words are
# sent base64-encoded, one per line, so an id is data for the node and never
# Elixir it evaluates.
ENCODED="$(printf '%s\n' "$@" | base64 | tr -d '\n')"
if ! ANSWER="$(as_vigil "${CURRENT}/bin/vigil" rpc "Vigil.OAuth.Grants.rpc(Vigil.OAuth.Store.over_tables(), System.system_time(:second), \"${ENCODED}\")")"; then
  err "bin/vigil rpc failed — is the release at ${CURRENT} the one running?"
  exit 1
fi

printf '%s\n' "$ANSWER"

# rpc exits 0 on anything that did not raise; a refusal is printed behind
# "error: ", and that is what the exit status is read from.
case "$ANSWER" in
  error:*) exit 1 ;;
esac
