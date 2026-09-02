#!/usr/bin/env bash
# scripts/init.sh — first-time setup for this instance: vault, secrets,
# skill bootstrap, first start. Runs as root (vault operations via as_vigil),
# once per vault. Idempotent but protective: if /etc/vigil/env already exists
# it aborts unless --force is given.
#
# Usage: sudo ./scripts/init.sh (--new-vault | --existing-vault <git-url>)
#          [--allow-unprotected] [--force] [--keep-token]
#          [--dry-run] [--non-interactive] [--verbose] [--help]
#        sudo ./scripts/init.sh --check-only [--vault <path>]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NEW_VAULT=0
EXISTING_VAULT_URL=""
VAULT_REMOTE_URL=""
ALLOW_UNPROTECTED=0
FORCE=0
KEEP_TOKEN=0
CHECK_ONLY=0
CHECK_ONLY_VAULT=""

usage() {
  cat <<'EOF'
scripts/init.sh — first-time setup: vault, secrets, skill bootstrap, start.

Prerequisite: setup.sh has already run.

  --new-vault                 create an empty vault with a skeleton
  --existing-vault <git-url>  clone an existing vault
  --vault-remote-url <url>    upstream URL for --new-vault (required with
                              --non-interactive, otherwise asked interactively)
  --allow-unprotected         skip the Cloudflare Access check in verify()
  --force                     regenerate existing secrets (requires typing "yes")
  --keep-token                do not seed a new token — prints instructions for
                              transferring the dets files from the old container
  --dry-run                   log changes with [DRY RUN] instead of applying
  --non-interactive           run through without any prompts
  --verbose                   extra debug output (set -x)
  --help                      this help

  --check-only [--vault <path>]
      Run only the vault adoption check, read-only, against an existing vault
      (default /var/lib/vigil/vault). No cloning, no secrets, no build, no
      service restart — safe to run against a running service. Exit 0 (no
      findings) / 2 (vault not readable) / 3 (findings present). Mutually
      exclusive with --new-vault/--existing-vault.
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
    --new-vault)
      NEW_VAULT=1
      shift
      ;;
    --existing-vault)
      EXISTING_VAULT_URL="$2"
      shift 2
      ;;
    --vault-remote-url)
      VAULT_REMOTE_URL="$2"
      shift 2
      ;;
    --allow-unprotected)
      ALLOW_UNPROTECTED=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --keep-token)
      KEEP_TOKEN=1
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --vault)
      CHECK_ONLY_VAULT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
      # shellcheck disable=SC2034 # read by ask_yes_no/ask_value/confirm_destructive in lib.sh
      NON_INTERACTIVE=1
      shift
      ;;
    --verbose)
      # shellcheck disable=SC2034 # only relevant for set -x, no other reference needed
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

if [ "$CHECK_ONLY" = "1" ]; then
  if [ "$NEW_VAULT" = "1" ] || [ -n "$EXISTING_VAULT_URL" ]; then
    err "--check-only is mutually exclusive with --new-vault/--existing-vault."
    exit 2
  fi
elif [ "$NEW_VAULT" = "1" ] && [ -n "$EXISTING_VAULT_URL" ]; then
  err "Give exactly one of --new-vault / --existing-vault, not both."
  exit 2
elif [ "$NEW_VAULT" != "1" ] && [ -z "$EXISTING_VAULT_URL" ]; then
  err "Exactly one of --new-vault / --existing-vault is required."
  exit 2
fi

VAULT="/var/lib/vigil/vault"
ENV_FILE="/etc/vigil/env"

## ── Vault adoption phase ──────────────────────────────────────────────────
#
# Automatic fixes (additive, applied without asking): .gitignore, local git
# config, upstream, missing _domains.yml entries, directory permissions.
# Report-only findings (content; never repaired automatically): frontmatter,
# filenames, chunk-id migration risk, domain drift, unpushed commits,
# consolidation candidates, an extra remote.
# Runs on --existing-vault (before the secrets step) and standalone under
# --check-only, which is strictly read-only. Skipped for --new-vault.

PHASE2B_APPLIED=()
PHASE2B_PENDING_AUTO=()

