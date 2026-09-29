#!/usr/bin/env bash
# scripts/update.sh — switch to a different code revision. Runs as root, any
# number of times, idempotent. Never touches secrets or vault content; touches
# the systemd unit only with --update-unit.
#
# Usage: sudo ./scripts/update.sh [--to <ref> | --rebuild] [--skip-tests --force]
#            [--update-unit] [--accept-id-changes] [--rollback]
#            [--dry-run] [--non-interactive] [--verbose] [--help]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

TARGET_REF="origin/main"
SKIP_TESTS=0
FORCE=0
UPDATE_UNIT=0
ROLLBACK=0
REBUILD=0
TO_GIVEN=0
ACCEPT_ID_CHANGES=0

usage() {
  cat <<'EOF'
scripts/update.sh — switch code revision.

  --to <ref>          target commit/tag (default: origin/main)
  --rebuild             build the running commit again, into a new release,
                        and switch to it (after an Erlang/OTP security update)
  --skip-tests          only together with --force; is logged
  --force              allows --skip-tests
  --update-unit         adopt a changed systemd unit
  --accept-id-changes   switch even when the target moves chunk ids (without
                        it, a change is asked about, or refused under
                        --non-interactive)
  --rollback            go back to the previous release without building
  --dry-run             log changes with [DRY RUN] instead of applying them
  --non-interactive     run through without any prompts
  --verbose             extra debug output (set -x)
  --help                   this help
EOF
}

for a in "$@"; do
  if [ "$a" = "--help" ] || [ "$a" = "-h" ]; then
    usage
    exit 0
  fi
done

# Kept for require_root's hint, which repeats the command as it was given —
# the loop below shifts every argument out of "$@".
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      TARGET_REF="$2"
      TO_GIVEN=1
      shift 2
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --update-unit)
      UPDATE_UNIT=1
      shift
      ;;
    --accept-id-changes)
      ACCEPT_ID_CHANGES=1
      shift
      ;;
    --rollback)
      ROLLBACK=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
      # shellcheck disable=SC2034
      NON_INTERACTIVE=1
      shift
      ;;
    --verbose)
      # shellcheck disable=SC2034
      VERBOSE=1
      set -x
      shift
      ;;
    *)
      err "Unknown option: $1 (see --help)"
      exit 2
      ;;
  esac
done

if [ "$REBUILD" = "1" ] && [ "$TO_GIVEN" = "1" ]; then
  err "--rebuild builds the running commit; it does not take --to."
  exit 2
fi
if [ "$REBUILD" = "1" ] && [ "$ROLLBACK" = "1" ]; then
  err "--rebuild and --rollback are two different runs; pick one."
  exit 2
fi
if [ "$SKIP_TESTS" = "1" ] && [ "$FORCE" != "1" ]; then
  err "--skip-tests requires --force."
  exit 2
fi
if [ "$SKIP_TESTS" = "1" ]; then
  warn "--skip-tests active (with --force) — tests will NOT be run."
fi

## ── Test seam ────────────────────────────────────────────────────────────


