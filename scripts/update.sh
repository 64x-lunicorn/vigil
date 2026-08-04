#!/usr/bin/env bash
# scripts/update.sh — switch to a different code revision. Runs as root, any
# number of times, idempotent. Does not touch secrets, vault content or
# the systemd unit only with --update-unit.
#
# Nutzung: sudo ./scripts/update.sh [--to <ref>] [--skip-tests --force]
#            [--update-unit] [--rollback]
#            [--dry-run] [--non-interactive] [--verbose] [--help]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ZIEL_REF="origin/main"
SKIP_TESTS=0
FORCE=0
UPDATE_UNIT=0
ROLLBACK=0

VAULT="/var/lib/vigil/vault"
PREVIOUS_RELEASE_FILE="/opt/vigil/.previous_release"

usage() {
  cat <<'EOF'
scripts/update.sh — Code-Stand wechseln.

  --to <ref>          Ziel-Commit/Tag (Default: origin/main)
  --skip-tests          only together with --force; is logged
  --force              erlaubt --skip-tests
  --update-unit         adopt a changed systemd unit
  --rollback            go back to the previous release without building
  --dry-run             log changes with [DRY RUN] instead of applying them
  --non-interactive     run through without any prompts
  --verbose             extra debug output (set -x)
  --help                   diese Hilfe
EOF
}

for a in "$@"; do
  if [ "$a" = "--help" ] || [ "$a" = "-h" ]; then
    usage
    exit 0
  fi
done

while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      ZIEL_REF="$2"
      shift 2
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
      err "Unbekannte Option: $1 (siehe --help)"
      exit 2
      ;;
  esac
done

if [ "$SKIP_TESTS" = "1" ] && [ "$FORCE" != "1" ]; then
  err "--skip-tests verlangt --force."
  exit 2
fi
if [ "$SKIP_TESTS" = "1" ]; then
  warn "--skip-tests active (with --force) — tests will NOT be run."
fi

## ── Helper: load VIGIL_* variables for verify() from /etc/vigil/env ──────

# Sets the VIGIL_* variables verify() (lib.sh) reads. Tokens are
# freshly seeded rather than cached as plaintext anywhere — the service
# has been running for a while; there is no "bootstrap moment" like in init.sh,
# and no reason to leave a secret sitting in a file nobody else needs.
source_env_for_verify() {
  set -a
  # shellcheck source=/dev/null
  source /etc/vigil/env
  set +a
  # shellcheck disable=SC2034
  VIGIL_LOCAL_URL="http://localhost:${VIGIL_PORT:-4000}"
  # shellcheck disable=SC2034
  VIGIL_GIT_REMOTE="${VIGIL_GIT_REMOTE:-github}"
  # shellcheck disable=SC2034
  VIGIL_ALLOW_UNPROTECTED=0
  # shellcheck disable=SC2034
  VIGIL_RW_TOKEN="$(vigil_seed_token "$VIGIL_RESOURCE" vault)"
  # shellcheck disable=SC2034
  VIGIL_RO_TOKEN="$(vigil_seed_token "$VIGIL_RESOURCE" vault:read)"
}

## ── Rollback mode: short, separate path ──────────────────────────────────

if [ "$ROLLBACK" = "1" ]; then
  step "Rollback without building"
  require_root "$@"

  if [ ! -f "$PREVIOUS_RELEASE_FILE" ]; then
    err "No previous release known (${PREVIOUS_RELEASE_FILE} missing)."
    exit 2
  fi
  OLD_RELEASE="$(cat "$PREVIOUS_RELEASE_FILE")"
  if [ ! -d "$OLD_RELEASE" ]; then
    err "Previous release ${OLD_RELEASE} no longer exists."
    exit 2
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] switch back to ${OLD_RELEASE}, restart the service, verify()"
    ok "Trockenlauf abgeschlossen."
    exit 0
  fi

  systemctl stop vigil
  ln -sfn "$OLD_RELEASE" /opt/vigil/current
  chown -h vigil:vigil /opt/vigil/current
  systemctl start vigil
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
require_root "$@"

if ! systemctl is-active --quiet vigil; then
  err "Service is not running — update.sh requires a running service."
  exit 2