phase2b_fix_gitignore() {
  local vault="$1" mode="$2"
  local gitignore="${vault}/.gitignore"
  local needs_append=1 is_tracked=0

  if [ -f "$gitignore" ] && grep -qxF '.obsidian/' "$gitignore"; then
    needs_append=0
  fi
  if as_vigil git -C "$vault" ls-files --error-unmatch -- .obsidian >/dev/null 2>&1; then
    is_tracked=1
  fi
  [ "$needs_append" = "0" ] && [ "$is_tracked" = "0" ] && return 0

  local description="gitignore: add .obsidian/"
  if [ "$is_tracked" = "1" ]; then
    description="${description}, and remove the already-tracked .obsidian directory from the index"
  fi

  if [ "$mode" = "check" ]; then
    PHASE2B_PENDING_AUTO+=("$description")
    return 0
  fi

  if [ "$needs_append" = "1" ]; then
    # shellcheck disable=SC2016 # $file is expanded by the inner bash -c, not here
    as_vigil bash -c '
      file="$1"
      if [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" = "0" ]; then
        printf "\n" >>"$file"
      fi
      printf ".obsidian/\n" >>"$file"
    ' _ "$gitignore"
  fi
  if [ "$is_tracked" = "1" ]; then
    as_vigil git -C "$vault" rm -r --cached -- .obsidian >/dev/null
  fi
  PHASE2B_APPLIED+=("added .obsidian/ to .gitignore$(
    [ "$is_tracked" = "1" ] && echo " (and removed the already-tracked .obsidian directory from the index)"
  )")
}

phase2b_fix_git_config() {
  local vault="$1" mode="$2"
  local name email
  name="$(as_vigil git -C "$vault" config --local user.name 2>/dev/null || true)"
  email="$(as_vigil git -C "$vault" config --local user.email 2>/dev/null || true)"
  local gpgsign
  gpgsign="$(as_vigil git -C "$vault" config --local commit.gpgsign 2>/dev/null || true)"

  if [ "$name" = "vigil" ] && [ "$email" = "vigil@$(hostname)" ] && [ "$gpgsign" = "false" ]; then
    return 0
  fi

  if [ "$mode" = "check" ]; then
    PHASE2B_PENDING_AUTO+=("git config: set local user.name/user.email/commit.gpgsign")
    return 0
  fi

  as_vigil git -C "$vault" config user.name vigil
  as_vigil git -C "$vault" config user.email "vigil@$(hostname)"
  as_vigil git -C "$vault" config commit.gpgsign false
  PHASE2B_APPLIED+=("set local git configuration in the vault")
}

phase2b_fix_upstream() {
  local vault="$1" mode="$2"
  local upstream
  upstream="$(as_vigil git -C "$vault" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ "$upstream" = "github/main" ] && return 0

  local github_remote
  github_remote="$(as_vigil git -C "$vault" remote 2>/dev/null | grep -qx github && echo yes || echo no)"

  local description="upstream: point main at github/main"
  [ "$github_remote" = "no" ] && description="${description} (remote 'github' missing; will be renamed from 'origin', or must be added by hand)"

  if [ "$mode" = "check" ]; then
    PHASE2B_PENDING_AUTO+=("$description")
    return 0
  fi

  if [ "$github_remote" = "no" ]; then
    if as_vigil git -C "$vault" remote | grep -qx origin; then
      as_vigil git -C "$vault" remote rename origin github
    else
      warn "upstream: no 'github' or 'origin' remote in the vault — cannot set it automatically."
      return 0
    fi
  fi
  as_vigil git -C "$vault" branch --set-upstream-to=github/main main
  PHASE2B_APPLIED+=("pointed upstream of main at github/main")
}

phase2b_fix_domains_yml() {
  local vault="$1" mode="$2" findings_json="$3"
  local missing_domains
  missing_domains="$(
    echo "$findings_json" |
      jq -r '.b4_domain_drift[] | select(.message | contains("is unknown to the runtime")) | .message' |
      grep -oP "domain '\K[^']+" || true
  )"
  [ -z "$missing_domains" ] && return 0

  local domain
  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    if [ "$mode" = "check" ]; then
      PHASE2B_PENDING_AUTO+=("_domains.yml: add entry '${domain}: \"\"'")
    else
      # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c, not here
      as_vigil bash -c 'printf "%s: \"\"\n" "$1" >>"$2"' _ "$domain" "${vault}/_domains.yml"
      PHASE2B_APPLIED+=("added a _domains.yml entry for domain '${domain}'")
    fi
  done <<<"$missing_domains"
}