# With VIGIL_UPDATE_TEST_STUBS=1 the four things that need a real vault host —
# root, the service account, systemd, a booted release — are replaced by
# stand-ins backed by files under $PREFIX, so scripts/test/update_test.sh can
# drive this script for real against a throwaway prefix. Everything the test
# exists to check stays production code: the step sequence, the order of
# stop/symlink/start, the exit codes, the rollback decision and the retention
# rule are the ones below, not a copy of them.
#
# Unset (the default) this block does nothing, and `sudo` resets the
# environment, so it cannot be smuggled into the invocation the release notes
# document.
if [ "${VIGIL_UPDATE_TEST_STUBS:-0}" = "1" ]; then
  # Refused as root rather than merely discouraged. With the stubs live the
  # script moves the `current` symlink, never stops or starts the real service,
  # and reports "update.sh finished" — a log indistinguishable from a good
  # deploy, for a deploy that did not happen. The comment above argues `sudo`
  # resets the environment, which is true and covers only the sudo path: a root
  # shell, /etc/environment or a cron wrapper do not.
  if [ "$(id -u)" -eq 0 ]; then
    err "VIGIL_UPDATE_TEST_STUBS=1 refused: the test seam must never be live as root."
    exit 2
  fi
  warn "VIGIL_UPDATE_TEST_STUBS=1 — root, the service account, systemd and verify() are stand-ins. This is not a deploy."

  require_root() { :; }
  as_vigil() { "$@"; }
  journalctl() { :; }
  vigil_seed_token() { echo "test-token"; }

  # The service is a file: written by start and stop, read by is-active. Each
  # start and stop is also recorded together with what `current` pointed at
  # when it happened, which is what lets the test assert that the symlink moved
  # while the service was down rather than under a running BEAM.
  #
  # The unit's start limit is modelled too (StartLimitBurst= in
  # deploy/vigil.service): a release that crashes on boot is restarted by
  # Restart=on-failure until the limit is used up, and from then on every
  # start is refused until `reset-failed`. A release holding .start-fails is
  # one whose start systemd reports as failed.
  systemctl() {
    case "${1:-}" in
      start | restart)
        if [ -f "${PREFIX}/.start-limit-hit" ]; then
          echo "refused $(readlink "$CURRENT" 2>/dev/null || echo none)" >>"${PREFIX}/.systemctl.log"
          return 1
        fi
        echo "start $(readlink "$CURRENT" 2>/dev/null || echo none)" >>"${PREFIX}/.systemctl.log"
        [ -f "$(readlink -f "$CURRENT")/.start-fails" ] && return 1
        : >"${PREFIX}/.service-active"
        if [ -f "$(readlink -f "$CURRENT")/.boot-fails" ]; then
          : >"${PREFIX}/.start-limit-hit"
        fi
        ;;
      reset-failed) rm -f "${PREFIX}/.start-limit-hit" ;;
      stop)
        rm -f "${PREFIX}/.service-active"
        echo "stop $(readlink "$CURRENT" 2>/dev/null || echo none)" >>"${PREFIX}/.systemctl.log"
        ;;
      is-active) [ -f "${PREFIX}/.service-active" ] ;;
      # Recorded apart from start and stop, whose log is the switchover's.
      daemon-reload | enable | disable) echo "$@" >>"${PREFIX}/.systemctl-units.log" ;;
      *) : ;;
    esac
  }

  # A release directory holding .boot-fails is one that never answers on
  # /healthz, which is how the test drives the health wait after a switch. One
  # holding .no-healthz is a release from before /healthz: up only where the
  # run accepts one (ACCEPT_PRE_HEALTHZ_RELEASE, scripts/lib.sh).
  release_answers() {
    local release
    release="$(readlink -f "$CURRENT")"
    [ ! -f "${release}/.boot-fails" ] &&
      { [ ! -f "${release}/.no-healthz" ] || [ "$ACCEPT_PRE_HEALTHZ_RELEASE" = "1" ]; }
  }
  wait_until_healthy() {
    systemctl is-active --quiet "$SERVICE" && release_answers
  }

  # verify() is the decision the automatic rollback hangs on, and it is a
  # property of the release that was switched to — which is how the test drives
  # both outcomes, and both attempts of the rollback path independently: a
  # release directory holding .verify-fails is one that does not come up.
  verify() { release_answers && [ ! -f "$(readlink -f "$CURRENT")/.verify-fails" ]; }
fi

## ── Helper: load VIGIL_* variables for verify() from the env file ────────

# Sets the VIGIL_* variables verify() (lib.sh) reads. Tokens are
# freshly seeded rather than cached as plaintext anywhere — the service
# has been running for a while; there is no "bootstrap moment" like in init.sh,
# and no reason to leave a secret sitting in a file nobody else needs.
#
# Not traced under --verbose: `source` would trace every line of the env file,
# the secrets included, and the assignments below the tokens. verify() hides
# its own use of them.
source_env_for_verify() {
  hide_trace
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  # shellcheck disable=SC2034
  VIGIL_LOCAL_URL="http://localhost:${VIGIL_PORT:-4000}"
  # shellcheck disable=SC2034
  VIGIL_ALLOW_UNPROTECTED=0
  # shellcheck disable=SC2034
  VIGIL_RW_TOKEN="$(vigil_seed_token "$VIGIL_RESOURCE" vault 900)"
  # shellcheck disable=SC2034
  VIGIL_RO_TOKEN="$(vigil_seed_token "$VIGIL_RESOURCE" vault:read 900)"
  show_trace
}