fi
if [ ! -L /opt/vigil/current ] || [ ! -d "$(readlink -f /opt/vigil/current)" ]; then
  err "/opt/vigil/current does not point at a valid release."
  exit 2
fi

PENDING="$(as_vigil git -C "$VAULT" rev-list --count github/main..main 2>/dev/null || echo "?")"
if [ "$PENDING" != "0" ]; then
  err "The vault has ${PENDING} unpushed commits. Secure them first: git -C ${VAULT} push github main"
  exit 2
fi

if [ -n "$(as_vigil git -C /opt/vigil/repo status --porcelain 2>/dev/null || true)" ]; then
  err "Code repo is not clean:"
  as_vigil git -C /opt/vigil/repo status --porcelain >&2
  exit 2
fi

FREI_KB="$(df --output=avail -k /opt | tail -1 | tr -d ' ')"
if [ "$FREI_KB" -lt 1048576 ]; then
  err "Weniger als 1 GB frei unter /opt (${FREI_KB} KB)."
  exit 2
fi

for path in /var/lib/vigil /opt/vigil/repo /opt/vigil/releases; do
  falsch="$(find "$path" '!' -user vigil -o '!' -group vigil 2>/dev/null | head -5 || true)"
  if [ -n "$falsch" ]; then
    err "Wrong ownership under ${path} — fix: chown -R vigil:vigil ${path}"
    exit 2
  fi
done

record_done "Preflight bestanden"

## ── Step 2 — fetch the target revision ───────────────────────────────────

step "2/8  Ziel-Stand holen"

as_vigil git -C /opt/vigil/repo fetch --all --tags

AKTUELLE_SHA="$(as_vigil git -C /opt/vigil/repo rev-parse --short HEAD)"
TARGET_SHA="$(as_vigil git -C /opt/vigil/repo rev-parse --short "$ZIEL_REF")"

if [ "$AKTUELLE_SHA" = "$TARGET_SHA" ]; then
  ok "Target commit ${TARGET_SHA} matches the running revision — nothing to do."
  exit 0
fi

log "Wechsel: ${AKTUELLE_SHA} → ${TARGET_SHA}"
as_vigil git -C /opt/vigil/repo log --oneline "${AKTUELLE_SHA}..${TARGET_SHA}" || true

GEAENDERTE_DATEIEN="$(as_vigil git -C /opt/vigil/repo diff --name-only "${AKTUELLE_SHA}..${TARGET_SHA}")"
if echo "$GEAENDERTE_DATEIEN" | grep -qE '^mix\.exs$|^config/|^deploy/vigil\.service$'; then
  warn "The change touches mix.exs, config/ or deploy/vigil.service — review the summary."
fi

record_done "Ziel-Stand ${TARGET_SHA} geholt"

## ── Step 3 — dependency audit (hard abort, no override) ──────────────────

step "3/8  Dependency audit"

as_vigil git -C /opt/vigil/repo checkout -q "$TARGET_SHA"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix deps.get --only prod && mix hex.audit"
else
  AUDIT_OUTPUT="$(as_vigil bash -c 'cd /opt/vigil/repo && mix deps.get --only prod && mix hex.audit' 2>&1)" || true
  echo "$AUDIT_OUTPUT"
  if echo "$AUDIT_OUTPUT" | grep -qiE '\b(high|critical)\b'; then
    err "mix hex.audit reports HIGH/CRITICAL advisories. Aborting (no override in update.sh)."
    as_vigil git -C /opt/vigil/repo checkout -q "$AKTUELLE_SHA"
    exit 2
  fi
  ok "Kein HIGH/CRITICAL-Advisory."
fi
record_done "ran the dependency audit"

## ── Step 4 — tests ───────────────────────────────────────────────────────

step "4/8  Tests"

if [ "$SKIP_TESTS" = "1" ]; then
  warn "Tests skipped (--skip-tests --force)."
elif [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix test"
else
  if ! as_vigil bash -c 'cd /opt/vigil/repo && mix test'; then
    err "mix test is red — not deploying, the running service is untouched."
    as_vigil git -C /opt/vigil/repo checkout -q "$AKTUELLE_SHA"
    exit 1
  fi
  ok "mix test is green."
fi
record_done "tests run (or deliberately skipped)"

## ── Step 5 — build ───────────────────────────────────────────────────────

step "5/8  Bauen"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] MIX_ENV=prod mix release --path /opt/vigil/releases/${TARGET_SHA}"
else
  as_vigil bash -c "cd /opt/vigil/repo && MIX_ENV=prod mix release --overwrite --path /opt/vigil/releases/${TARGET_SHA}"
  ok "Built release ${TARGET_SHA} — the running release is untouched."