phase2b_fix_permissions() {
  local vault="$1" mode="$2"
  local owner
  owner="$(stat -c '%U:%G' "$vault" 2>/dev/null || echo '?:?')"
  local mode_bits
  mode_bits="$(stat -c '%a' "$vault" 2>/dev/null || echo '?')"

  local wrong_owner=0 wrong_permissions=0
  [ "$owner" != "vigil:vigil" ] && wrong_owner=1
  [ "$mode_bits" != "750" ] && wrong_permissions=1
  [ "$wrong_owner" = "0" ] && [ "$wrong_permissions" = "0" ] && return 0

  if [ "$mode" = "check" ]; then
    PHASE2B_PENDING_AUTO+=("permissions: chown -R vigil:vigil, chmod 0750 on ${vault}")
    return 0
  fi

  chown -R vigil:vigil "$vault"
  chmod 0750 "$vault"
  PHASE2B_APPLIED+=("fixed permissions on ${vault} (vigil:vigil, 0750)")
}

# phase2b_run <vault> <mode>  — mode: "apply" | "check"
# Sets PHASE2B_APPLIED/PHASE2B_PENDING_AUTO and returns the total number of
# (pending or reported) findings through the global PHASE2B_TOTAL_FINDINGS.
phase2b_run() {
  local vault="$1" mode="$2"
  PHASE2B_APPLIED=()
  PHASE2B_PENDING_AUTO=()
  PHASE2B_TOTAL_FINDINGS=0

  echo
  if [ "$mode" = "check" ]; then
    echo "── Vault adoption (--check-only) ──"
  else
    echo "── Vault adoption ──"
  fi

  # Make sure deps are present BEFORE any mix task runs: this phase sits
  # ahead of the dependency audit, which would otherwise be the first thing to
  # call `mix deps.get`. Without MIX_ENV=prod, for the same reason as
  # `mix test`: in :prod config/runtime.exs reaches for /var/lib/vigil, which
  # is not ready at this point in the sequence.
  if ! as_vigil bash -c 'cd /opt/vigil/repo && mix deps.get' >/dev/null; then
    err "mix deps.get failed for the vault adoption check."
    return 1
  fi

  local findings_json
  if ! findings_json="$(as_vigil bash -c "cd /opt/vigil/repo && mix vigil.vault_check '${vault}'")"; then
    err "mix vigil.vault_check failed — vault at ${vault} is not readable or has no valid content."
    return 2
  fi

  # ── Automatic fixes ───────────────────────────────────────────────────
  phase2b_fix_gitignore "$vault" "$mode"
  phase2b_fix_git_config "$vault" "$mode"
  phase2b_fix_upstream "$vault" "$mode"
  phase2b_fix_domains_yml "$vault" "$mode" "$findings_json"
  phase2b_fix_permissions "$vault" "$mode"

  # The gitignore and _domains.yml fixes change tracked content. Without this
  # step those changes would sit in the index (staged, never committed),
  # invisible to the pending-commit check and to anyone looking at the repo.
  # One commit for all automatic fixes of this run, with a push, authored as
  # vigil like Vigil.Git does.
  if [ "$mode" = "apply" ]; then
    as_vigil git -C "$vault" add -- .gitignore _domains.yml 2>/dev/null || true
    if ! as_vigil git -C "$vault" diff --cached --quiet -- .gitignore _domains.yml .obsidian 2>/dev/null; then
      # No pathspec on the commit itself: `git commit -- .obsidian` drops an
      # already-staged directory deletion (a git quirk, found empirically —
      # `git diff --cached -- .obsidian` shows it correctly, `git commit --
      # .obsidian` does not). At this point in init.sh the index contains
      # only what the automatic fixes staged, so committing everything staged
      # is safe.
      if as_vigil git -C "$vault" -c user.name=vigil -c user.email=vigil@local commit -q -m \
        "vault adoption: automatic fixes"; then
        if as_vigil git -C "$vault" remote | grep -qx github &&
          as_vigil git -C "$vault" push github main >/dev/null 2>&1; then
          PHASE2B_APPLIED+=("committed automatic fixes and pushed them to github")
        else
          warn "automatic fixes committed, but push failed or no 'github' remote — please push manually."
        fi
      fi
    fi
  fi

  if [ "${#PHASE2B_APPLIED[@]}" -gt 0 ]; then
    echo "Applied automatically (${#PHASE2B_APPLIED[@]}):"
    for e in "${PHASE2B_APPLIED[@]}"; do echo "  ✓ ${e}"; done
  fi
  if [ "${#PHASE2B_PENDING_AUTO[@]}" -gt 0 ]; then
    echo "Would be applied (${#PHASE2B_PENDING_AUTO[@]}):"
    for e in "${PHASE2B_PENDING_AUTO[@]}"; do echo "  ✓ ${e}"; done
    PHASE2B_TOTAL_FINDINGS=$((PHASE2B_TOTAL_FINDINGS + ${#PHASE2B_PENDING_AUTO[@]}))
  fi

  # ── Report-only findings (content, from mix vigil.vault_check) ─────────
  local b_lines
  b_lines="$(
    {
      echo "$findings_json" | jq -r '.b1_frontmatter[] |
        "  ! \(.path): \(.message)\n      Fix: update_frontmatter"'
      echo "$findings_json" | jq -r '.b2_filenames[] | select(has("normalized") and has("path")) |
        "  ! \(.path): \(.message)\n      Fix: move_note with confirm: true (returns a backlink report)"'
      echo "$findings_json" | jq -r '.b2_filenames[] | select(has("paths")) |
        "  ! \(.message): \(.paths | join(", "))\n      Fix: rename one of the files (move_note)"'
      echo "$findings_json" | jq -r '.b2_filenames[] | select((has("paths")|not) and (has("normalized")|not)) |
        "  ! \(.path): \(.message)\n      Fix: choose a shorter filename (move_note)"'
      echo "$findings_json" | jq -r '.b4_domain_drift[] | select(.message | contains("is configured but does not exist in the vault")) |
        "  ! \(.message)"'
      echo "$findings_json" | jq -r '.b6_consolidation[] |
        "  ! \(.path): \(.headings) headings, \(.words) words" +
        (if (.duplicate_headings | length) > 0 then ", \(.duplicate_headings | length) duplicate titles" else "" end) +
        "\n      Fix: rewrite_note (mind the shrink threshold, confirm: true)"'
    } | sed '/^$/d'
  )"

  local b_count
  b_count="$(
    echo "$findings_json" | jq '
      (.b1_frontmatter | length) +
      (.b2_filenames | length) +
      ([.b4_domain_drift[] | select(.message | contains("is configured but does not exist in the vault"))] | length) +
      (.b6_consolidation | length)
    '
  )"

  # Unpushed commits and an extra remote are git facts, not vault content, so
  # they are checked directly here rather than in the mix task.
  local pending
  pending="$(as_vigil git -C "$vault" rev-list --count github/main..main 2>/dev/null || echo "0")"
  if [ "$pending" != "0" ]; then
    b_lines="${b_lines}
  ! ${pending} local commits not pushed
      Fix: git -C ${vault} push github main"
    b_count=$((b_count + 1))
  fi

  if as_vigil git -C "$vault" remote | grep -qx origin; then
    local origin_target
    origin_target="$(as_vigil git -C "$vault" remote get-url origin 2>/dev/null || echo "?")"
    b_lines="${b_lines}
  ! Remote 'origin' points at ${origin_target} — purpose unclear, review it"
    b_count=$((b_count + 1))
  fi

  if [ "$b_count" -gt 0 ]; then
    echo "Findings (${b_count}):"
    echo "$b_lines"
    PHASE2B_TOTAL_FINDINGS=$((PHASE2B_TOTAL_FINDINGS + b_count))
  fi

  # Chunk-id diff, always printed (even when empty)
  local b3_checked b3_count
  b3_checked="$(echo "$findings_json" | jq -r '.b3_chunk_diff.checked')"
  b3_count="$(echo "$findings_json" | jq -r '.b3_chunk_diff.changes | length')"
  if [ "$b3_count" = "0" ]; then
    echo "Chunk ids: unchanged (${b3_checked} checked)"
  else
    echo "WARNING: ${b3_count} chunk ids will change. Stored references and [[…]] links"
    echo "to those sections will break. This is a deliberate migration, not a"
    echo "side effect — review it before going live."
    echo "$findings_json" | jq -r '.b3_chunk_diff.changes[] | "  [\(.kind)] \(.path): \(.old) -> \(.new // "ERROR")"'
  fi

  # Inventory overview, always printed
  echo
  echo "Vault overview"
  echo "$findings_json" | jq -r '
    .overview |
    "  Domains: \(.domains)  (\(.domain_names | join(", ")))\n" +
    "  Notes:   \(.notes)\n" +
    "  Chunks:  \(.chunks)\n" +
    "  Size:    \(.size_bytes) bytes\n" +
    "  HEAD:    \(.head_sha // "?") (\(.head_date // "?"))"
  '

  return 0
}

## ── --check-only: standalone read-only mode, short-circuits everything ────

# Test seam: with VIGIL_INIT_TEST_STUBS=1, replace the root/vigil-user checks
# and the hardcoded /opt/vigil/repo checkout with a caller-supplied stand-in
# (VIGIL_TEST_REPO_ROOT), so scripts/test/check_only_test.sh can exercise the
# mode-string plumbing below without root, a "vigil" system user, or a real
# /opt/vigil/repo install. Unset (the default), this changes nothing.
if [ "${VIGIL_INIT_TEST_STUBS:-0}" = "1" ]; then
  require_root() { :; }
  require_command() { :; }
  as_vigil() {
    if [ "$1" = "bash" ] && [ "$2" = "-c" ] && [ -n "${VIGIL_TEST_REPO_ROOT:-}" ]; then
      bash -c "${3//\/opt\/vigil\/repo/$VIGIL_TEST_REPO_ROOT}"
    else
      "$@"
    fi
  }
fi

if [ "$CHECK_ONLY" = "1" ]; then
  require_root "$@"

  if [ "${VIGIL_INIT_TEST_STUBS:-0}" != "1" ] && [ ! -d /opt/vigil/repo/.git ]; then
    err "Code repo missing at /opt/vigil/repo — run setup.sh first."
    exit 2
  fi
  require_command mix
  require_command jq

  CHECK_VAULT="${CHECK_ONLY_VAULT:-$VAULT}"

  if [ ! -d "$CHECK_VAULT" ]; then
    err "Vault not readable or not present: ${CHECK_VAULT}"
    exit 2
  fi

  set +e
  phase2b_run "$CHECK_VAULT" "check"
  RUN_RC=$?
  set -e

  if [ "$RUN_RC" -ne 0 ]; then
    exit 2
  fi
  if [ "$PHASE2B_TOTAL_FINDINGS" -gt 0 ]; then
    exit 3
  fi
  exit 0
fi

## ── Step 1 — preflight ───────────────────────────────────────────────────

step "1/9  Preflight"
require_root "$@"

if ! id vigil >/dev/null 2>&1; then
  err "User 'vigil' missing — run setup.sh first."
  exit 2
fi
if [ ! -d /opt/vigil/repo/.git ]; then
  err "Code repo missing at /opt/vigil/repo — run setup.sh first."
  exit 2
fi
if [ ! -f /etc/systemd/system/vigil.service ]; then
  err "systemd unit missing — run setup.sh first."
  exit 2
fi
require_command mix
# jq is needed by the vault adoption phase and by verify(), not only in the
# --check-only path. setup.sh installs it — if it is missing here, setup.sh
# did not complete cleanly, and that should surface in preflight rather than
# halfway through the run.
require_command jq

if [ -f "$ENV_FILE" ]; then
  if [ "$FORCE" != "1" ]; then
    err "${ENV_FILE} already exists. init.sh is idempotent but will not overwrite secrets without --force."
    exit 2
  fi
  if ! confirm_destructive "Existing secrets in ${ENV_FILE} will be overwritten irreversibly."; then
    err "Aborted."
    exit 4
  fi
fi

if [ -L /opt/vigil/current ]; then
  log "Release already built (/opt/vigil/current present) — will be rebuilt in step 6."
else
  log "No release built yet — follows in step 6."
fi

record_done "preflight passed"

## ── Step 2 — provide the vault ───────────────────────────────────────────

step "2/9  Provide the vault"

# Set the service user's global git identity BEFORE any commit happens:
# init_vault.sh commits immediately, and without a global identity the very
# first commit on a fresh container aborts with "Please tell me who you are".
if [ "$DRY_RUN" != "1" ]; then
  as_vigil git config --global user.name vigil
  as_vigil git config --global user.email "vigil@$(hostname)"
  as_vigil git config --global commit.gpgsign false
  as_vigil git config --global init.defaultBranch main
fi

if [ -d "${VAULT}/.git" ]; then
  log "Vault already exists at ${VAULT} — skipping create/clone."
elif [ -n "$EXISTING_VAULT_URL" ]; then
  run_step "clone vault (${EXISTING_VAULT_URL})" -- as_vigil git clone "$EXISTING_VAULT_URL" "$VAULT"

  if [ "$DRY_RUN" != "1" ]; then
    as_vigil git -C "$VAULT" rev-parse HEAD >/dev/null || {
      err "Cloned vault has no HEAD."
      exit 2
    }
    [ -f "${VAULT}/_domains.yml" ] || warn "Cloned vault has no _domains.yml at its root."
    [ -n "$(as_vigil ls -A "$VAULT")" ] || {
      err "Cloned vault is empty."
      exit 2
    }
  fi

  # Renaming origin→github, local git config, .gitignore and so on all run
  # through the vault adoption phase below, not separately here.
else
  if [ -z "$VAULT_REMOTE_URL" ] && [ "$NON_INTERACTIVE" = "1" ]; then
    err "--new-vault with --non-interactive requires --vault-remote-url <url>."
    exit 2
  fi

  DOMAINS_DEFAULT="admin gear home journal projects training"
  DOMAINS_VALUE="$(ask_value "Domain directories (space separated)" "$DOMAINS_DEFAULT")"

  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] create vault skeleton at ${VAULT} (domains: ${DOMAINS_VALUE})"
  else
    as_vigil bash -c "VIGIL_INIT_DOMAINS='${DOMAINS_VALUE}' /opt/vigil/repo/scripts/init_vault.sh '${VAULT}'"

    NEW_REMOTE_URL="${VAULT_REMOTE_URL:-$(ask_value "Git URL for the new vault upstream" "git@github.com:<org>/vault.git")}"
    if as_vigil git -C "$VAULT" remote | grep -qx github; then
      :
    else
      as_vigil git -C "$VAULT" remote add github "$NEW_REMOTE_URL"
    fi
    as_vigil git -C "$VAULT" push -u github main
  fi