## ── Which commit a release was built from ────────────────────────────────

# release_revision <release-dir> — the short sha of the commit the release was
# built from, or nothing when that cannot be told. The running revision is a
# property of the release `current` points at, not of the code checkout: the
# checkout is moved to the target before the build, so reading it after a
# failed build or a rollback named a commit that was not running, and the same
# update run again reported "nothing to do".
#
# Read from the REVISION file every build writes, and for a release built
# before that file existed from its directory name, which has always begun
# with the short sha.
release_revision() {
  local release="$1" rev
  if [ -f "${release}/REVISION" ]; then
    rev="$(head -n 1 "${release}/REVISION")"
  else
    rev="$(basename "$release")"
    rev="${rev%%-*}"
  fi
  as_vigil git -C "$REPO" rev-parse --short "${rev}^{commit}" 2>/dev/null || true
}

## ── The checkout follows the running release ─────────────────────────────

# The revision the code checkout has to be on when this script ends, set once
# the running one is known; empty leaves the checkout where it is. The build
# needs the checkout on the target, and every way out that does not end on the
# target — a red audit or suite, a failed build, a refused unit, an automatic
# rollback, a dry run, an abort anywhere — puts it back, so that the checkout
# always shows what is running. A successful switch clears it.
CHECKOUT_TARGET=""

restore_checkout() {
  [ -n "$CHECKOUT_TARGET" ] || return 0
  local head
  head="$(as_vigil git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"
  [ "$head" = "$CHECKOUT_TARGET" ] && return 0
  if as_vigil git -C "$REPO" checkout -q "$CHECKOUT_TARGET"; then
    log "Code checkout put back on ${CHECKOUT_TARGET}, the running revision."
  else
    warn "Could not put the code checkout back on ${CHECKOUT_TARGET}. Fix: git -C ${REPO} checkout ${CHECKOUT_TARGET}"
  fi
}

# Replaces lib.sh's EXIT trap with one that restores the checkout first and
# then prints the same summary, with the exit code the script ended on.
# shellcheck disable=SC2329,SC2317 # invoked by the EXIT trap below
on_exit() {
  local rc="$1"
  restore_checkout || true
  summary "$rc"
}
trap 'on_exit $?' EXIT

## ── Rollback mode: short, separate path ──────────────────────────────────

if [ "$ROLLBACK" = "1" ]; then
  step "Rollback without building"
  require_root ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}

  if [ ! -f "$PREVIOUS_RELEASE_FILE" ]; then
    err "No previous release known (${PREVIOUS_RELEASE_FILE} missing)."
    exit 2
  fi
  OLD_RELEASE="$(cat "$PREVIOUS_RELEASE_FILE")"
  if [ ! -d "$OLD_RELEASE" ]; then
    err "Previous release ${OLD_RELEASE} no longer exists."
    exit 2
  fi

  # Step 7 writes this file before verify() runs and an automatic rollback does
  # not rewrite it, so after one the file names the release that is now current
  # — and without this guard `--rollback` symlinked `current` onto itself,
  # restarted, and told the operator the rollback had succeeded. It is not
  # rewritten instead of guarded because after an automatic rollback there is no
  # known release to go back to, and inventing one would be worse than saying so.
  if [ "$(readlink -f "$CURRENT")" = "$(readlink -f "$OLD_RELEASE")" ]; then
    err "Already running ${OLD_RELEASE} — there is nothing to roll back to."
    exit 2
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] switch back to ${OLD_RELEASE}, restart the service, verify()"
    ok "Dry run finished."
    exit 0
  fi

  # The checkout goes back with the release, whatever verify() says below.
  CHECKOUT_TARGET="$(release_revision "$OLD_RELEASE")"
  if [ -z "$CHECKOUT_TARGET" ]; then
    warn "Cannot tell which commit ${OLD_RELEASE} was built from — the code checkout is left where it is."
  fi

  # The release gone back to may predate /healthz.
  ACCEPT_PRE_HEALTHZ_RELEASE=1
  systemctl stop "$SERVICE"
  ln -sfn "$OLD_RELEASE" "$CURRENT"
  chown -h "${SERVICE_USER}:${SERVICE_GROUP}" "$CURRENT"
  start_service start || true
  wait_until_healthy || exit 1

  # shellcheck disable=SC2034
  VIGIL_VAULT="$VAULT"
  source_env_for_verify
  if verify; then
    ok "Rollback to ${OLD_RELEASE} succeeded, service is running."
    exit 0
  else
    err "Rolled back to ${OLD_RELEASE}, but verify() is still red."
    exit 1
  fi