fi
record_done "built release ${TARGET_SHA}"

## ── Optional: adopt the systemd unit ─────────────────────────────────────

UNIT_QUELLE="/opt/vigil/repo/deploy/vigil.service"
if ! diff -q "$UNIT_QUELLE" /etc/systemd/system/vigil.service >/dev/null 2>&1; then
  if [ "$UPDATE_UNIT" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "[DRY RUN] adopt the changed systemd unit"
    else
      cp "$UNIT_QUELLE" /etc/systemd/system/vigil.service
      ANALYSE="$(systemd-analyze verify /etc/systemd/system/vigil.service 2>&1 || true)"
      if [ -n "$ANALYSE" ]; then
        err "systemd-analyze verify meldet Probleme mit der neuen Unit:"
        echo "$ANALYSE" >&2
        exit 1
      fi
      systemctl daemon-reload
      ok "systemd unit adopted."
    fi
    record_done "systemd-Unit aktualisiert"
  else
    warn "deploy/vigil.service changed — adopt it with --update-unit, otherwise the old unit stays active."
    record_next_step "run update.sh --update-unit to adopt the changed systemd unit"
  fi
fi

## ── Step 6 — switch over ─────────────────────────────────────────────────

step "6/8  Umschalten"

PREVIOUS_RELEASE="$(readlink -f /opt/vigil/current)"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] systemctl stop vigil; symlink to ${TARGET_SHA}; systemctl start vigil"
else
  systemctl stop vigil
  ln -sfn "/opt/vigil/releases/${TARGET_SHA}" /opt/vigil/current
  chown -h vigil:vigil /opt/vigil/current
  echo "$PREVIOUS_RELEASE" >"$PREVIOUS_RELEASE_FILE"
  systemctl start vigil
  wait_until_healthy || exit 1
  ok "Switched to ${TARGET_SHA} (previous release: ${PREVIOUS_RELEASE})."
fi
record_done "Umgeschaltet auf ${TARGET_SHA}"

## ── Step 7 — verify() with automatic rollback ────────────────────────────

step "7/8  verify()"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] verify() would run now"
else
  source_env_for_verify
  # shellcheck disable=SC2034
  VIGIL_VAULT="$VAULT"

  if verify; then
    record_done "verify(): all mandatory checks passed"
  else
    err "verify() failed — rolling back automatically to ${PREVIOUS_RELEASE}."
    systemctl stop vigil
    ln -sfn "$PREVIOUS_RELEASE" /opt/vigil/current
    chown -h vigil:vigil /opt/vigil/current
    systemctl start vigil
    wait_until_healthy || true

    if verify; then
      err "Update rolled back to $(basename "$PREVIOUS_RELEASE"). The service is running again."
      exit 3
    else
      err "Rollback auf ${PREVIOUS_RELEASE} ebenfalls fehlgeschlagen. Manuell eingreifen — Proxmox-Snapshot des Containers einspielen."
      exit 1
    fi
  fi
fi

## ── Step 8 — cleanup ─────────────────────────────────────────────────────

step "8/8  Cleanup"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] clean up old releases (keep the last 3, never delete current/previous)"
else
  AKTUELLER_LINK="$(readlink -f /opt/vigil/current)"
  VORHERIGER_LINK="$PREVIOUS_RELEASE"

  mapfile -t ALLE_RELEASES < <(find /opt/vigil/releases -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | awk '{print $2}')

  behalten=0
  for release in "${ALLE_RELEASES[@]}"; do
    if [ "$release" = "$AKTUELLER_LINK" ] || [ "$release" = "$VORHERIGER_LINK" ]; then
      continue
    fi
    behalten=$((behalten + 1))
    if [ "$behalten" -gt 1 ]; then
      log "Alten Release entfernen: ${release}"
      rm -rf "$release"
    fi
  done
fi
record_done "cleaned up old releases (kept the last 3)"

ok "update.sh abgeschlossen."