fi

record_done "vault ready at ${VAULT} (remote: github)"

## ── Step 2b — vault adoption ─────────────────────────────────────────────
# Only for --existing-vault: a fresh --new-vault skeleton satisfies the rules
# by construction.

if [ -n "$EXISTING_VAULT_URL" ]; then
  step "2b   Vault adoption"

  PHASE2B_MODE="apply"
  [ "$DRY_RUN" = "1" ] && PHASE2B_MODE="check"

  if ! phase2b_run "$VAULT" "$PHASE2B_MODE"; then
    err "Vault adoption check failed."
    exit 2
  fi

  if [ "${#PHASE2B_APPLIED[@]}" -gt 0 ]; then
    record_done "vault adoption: applied ${#PHASE2B_APPLIED[@]} fix(es)"
  fi
  if [ "${#PHASE2B_PENDING_AUTO[@]}" -gt 0 ] || [ "$PHASE2B_TOTAL_FINDINGS" -gt "${#PHASE2B_APPLIED[@]}" ]; then
    record_next_step "review the vault adoption findings above — they do not block init.sh, but should be looked at before going live"
  fi
fi

## ── Step 3 — secrets ─────────────────────────────────────────────────────

step "3/9  Secrets"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] generate VIGIL_AUTH_PASSWORD (openssl rand -base64 48)"
  AUTH_PASSWORD="[DRY RUN]"