fi

## ── Step 1 — preflight (exit 2, nothing changed) ─────────────────────────

step "1/8  Preflight"
require_root ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}

if ! systemctl is-active --quiet "$SERVICE"; then
  err "Service is not running — update.sh requires a running service."
  exit 2
fi
if [ ! -L "$CURRENT" ] || [ ! -d "$(readlink -f "$CURRENT")" ]; then
  err "${CURRENT} does not point at a valid release."
  exit 2
fi

# A setting every release from here on refuses to boot without, and that an
# init.sh older than it never wrote. Checked here rather than left to boot:
# a release that does not come up fails step 6's health wait and is rolled
# back, but only after the service was stopped for it. The value is only
# tested for being there — the boot check judges it — and never printed.
if ! grep -qE '^VIGIL_SKILLKEY_SECRET=.' "$ENV_FILE" 2>/dev/null; then
  err "${ENV_FILE} has no VIGIL_SKILLKEY_SECRET, which vigil now requires (the SkillKey's own HMAC secret). Add it once, then run update.sh again:"
  err "  echo \"VIGIL_SKILLKEY_SECRET=\$(openssl rand -base64 48)\" >> ${ENV_FILE}"
  exit 2
fi

GIT_REMOTE="$(vault_git_remote)"
GIT_BRANCH="$(vault_git_branch "$VAULT")"
PENDING="$(as_vigil git -C "$VAULT" rev-list --count "${GIT_REMOTE}/${GIT_BRANCH}..${GIT_BRANCH}" 2>/dev/null || echo "?")"
if [ "$PENDING" != "0" ]; then
  err "The vault has ${PENDING} unpushed commits. Secure them first: git -C ${VAULT} push ${GIT_REMOTE} ${GIT_BRANCH}"
  exit 2
fi

if [ -n "$(as_vigil git -C "$REPO" status --porcelain 2>/dev/null || true)" ]; then
  err "Code repo is not clean:"
  as_vigil git -C "$REPO" status --porcelain >&2
  exit 2
fi

# `df -k <dir> | awk NR==2` rather than `df --output=avail`: the latter is
# GNU-only, and this script is also run against a throwaway prefix by
# scripts/test/update_test.sh.
FREE_KB="$(df -k "$PREFIX" | awk 'NR == 2 { print $4 }')"
if [ "$FREE_KB" -lt 1048576 ]; then
  err "Less than 1 GB free under ${PREFIX} (${FREE_KB} KB)."
  exit 2
fi

for path in "$(dirname "$VAULT")" "$REPO" "$RELEASES"; do
  wrong="$(find "$path" '!' -user "$SERVICE_USER" -o '!' -group "$SERVICE_GROUP" 2>/dev/null | head -5 || true)"
  if [ -n "$wrong" ]; then
    err "Wrong ownership under ${path} — fix: chown -R ${SERVICE_USER}:${SERVICE_GROUP} ${path}"
    exit 2
  fi
done

record_done "preflight passed"

## ── Step 2 — fetch the target revision ───────────────────────────────────

step "2/8  Fetch target revision"

as_vigil git -C "$REPO" fetch --all --tags