else
  AUTH_PASSWORD="$(openssl rand -base64 48)"
fi
record_done "generated VIGIL_AUTH_PASSWORD (also the SkillKey HMAC secret)"

## ── Step 4 — runtime config ──────────────────────────────────────────────

step "4/9  Runtime config"

HOSTNAME_DEFAULT="localhost:4000"
if [ -f /etc/cloudflared/config.yml ]; then
  FOUND="$(grep -oP 'hostname:\s*\K\S+' /etc/cloudflared/config.yml 2>/dev/null | head -1 || true)"
  [ -n "$FOUND" ] && HOSTNAME_DEFAULT="$FOUND"
fi
PUBLIC_HOST="$(ask_value "Public hostname (OAuth issuer/resource)" "$HOSTNAME_DEFAULT")"

if [ "$PUBLIC_HOST" = "localhost:4000" ]; then
  ISSUER="http://localhost:4000"
else
  ISSUER="https://${PUBLIC_HOST}"
fi
RESOURCE="${ISSUER}/mcp"

# The domain list is deliberately NOT written here: it is read at runtime
# from _domains.yml, never maintained as a regex or list in code. A list kept
# in two places always drifts.
ENV_CONTENT="$(
  cat <<EOF
VIGIL_VAULT_PATH=${VAULT}
VIGIL_PORT=4000
VIGIL_GIT_REMOTE=github
VIGIL_TZ=Europe/Berlin
VIGIL_EXCLUDE=
VIGIL_ISSUER=${ISSUER}
VIGIL_RESOURCE=${RESOURCE}
VIGIL_AUTH_PASSWORD=${AUTH_PASSWORD}
VIGIL_STATE_DIR=/var/lib/vigil
VIGIL_SKILLKEY_TTL=3600
VIGIL_RATE_LIMIT_RPM=60
EOF
)"
write_file_atomically "$ENV_FILE" 0600 root:root "$ENV_CONTENT"
record_done "wrote runtime config to ${ENV_FILE}"

## ── Step 5 — dependency audit ────────────────────────────────────────────

step "5/9  Dependency audit"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix deps.get --only prod && mix hex.audit"
else
  AUDIT_OUTPUT="$(as_vigil bash -c 'cd /opt/vigil/repo && mix deps.get --only prod && mix hex.audit' 2>&1)" || true
  echo "$AUDIT_OUTPUT"
  if echo "$AUDIT_OUTPUT" | grep -qiE '\b(high|critical)\b'; then
    if [ "$FORCE" != "1" ]; then
      err "mix hex.audit reports HIGH/CRITICAL advisories. Override only with --force."
      exit 2
    fi
    warn "mix hex.audit reports HIGH/CRITICAL advisories, overridden with --force."
  else
    ok "No HIGH/CRITICAL advisory."
  fi
fi
record_done "ran the dependency audit"

## ── Step 6 — build ───────────────────────────────────────────────────────

step "6/9  Build"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix test (without MIX_ENV=prod), then MIX_ENV=prod mix release"
else
  # mix test runs without MIX_ENV=prod: in prod Mix loads the production
  # config and would reach for /var/lib/vigil. config/runtime.exs pins safe
  # paths for :test, but deliberately not for :prod.
  if ! as_vigil bash -c 'cd /opt/vigil/repo && mix test'; then
    err "mix test is red — not deploying."
    exit 1
  fi
  ok "mix test is green."

  SHORT_SHA="$(as_vigil git -C /opt/vigil/repo rev-parse --short HEAD)"
  as_vigil bash -c "cd /opt/vigil/repo && MIX_ENV=prod mix release --overwrite --path /opt/vigil/releases/${SHORT_SHA}"
  ln -sfn "/opt/vigil/releases/${SHORT_SHA}" /opt/vigil/current
  chown -h vigil:vigil /opt/vigil/current
  ok "Built release ${SHORT_SHA}, /opt/vigil/current points at it."