CURRENT_SHA="$(release_revision "$(readlink -f "$CURRENT")")"
if [ -z "$CURRENT_SHA" ]; then
  err "Cannot tell which commit $(readlink -f "$CURRENT") was built from. Write its sha into $(readlink -f "$CURRENT")/REVISION, then run update.sh again."
  exit 2
fi
CHECKOUT_TARGET="$CURRENT_SHA"

if [ "$REBUILD" = "1" ]; then
  TARGET_SHA="$CURRENT_SHA"
  # A directory of its own, never the running one: the running release keeps
  # serving while this one is built, and stays the rollback target.
  RELEASE_DIR="${RELEASES}/${TARGET_SHA}-$(date -u +%Y%m%d%H%M%S)"
  while [ -e "$RELEASE_DIR" ]; do
    sleep 1
    RELEASE_DIR="${RELEASES}/${TARGET_SHA}-$(date -u +%Y%m%d%H%M%S)"
  done
  log "Rebuild: ${CURRENT_SHA} again, into $(basename "$RELEASE_DIR")"
else
  TARGET_SHA="$(as_vigil git -C "$REPO" rev-parse --short "$TARGET_REF")"
  RELEASE_DIR="${RELEASES}/${TARGET_SHA}"

  if [ "$CURRENT_SHA" = "$TARGET_SHA" ]; then
    ok "Target commit ${TARGET_SHA} matches the running revision — nothing to do. (--rebuild builds it again.)"
    exit 0
  fi

  log "Switch: ${CURRENT_SHA} → ${TARGET_SHA}"
  as_vigil git -C "$REPO" log --oneline "${CURRENT_SHA}..${TARGET_SHA}" || true

  CHANGED_FILES="$(as_vigil git -C "$REPO" diff --name-only "${CURRENT_SHA}..${TARGET_SHA}")"
  if echo "$CHANGED_FILES" | grep -qE '^mix\.exs$|^config/|^deploy/vigil\.service$'; then
    warn "The change touches mix.exs, config/ or deploy/vigil.service — review the summary."
  fi
fi

record_done "fetched target revision ${TARGET_SHA}"

## ── Step 3 — dependency audit (hard abort, no override) ──────────────────

step "3/8  Dependency audit"

as_vigil git -C "$REPO" checkout -q "$TARGET_SHA"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix deps.get && mix hex.audit && mix deps.audit"
else
  # All environments' deps, not --only prod: `mix test` below needs the test
  # deps, and a lock that bumped one of them would otherwise fail it with a
  # lock mismatch. The verdict is the exit status — hex.audit fails on a
  # retired package, deps.audit on a known vulnerability; neither prints a
  # severity word to grep for.
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash -c, not here
  if ! AUDIT_OUTPUT="$(as_vigil bash -c 'cd "$1" && mix deps.get && mix hex.audit && mix deps.audit' _ "$REPO" 2>&1)"; then
    echo "$AUDIT_OUTPUT"
    err "Dependency audit failed (retired package or known vulnerability). Aborting (no override in update.sh)."
    exit 2
  fi
  echo "$AUDIT_OUTPUT"
  ok "Dependency audit clean."
fi
record_done "ran the dependency audit"

## ── Step 4 — tests ───────────────────────────────────────────────────────

step "4/8  Tests"

if [ "$SKIP_TESTS" = "1" ]; then
  warn "Tests skipped (--skip-tests --force)."
elif [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix test"
else
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash -c, not here
  if ! as_vigil bash -c 'cd "$1" && mix test' _ "$REPO"; then
    err "mix test is red — not deploying, the running service is untouched."
    exit 1
  fi
  ok "mix test is green."
fi
record_done "tests run (or deliberately skipped)"

## ── Step 5 — build ───────────────────────────────────────────────────────

step "5/8  Build"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] MIX_ENV=prod mix release --path ${RELEASE_DIR}"
else
  # The release bundles the ERTS and OTP applications installed right now,
  # which is what makes --rebuild the way an Erlang/OTP security update reaches
  # the service. REVISION is what release_revision reads the running commit
  # from.
  # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c, not here
  as_vigil bash -c 'cd "$1" && MIX_ENV=prod mix release --overwrite --path "$2" && git rev-parse HEAD >"$2/REVISION"' \
    _ "$REPO" "$RELEASE_DIR"
  ok "Built release $(basename "$RELEASE_DIR") — the running release is untouched."
fi
record_done "built release $(basename "$RELEASE_DIR")"

## ── Chunk ids: a switch that moves a reference is asked about ───────────

# A chunk id is what every stored reference into the vault is made of — a
# `[[note#heading]]` link, an id an assistant keeps — and the contract says a
# release only moves one in a major version, with a note in CHANGELOG.md
# (docs/compatibility.md). Whether this switch moves any is asked of the two
# builds themselves, on the vault as it is now: the running release lists the
# ids it derives (`Vigil.Release.chunk_ids/0`, through `bin/vigil eval`, which
# loads its code and starts nothing), and the target checkout, compiled for
# the release just built, compares that list with its own
# (`mix vigil.slug_diff --against`). Checked here, after the build and before
# anything is switched, because the comparison needs the target compiled; the
# running service is untouched whatever it answers.
#
# A change is asked about, and refused under --non-interactive (exit 2)
# unless --accept-id-changes says the operator has read the release notes.
# Declining is exit 4. A running release that cannot list its ids — one built
# before it could — is compared against nothing, and that is said.
check_chunk_ids() {
  local running_ids exclude output
  exclude="$(env_file_value VIGIL_EXCLUDE)"
  # Owned by the service account, which reads it below; written by this shell.
  running_ids="$(as_vigil mktemp)"

  if ! as_vigil env VIGIL_VAULT_PATH="$VAULT" VIGIL_EXCLUDE="$exclude" \
    "${PREVIOUS_RELEASE}/bin/vigil" eval 'Vigil.Release.chunk_ids()' >"$running_ids" 2>/dev/null; then
    rm -f "$running_ids"
    warn "The running release cannot list its chunk ids (a release built before Vigil.Release.chunk_ids/0 cannot), so this switch is not compared. Before a slug change: mix vigil.slug_diff <vault>."
    return 0
  fi

  # shellcheck disable=SC2016 # $1-$3 are expanded by the inner bash -c, not here
  if output="$(as_vigil env VIGIL_EXCLUDE="$exclude" bash -c \
    'cd "$1" && MIX_ENV=prod mix vigil.slug_diff --against "$2" "$3"' \
    _ "$REPO" "$running_ids" "$VAULT" 2>&1)"; then
    rm -f "$running_ids"
    ok "No chunk id changes: every stored reference keeps resolving."
    return 0
  fi
  rm -f "$running_ids"
  echo "$output"

  if ! echo "$output" | grep -q "chunk id change(s)"; then
    err "mix vigil.slug_diff could not compare the chunk ids (output above). The running service is untouched."
    exit 1
  fi

  if [ "$ACCEPT_ID_CHANGES" = "1" ]; then
    warn "Switching although chunk ids change (--accept-id-changes): references to an id marked - stop resolving."
    return 0
  fi
  if [ "$NON_INTERACTIVE" = "1" ]; then
    err "$(basename "$RELEASE_DIR") changes the chunk ids above, and references to an id marked - stop resolving. Read the release's CHANGELOG entry, then run again with --accept-id-changes to switch anyway."
    exit 2
  fi
  if ! ask_yes_no "Switch anyway? References to an id marked - stop resolving." n; then
    err "Aborted before the switch: the chunk ids would change. The running service is untouched."
    exit 4
  fi
}

PREVIOUS_RELEASE="$(readlink -f "$CURRENT")"

if [ "$REBUILD" = "1" ]; then
  log "Rebuild of the running commit: its chunk ids are the running release's."
elif [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] compare the running release's chunk ids with mix vigil.slug_diff --against"
else
  check_chunk_ids
fi
record_done "compared chunk ids"

## ── Optional: adopt the systemd unit ─────────────────────────────────────