fi
record_done "mix test green, release built"

## ── Step 7 — start, token bootstrap, skill bootstrap ─────────────────────

step "7/9  Start, token bootstrap, skill bootstrap"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] systemctl start vigil, wait for health, seed tokens, create vigil-vault-conventions via skill_write"
else
  systemctl start vigil
  wait_until_healthy || exit 1

  RW_TOKEN="$(vigil_seed_token "$RESOURCE" vault)"
  RO_TOKEN="$(vigil_seed_token "$RESOURCE" vault:read)"

  if [ "$KEEP_TOKEN" = "1" ] && [ ! -s /var/lib/vigil/oauth_tokens.dets ]; then
    warn "--keep-token: /var/lib/vigil/oauth_tokens.dets is missing or empty — no previous tokens to carry over."
    echo
    echo "  For seamless access without re-authorizing existing clients:"
    echo "  back up oauth_tokens.dets + oauth_clients.dets on the old container"
    echo "  and copy them into /var/lib/vigil/ (stop the service briefly for that)."
    echo
    record_next_step "carry over oauth_tokens.dets/oauth_clients.dets from the old container, if wanted"
  fi

  SKILL_CONTENT="$(cat "${SCRIPT_DIR}/templates/vigil-vault-conventions.md")"
  SKILL_JSON_CONTENT="$(printf '%s' "$SKILL_CONTENT" | jq -Rs .)"
  # skill_write requires a SkillKey like every other write tool. That creates
  # a chicken-and-egg problem on a fresh vault: the vigil-vault-conventions
  # skill does not exist yet, so there is no skill_read response to take the
  # key from. do_skill_read/2 therefore returns the current SkillKey in the
  # error case as well (it is a pure HMAC over secret + time, independent of
  # any skill existing) — parsed here out of the failing skill_read
  # response.
  SKILL_READ_RESPONSE="$(mcp_call "http://localhost:4000" "$RW_TOKEN" "skill_read" \
    '{"name":"vigil-vault-conventions"}')"
  BOOTSTRAP_SKILL_KEY="$(echo "$SKILL_READ_RESPONSE" | mcp_error_text 2>/dev/null | grep -oP 'SkillKey: \K[0-9a-f]+' || true)"
  if [ -z "$BOOTSTRAP_SKILL_KEY" ]; then
    err "Could not extract a SkillKey from the skill_read response for bootstrapping: ${SKILL_READ_RESPONSE}"
    exit 1
  fi

  SKILL_WRITE_RESPONSE="$(mcp_call "http://localhost:4000" "$RW_TOKEN" "skill_write" \
    "{\"name\":\"vigil-vault-conventions\",\"content\":${SKILL_JSON_CONTENT},\"skill_key\":\"${BOOTSTRAP_SKILL_KEY}\"}")"
  if echo "$SKILL_WRITE_RESPONSE" | mcp_is_error; then
    err "skill_write for vigil-vault-conventions failed: $(echo "$SKILL_WRITE_RESPONSE" | mcp_error_text 2>/dev/null || echo "$SKILL_WRITE_RESPONSE")"
    exit 1
  fi
  ok "Created skill 'vigil-vault-conventions'."