UNIT_SOURCE="${REPO}/deploy/vigil.service"
if ! diff -q "$UNIT_SOURCE" "$UNIT_FILE" >/dev/null 2>&1; then
  if [ "$UPDATE_UNIT" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "[DRY RUN] adopt the changed systemd unit"
    else
      # Verified before it replaces the installed unit: a rejected unit left
      # in /etc/systemd/system would be picked up by the next daemon-reload.
      # Same filter as setup.sh — a release binary that does not exist yet is
      # expected, anything else is not. Then its sandbox is scored against the
      # recorded target, so a unit that loosened it is not adopted either.
      # A directory rather than `mktemp --suffix`: the candidate keeps the
      # unit's own name, and GNU's --suffix is the one flag here macOS lacks.
      UNIT_CANDIDATE_DIR="$(mktemp -d)"
      UNIT_CANDIDATE="${UNIT_CANDIDATE_DIR}/$(basename "$UNIT_FILE")"
      cp "$UNIT_SOURCE" "$UNIT_CANDIDATE"
      ANALYSIS="$(systemd-analyze verify "$UNIT_CANDIDATE" 2>&1 || true)"
      UNEXPECTED="$(echo "$ANALYSIS" | grep -v -E "Executable .* does not exist|is not executable: No such file or directory|^$" || true)"
      if [ -n "$UNEXPECTED" ]; then
        rm -rf "$UNIT_CANDIDATE_DIR"
        err "systemd-analyze verify reports problems with the new unit:"
        echo "$UNEXPECTED" >&2
        exit 1
      fi
      if ! check_unit_exposure "$UNIT_CANDIDATE"; then
        rm -rf "$UNIT_CANDIDATE_DIR"
        err "Not adopting the new unit; the running service is untouched."
        exit 1
      fi
      install -m 0644 "$UNIT_CANDIDATE" "$UNIT_FILE"
      rm -rf "$UNIT_CANDIDATE_DIR"
      systemctl daemon-reload
      ok "systemd unit adopted."
    fi
    record_done "systemd unit updated"
  else
    warn "deploy/vigil.service changed — adopt it with --update-unit, otherwise the old unit stays active."
    record_next_step "run update.sh --update-unit to adopt the changed systemd unit"
  fi
fi

## ── The push safety net ──────────────────────────────────────────────────

# On every update rather than behind a flag: the timer runs a script from the
# code checkout this update has just moved, so the units that run it move with
# it. A host still on the cron line (/etc/cron.d/vigil-push-safety-net) is
# moved to the timer here. Nothing is switched yet, so a refusal leaves the
# running service as it was.
if ! install_push_timer "${REPO}/deploy"; then
  err "Not installing the push safety net's units; the running service is untouched."
  exit 1
fi
record_done "push safety net: vigil-push.timer enabled"

## ── Automatic rollback ───────────────────────────────────────────────────

# Back to the release that was running before step 6, for a new release that
# does not come up (step 6) and for one that comes up and fails verify()
# (step 7). Always exits: 3 when the old release serves again, 1 when it does
# not either. The checkout is put back by the EXIT trap, since CHECKOUT_TARGET
# still names the old release's revision.
#
# Nothing in here may end the run before the health wait has judged the old
# release: a stop or a start that systemd answers with an error is not the
# verdict, and under `set -e` it would leave the service down with the
# operator told nothing about the rollback.
roll_back_automatically() {
  # The release that ran before may predate /healthz.
  ACCEPT_PRE_HEALTHZ_RELEASE=1
  systemctl stop "$SERVICE" || true
  ln -sfn "$PREVIOUS_RELEASE" "$CURRENT"
  chown -h "${SERVICE_USER}:${SERVICE_GROUP}" "$CURRENT"
  start_service start || true

  if wait_until_healthy; then
    source_env_for_verify
    # shellcheck disable=SC2034
    VIGIL_VAULT="$VAULT"
    if verify; then
      err "Update rolled back to $(basename "$PREVIOUS_RELEASE"). The service is running again."
      exit 3
    fi
  fi
  err "Rollback to ${PREVIOUS_RELEASE} also failed. Manual intervention needed — restore the container's Proxmox snapshot."
  exit 1
}

## ── Step 6 — switch over ─────────────────────────────────────────────────

step "6/8  Switch over"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] systemctl stop ${SERVICE}; symlink to $(basename "$RELEASE_DIR"); systemctl start ${SERVICE}"
else
  systemctl stop "$SERVICE"
  ln -sfn "$RELEASE_DIR" "$CURRENT"
  chown -h "${SERVICE_USER}:${SERVICE_GROUP}" "$CURRENT"
  echo "$PREVIOUS_RELEASE" >"$PREVIOUS_RELEASE_FILE"
  # A start systemd refuses is a release that did not come up, which is the
  # health wait's to say and the rollback's to answer — not the end of the run.
  start_service start || true
  if ! wait_until_healthy; then
    err "$(basename "$RELEASE_DIR") did not come up — rolling back automatically to ${PREVIOUS_RELEASE}."
    roll_back_automatically
  fi
  ok "Switched to $(basename "$RELEASE_DIR") (previous release: ${PREVIOUS_RELEASE})."