fi
record_done "service started, tokens seeded, conventions skill created"

## ── Step 8 — verify() ────────────────────────────────────────────────────

step "8/9  verify()"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] verify() would run now"
else
  # Read by verify() in lib.sh, not referenced in this file.
  # shellcheck disable=SC2034
  VIGIL_VAULT="$VAULT"
  # shellcheck disable=SC2034
  VIGIL_RW_TOKEN="$RW_TOKEN"
  # shellcheck disable=SC2034
  VIGIL_RO_TOKEN="$RO_TOKEN"
  # shellcheck disable=SC2034
  VIGIL_RESOURCE="$RESOURCE"
  # shellcheck disable=SC2034
  VIGIL_LOCAL_URL="http://localhost:4000"
  # shellcheck disable=SC2034
  VIGIL_GIT_REMOTE="github"
  # shellcheck disable=SC2034
  VIGIL_ALLOW_UNPROTECTED="$ALLOW_UNPROTECTED"

  if [ "$ALLOW_UNPROTECTED" = "1" ]; then
    warn "--allow-unprotected: Cloudflare Access check (verify check 2) skipped. The endpoint is unprotected until Access is configured."
  fi

  if verify; then
    record_done "verify(): all mandatory checks passed"
  else
    err "verify() failed — stopping the service."
    systemctl stop vigil
    exit 3
  fi
fi

## ── Step 9 — summary and token output ────────────────────────────────────

step "9/9  Summary"

if [ "$DRY_RUN" != "1" ] && [ "$KEEP_TOKEN" != "1" ]; then
  echo
  echo "  ──────────────────────────────────────────────────────"
  echo "  RW token (full access — paste into the Claude.ai connector):"
  echo "  ${RW_TOKEN}"
  echo
  echo "  RO token (read-only, for read-only clients):"
  echo "  ${RO_TOKEN}"
  echo "  ──────────────────────────────────────────────────────"
  echo
  echo "  These values are stored nowhere except in"
  echo "  /var/lib/vigil/oauth_tokens.dets — readable by root only from here on."
  echo
fi

ok "init.sh finished."