fi
record_done "switched over to $(basename "$RELEASE_DIR")"

## ── Step 7 — verify() with automatic rollback ────────────────────────────

step "7/8  verify()"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] verify() would run now"
else
  source_env_for_verify
  # shellcheck disable=SC2034
  VIGIL_VAULT="$VAULT"

  if verify; then
    # The target runs now, and the checkout is already on it.
    CHECKOUT_TARGET=""
    record_done "verify(): all mandatory checks passed"
  else
    err "verify() failed — rolling back automatically to ${PREVIOUS_RELEASE}."
    roll_back_automatically
  fi
fi

## ── Step 8 — cleanup ─────────────────────────────────────────────────────

step "8/8  Cleanup"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] clean up old releases (keep the last 3, never delete current/previous)"
else
  # Both sides of the comparison below are resolved. CURRENT_LINK comes out of
  # `readlink -f` and the candidates come out of listing $RELEASES, so if any
  # component of the prefix is itself a symlink the two spellings of the same
  # directory never compare equal — and then nothing is protected at all: what
  # survives becomes an accident of modification order, and the previous
  # release, which is the rollback target, is among the ones deleted. Found by
  # scripts/test/update_test.sh, whose throwaway prefix lives under macOS's
  # symlinked /var.
  CURRENT_LINK="$(readlink -f "$CURRENT")"
  PREVIOUS_LINK="$(readlink -f "$PREVIOUS_RELEASE")"

  # Newest first, portably: `ls -dt` rather than `find -printf`, and a read
  # loop rather than `mapfile`. Both of those were GNU/bash-4 only, which made
  # this step — the one that deletes things — the one step that could not be
  # run anywhere but the vault host.
  # dotglob so an interrupted build's `.tmp-xyz` is pruned rather than kept
  # forever, and `! -L` so a convenience symlink into releases/ is never a
  # deletion candidate. Together those are what `-mindepth 1 -maxdepth 1
  # -type d` used to select.
  shopt -s dotglob
  ALL_RELEASES=()
  while IFS= read -r release; do
    { [ -d "$release" ] && [ ! -L "$release" ]; } || continue
    ALL_RELEASES+=("$release")
  done < <(ls -dt "$RELEASES"/* 2>/dev/null || true)
  shopt -u dotglob

  # An empty array is not an empty expansion under `set -u` in bash 3.2; it is
  # an unbound variable and the end of the script.
  if [ "${#ALL_RELEASES[@]}" -gt 0 ]; then
    kept=0
    for release in "${ALL_RELEASES[@]}"; do
      resolved="$(readlink -f "$release")"
      if [ "$resolved" = "$CURRENT_LINK" ] || [ "$resolved" = "$PREVIOUS_LINK" ]; then
        continue
      fi
      kept=$((kept + 1))
      if [ "$kept" -gt 1 ]; then
        log "Removing old release: ${release}"
        rm -rf "$release"
      fi
    done
  fi
fi
record_done "cleaned up old releases (kept the last 3)"

ok "update.sh finished."
