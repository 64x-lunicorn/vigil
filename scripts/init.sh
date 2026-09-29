#!/usr/bin/env bash
# scripts/init.sh — first-time setup for this instance: vault, secrets,
# skill bootstrap, first start. Runs as root (vault operations via as_vigil),
# once per vault. Idempotent but protective: if /etc/vigil/env already exists
# it aborts unless --force is given.
#
# Usage: sudo ./scripts/init.sh (--new-vault | --existing-vault <git-url>)
#          [--allow-unprotected] [--force] [--ignore-audit] [--keep-token]
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
IGNORE_AUDIT=0
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
  --force                     run again over an existing env file: both
                              secrets are generated anew, every other
                              setting in it is kept (requires typing "yes")
  --ignore-audit              continue despite a failed dependency audit
  --keep-token                mint no token for the owner, who keeps the ones
                              carried over from the old container (the dets
                              files; how is printed). verify() gets two that
                              live 15 minutes
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

# Kept for require_root's hint, which repeats the command as it was given —
# the loop below shifts every argument out of "$@".
ORIGINAL_ARGS=("$@")

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
    --ignore-audit)
      IGNORE_AUDIT=1
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

# VAULT and ENV_FILE come from scripts/lib.sh, which states the installation
# layout once. They were repeated here as literals, which meant the same two
# paths were defined in two files that must agree.

# The vault's remote and branch, as the env file states them or, where it
# does not, as lib.sh defaults them. A run with --force keeps what the file
# it replaces said; a first run writes the defaults into the new one.
GIT_REMOTE="$(vault_git_remote)"

# vault_branch <vault> — the branch the vault is pulled and pushed on: the env
# file's, or else the one the clone has checked out, or else the default for
# a vault that is not there yet. Not vault_git_branch: that asks for a branch
# already tracking the remote, and adoption is what makes a fresh clone's
# branch do so.
vault_branch() {
  local vault="$1" branch
  branch="$(env_file_value VIGIL_GIT_BRANCH)"
  if [ -z "$branch" ] && [ -d "${vault}/.git" ]; then
    branch="$(as_vigil git -C "$vault" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  fi
  echo "${branch:-$DEFAULT_GIT_BRANCH}"
}

## ── Vault adoption phase ──────────────────────────────────────────────────
#
# Automatic fixes (additive, applied without asking): .gitignore, local git
# config, upstream, missing _domains.yml entries, directory permissions.
# Report-only findings (content; never repaired automatically): frontmatter,
# filenames, chunk-id migration risk, domain drift, unpushed commits,
# consolidation candidates, an extra remote.
# Runs on --existing-vault (before the secrets step) and standalone under
# --check-only, which is strictly read-only. Skipped for --new-vault.

ADOPTION_FIXES_APPLIED=()
ADOPTION_FIXES_PENDING=()

# Obsidian's device-local directories (OBSIDIAN_LOCAL_DIRS in lib.sh): one
# finding per directory the .gitignore misses or the index still tracks.
fix_vault_gitignore() {
  local vault="$1" mode="$2"
  local lines line
  if ! lines="$(ignore_obsidian_dirs "$vault" "$mode")"; then
    err "gitignore: could not keep Obsidian's directories out of the vault history."
    return 1
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$mode" = "check" ]; then
      ADOPTION_FIXES_PENDING+=("$line")
    else
      ADOPTION_FIXES_APPLIED+=("$line")
    fi
  done <<<"$lines"
}

fix_vault_git_config() {
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
    ADOPTION_FIXES_PENDING+=("git config: set local user.name/user.email/commit.gpgsign")
    return 0
  fi

  as_vigil git -C "$vault" config user.name vigil
  as_vigil git -C "$vault" config user.email "vigil@$(hostname)"
  as_vigil git -C "$vault" config commit.gpgsign false
  ADOPTION_FIXES_APPLIED+=("set local git configuration in the vault")
}

# A fresh clone names its remote `origin`, git's own default; adoption renames
# it to the remote the env file says, unless that is `origin` already.
fix_vault_upstream() {
  local vault="$1" mode="$2" branch="$3"
  local upstream
  upstream="$(as_vigil git -C "$vault" rev-parse --abbrev-ref --symbolic-full-name "${branch}@{u}" 2>/dev/null || true)"
  [ "$upstream" = "${GIT_REMOTE}/${branch}" ] && return 0

  local has_remote
  has_remote="$(as_vigil git -C "$vault" remote 2>/dev/null | grep -qx "$GIT_REMOTE" && echo yes || echo no)"

  local description="upstream: point ${branch} at ${GIT_REMOTE}/${branch}"
  [ "$has_remote" = "no" ] && description="${description} (remote '${GIT_REMOTE}' missing; will be renamed from 'origin', or must be added by hand)"

  if [ "$mode" = "check" ]; then
    ADOPTION_FIXES_PENDING+=("$description")
    return 0
  fi

  if [ "$has_remote" = "no" ]; then
    if as_vigil git -C "$vault" remote | grep -qx origin; then
      as_vigil git -C "$vault" remote rename origin "$GIT_REMOTE"
    else
      warn "upstream: no '${GIT_REMOTE}' or 'origin' remote in the vault — cannot set it automatically."
      return 0
    fi
  fi
  as_vigil git -C "$vault" branch --set-upstream-to="${GIT_REMOTE}/${branch}" "$branch"
  ADOPTION_FIXES_APPLIED+=("pointed upstream of ${branch} at ${GIT_REMOTE}/${branch}")
}

fix_vault_domains_yml() {
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
      ADOPTION_FIXES_PENDING+=("_domains.yml: add entry '${domain}: \"\"'")
    else
      # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c, not here
      as_vigil bash -c 'printf "%s: \"\"\n" "$1" >>"$2"' _ "$domain" "${vault}/_domains.yml"
      ADOPTION_FIXES_APPLIED+=("added a _domains.yml entry for domain '${domain}'")
    fi
  done <<<"$missing_domains"
}

fix_vault_permissions() {
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
    ADOPTION_FIXES_PENDING+=("permissions: chown -R vigil:vigil, chmod 0750 on ${vault}")
    return 0
  fi

  chown -R vigil:vigil "$vault"
  chmod 0750 "$vault"
  ADOPTION_FIXES_APPLIED+=("fixed permissions on ${vault} (vigil:vigil, 0750)")
}

# run_vault_adoption <vault> <mode>  — mode: "apply" | "check"
# Sets ADOPTION_FIXES_APPLIED/ADOPTION_FIXES_PENDING and returns the total number of
# (pending or reported) findings through the global ADOPTION_TOTAL_FINDINGS.
run_vault_adoption() {
  local vault="$1" mode="$2"
  local branch
  branch="$(vault_branch "$vault")"
  ADOPTION_FIXES_APPLIED=()
  ADOPTION_FIXES_PENDING=()
  ADOPTION_TOTAL_FINDINGS=0

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
  # Compiled here too, so the first run's compiler output does not land in
  # the JSON the check below prints on stdout.
  if ! as_vigil bash -c 'cd /opt/vigil/repo && mix deps.get && mix compile' >/dev/null; then
    err "mix deps.get failed for the vault adoption check."
    return 1
  fi

  local findings_json
  # The path is an argument to the fixed script, never part of it.
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash -c, not here
  if ! findings_json="$(as_vigil bash -c 'cd /opt/vigil/repo && mix vigil.vault_check "$1"' _ "$vault")"; then
    err "mix vigil.vault_check failed — vault at ${vault} is not readable or has no valid content."
    return 2
  fi

  # ── Automatic fixes ───────────────────────────────────────────────────
  fix_vault_gitignore "$vault" "$mode" || return 1
  fix_vault_git_config "$vault" "$mode"
  fix_vault_upstream "$vault" "$mode" "$branch"
  fix_vault_domains_yml "$vault" "$mode" "$findings_json"
  fix_vault_permissions "$vault" "$mode"

  # The gitignore and _domains.yml fixes change tracked content. Without this
  # step those changes would sit in the index (staged, never committed),
  # invisible to the pending-commit check and to anyone looking at the repo.
  # One commit for all automatic fixes of this run, with a push, authored as
  # vigil like Vigil.Git does.
  if [ "$mode" = "apply" ]; then
    as_vigil git -C "$vault" add -- .gitignore _domains.yml 2>/dev/null || true
    if ! as_vigil git -C "$vault" diff --cached --quiet -- .gitignore _domains.yml "${OBSIDIAN_LOCAL_DIRS[@]}" 2>/dev/null; then
      # No pathspec on the commit itself: `git commit -- .obsidian` drops an
      # already-staged directory deletion (a git quirk, found empirically —
      # `git diff --cached -- .obsidian` shows it correctly, `git commit --
      # .obsidian` does not). At this point in init.sh the index contains
      # only what the automatic fixes staged, so committing everything staged
      # is safe.
      if as_vigil git -C "$vault" -c user.name=vigil -c user.email=vigil@local commit -q -m \
        "vault adoption: automatic fixes"; then
        if as_vigil git -C "$vault" remote | grep -qx "$GIT_REMOTE" &&
          as_vigil git -C "$vault" push "$GIT_REMOTE" "$branch" >/dev/null 2>&1; then
          ADOPTION_FIXES_APPLIED+=("committed automatic fixes and pushed them to ${GIT_REMOTE}")
        else
          warn "automatic fixes committed, but push failed or no '${GIT_REMOTE}' remote — please push manually."
        fi
      fi
    fi
  fi

  if [ "${#ADOPTION_FIXES_APPLIED[@]}" -gt 0 ]; then
    echo "Applied automatically (${#ADOPTION_FIXES_APPLIED[@]}):"
    for e in "${ADOPTION_FIXES_APPLIED[@]}"; do echo "  ✓ ${e}"; done
  fi
  if [ "${#ADOPTION_FIXES_PENDING[@]}" -gt 0 ]; then
    echo "Would be applied (${#ADOPTION_FIXES_PENDING[@]}):"
    for e in "${ADOPTION_FIXES_PENDING[@]}"; do echo "  ✓ ${e}"; done
    ADOPTION_TOTAL_FINDINGS=$((ADOPTION_TOTAL_FINDINGS + ${#ADOPTION_FIXES_PENDING[@]}))
  fi

  # ── Report-only findings (content, from mix vigil.vault_check) ─────────
  local b_lines
  b_lines="$(
    {
      echo "$findings_json" | jq -r '.b0_encoding[] |
        "  ! \(.path): \(.message)\n      Fix: re-save the file as UTF-8, then reload"'
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
      echo "$findings_json" | jq -r '.b5_separators[] |
        "  ! \(.path): \(.message)\n      Fix: rewrite_note (or restore the blank line by hand)"'
      echo "$findings_json" | jq -r '.b6_consolidation[] |
        "  ! \(.path): \(.headings) headings, \(.words) words" +
        (if (.duplicate_headings | length) > 0 then ", \(.duplicate_headings | length) duplicate titles" else "" end) +
        "\n      Fix: rewrite_note (mind the shrink threshold, confirm: true)"'
      echo "$findings_json" | jq -r '.b7_ignored_files[] | select(.severity == "warning") |
        "  ! \(.path): \(.message)\n      Fix: move it to <domain>/<name>.md (or projects/<project>/<name>.md), then reload"'
    } | sed '/^$/d'
  )"

  local b_count
  b_count="$(
    echo "$findings_json" | jq '
      (.b0_encoding | length) +
      (.b1_frontmatter | length) +
      (.b2_filenames | length) +
      ([.b4_domain_drift[] | select(.message | contains("is configured but does not exist in the vault"))] | length) +
      (.b5_separators | length) +
      (.b6_consolidation | length) +
      ([.b7_ignored_files[] | select(.severity == "warning")] | length)
    '
  )"

  # Unpushed commits and an extra remote are git facts, not vault content, so
  # they are checked directly here rather than in the mix task.
  local pending
  pending="$(as_vigil git -C "$vault" rev-list --count "${GIT_REMOTE}/${branch}..${branch}" 2>/dev/null || echo "0")"
  if [ "$pending" != "0" ]; then
    b_lines="${b_lines}
  ! ${pending} local commits not pushed
      Fix: git -C ${vault} push ${GIT_REMOTE} ${branch}"
    b_count=$((b_count + 1))
  fi

  if [ "$GIT_REMOTE" != "origin" ] && as_vigil git -C "$vault" remote | grep -qx origin; then
    local origin_target
    origin_target="$(as_vigil git -C "$vault" remote get-url origin 2>/dev/null || echo "?")"
    b_lines="${b_lines}
  ! Remote 'origin' points at ${origin_target} — purpose unclear, review it"
    b_count=$((b_count + 1))
  fi

  if [ "$b_count" -gt 0 ]; then
    echo "Findings (${b_count}):"
    echo "$b_lines"
    ADOPTION_TOTAL_FINDINGS=$((ADOPTION_TOTAL_FINDINGS + b_count))
  fi

  # Information: printed, never counted, so a deliberate root page (a
  # Dataview dashboard, say) does not fail --check-only forever.
  local info_lines
  info_lines="$(echo "$findings_json" | jq -r '.b7_ignored_files[] | select(.severity == "info") |
    "  i \(.path): \(.message)"')"
  if [ -n "$info_lines" ]; then
    echo "Information:"
    echo "$info_lines"
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
    echo "$findings_json" | jq -r '.b3_chunk_diff.changes[] | "  [\(.kind)] \(.path)\(if .heading then " › \(.heading)" else "" end): \(.old) -> \(.new // "ERROR")"'
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

if [ "$CHECK_ONLY" = "1" ]; then
  # Test seam: with VIGIL_INIT_TEST_STUBS=1, replace the root/vigil-user
  # checks and the hardcoded /opt/vigil/repo checkout with a caller-supplied
  # stand-in (VIGIL_TEST_REPO_ROOT), so scripts/test/check_only_test.sh can
  # exercise the mode-string plumbing below without root, a "vigil" system
  # user, or a real /opt/vigil/repo install. Scoped to this branch — the rest
  # of init.sh (Steps 1-9) always uses the real require_root/as_vigil. Unset
  # (the default), this changes nothing.
  if [ "${VIGIL_INIT_TEST_STUBS:-0}" = "1" ]; then
    require_root() { :; }
    require_command() { :; }
    as_vigil() {
      if [ "$1" = "bash" ] && [ "$2" = "-c" ] && [ -n "${VIGIL_TEST_REPO_ROOT:-}" ]; then
        local script="${3//\/opt\/vigil\/repo/$VIGIL_TEST_REPO_ROOT}"
        # Not "${@:4}": bash 3.2 joins that into one word when IFS has no
        # space, and the script's arguments are words.
        shift 3
        bash -c "$script" "$@"
      else
        "$@"
      fi
    }
  fi

  require_root ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}

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
  run_vault_adoption "$CHECK_VAULT" "check"
  RUN_RC=$?
  set -e

  if [ "$RUN_RC" -ne 0 ]; then
    exit 2
  fi
  if [ "$ADOPTION_TOTAL_FINDINGS" -gt 0 ]; then
    exit 3
  fi
  exit 0
fi


## ── Step 1 — preflight ───────────────────────────────────────────────────

step "1/9  Preflight"
require_root ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}

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

# The push safety net's units, taken from the checkout into a directory of
# root's own and judged there now, before the first mix step runs any
# dependency's code as the service account that owns the checkout; installed
# in step 7 from that copy (scripts/lib.sh, prepare_push_units).
if ! prepare_push_units "${SCRIPT_DIR}/../deploy"; then
  err "Not installing the push safety net's units."
  exit 2
fi
# The copy goes when the run ends, whichever way; the summary keeps its code.
trap 'rc=$?; rm -rf "${PUSH_UNITS_CANDIDATE:-}"; summary "$rc"' EXIT

if [ -f "$ENV_FILE" ]; then
  if [ "$FORCE" != "1" ]; then
    err "${ENV_FILE} already exists. init.sh is idempotent but will not overwrite secrets without --force."
    exit 2
  fi
  if ! confirm_destructive "Both secrets in ${ENV_FILE} will be replaced irreversibly (every other setting in it is kept). To replace one of them, use scripts/rotate_secret.sh instead."; then
    err "Aborted."
    exit 4
  fi
fi

# The public hostname, which the OAuth issuer and resource are made of. Asked
# here, before anything is created: in prod the boot check refuses an issuer
# that is not https, so there is no default a service could start on without
# one — the tunnel's hostname when setup.sh configured cloudflared, the env
# file's own under --force (Enter keeps it), and otherwise none.
HOSTNAME_DEFAULT=""
if [ -f /etc/cloudflared/config.yml ]; then
  FOUND="$(grep -oP 'hostname:\s*\K\S+' /etc/cloudflared/config.yml 2>/dev/null | head -1 || true)"
  [ -n "$FOUND" ] && HOSTNAME_DEFAULT="$FOUND"
fi
EXISTING_ISSUER="$(env_file_value VIGIL_ISSUER)"
if [ -n "$EXISTING_ISSUER" ]; then
  HOSTNAME_DEFAULT="${EXISTING_ISSUER#https://}"
fi
PUBLIC_HOST="$(ask_value "Public hostname (OAuth issuer/resource, e.g. vault.example.org)" "$HOSTNAME_DEFAULT")"
ISSUER="$(issuer_for_host "$PUBLIC_HOST")" || exit 2
RESOURCE="${ISSUER}/mcp"

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
  as_vigil git config --global init.defaultBranch "$DEFAULT_GIT_BRANCH"
fi

# Before step 2 creates or clones anything: a new vault is created on it, and
# a vault that is already there says it.
GIT_BRANCH="$(vault_branch "$VAULT")"

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

  # Renaming origin to the configured remote, local git config, .gitignore and so on all run
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
    # The answer is an argument, never spliced into a command line a shell
    # reads again: a quote in it stays part of the value.
    as_vigil env "VIGIL_INIT_DOMAINS=${DOMAINS_VALUE}" "VIGIL_GIT_BRANCH=${GIT_BRANCH}" \
      /opt/vigil/repo/scripts/init_vault.sh "$VAULT"

    NEW_REMOTE_URL="${VAULT_REMOTE_URL:-$(ask_value "Git URL for the new vault upstream" "git@github.com:<org>/vault.git")}"
    if as_vigil git -C "$VAULT" remote | grep -qx "$GIT_REMOTE"; then
      :
    else
      as_vigil git -C "$VAULT" remote add "$GIT_REMOTE" "$NEW_REMOTE_URL"
    fi
    as_vigil git -C "$VAULT" push -u "$GIT_REMOTE" "$GIT_BRANCH"
  fi
fi

# A clone checks out the remote's default branch, so the branch is read again
# now that there is one to read.
GIT_BRANCH="$(vault_branch "$VAULT")"
record_done "vault ready at ${VAULT} (remote: ${GIT_REMOTE}, branch: ${GIT_BRANCH})"

## ── Step 2b — vault adoption ─────────────────────────────────────────────
# Only for --existing-vault: a fresh --new-vault skeleton satisfies the rules
# by construction.

if [ -n "$EXISTING_VAULT_URL" ]; then
  step "2b   Vault adoption"

  ADOPTION_MODE="apply"
  [ "$DRY_RUN" = "1" ] && ADOPTION_MODE="check"

  if ! run_vault_adoption "$VAULT" "$ADOPTION_MODE"; then
    err "Vault adoption check failed."
    exit 2
  fi

  if [ "${#ADOPTION_FIXES_APPLIED[@]}" -gt 0 ]; then
    record_done "vault adoption: applied ${#ADOPTION_FIXES_APPLIED[@]} fix(es)"
  fi
  if [ "${#ADOPTION_FIXES_PENDING[@]}" -gt 0 ] || [ "$ADOPTION_TOTAL_FINDINGS" -gt "${#ADOPTION_FIXES_APPLIED[@]}" ]; then
    record_next_step "review the vault adoption findings above — they do not block init.sh, but should be looked at before going live"
  fi
fi

## ── Step 3 — secrets ─────────────────────────────────────────────────────

step "3/9  Secrets"

# Two secrets, generated apart. The consent password is typed by a human on
# the consent page; the SkillKey secret keys the HMAC whose output every
# client is handed and which ends up in chat transcripts, so it must never be
# the password — rotating either leaves the other alone
# (scripts/rotate_secret.sh). Not traced under --verbose: a trace prints the
# value an assignment is given.
if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] generate VIGIL_AUTH_PASSWORD and VIGIL_SKILLKEY_SECRET (openssl rand -base64 48 each)"
  AUTH_PASSWORD="[DRY RUN]"
  SKILLKEY_SECRET="[DRY RUN]"
else
  hide_trace
  AUTH_PASSWORD="$(generate_secret)"
  SKILLKEY_SECRET="$(generate_secret)"
  show_trace
fi
record_done "generated VIGIL_AUTH_PASSWORD (the consent password)"
record_done "generated VIGIL_SKILLKEY_SECRET (the SkillKey HMAC secret)"

## ── Step 4 — runtime config ──────────────────────────────────────────────

step "4/9  Runtime config"

# ISSUER and RESOURCE were decided in the preflight.

# existing_or <NAME> <default> — the env file's value for NAME, or the default.
existing_or() {
  local value
  value="$(env_file_value "$1")"
  printf '%s\n' "${value:-$2}"
}

# What the writing instructions tell the assistant about the vault: whose
# notes these are and which language they are written in.
VAULT_OWNER="$(ask_value "Vault owner (named in the writing instructions)" "$(existing_or VIGIL_VAULT_OWNER "the vault owner")")"
VAULT_LANGUAGE="$(ask_value "Language the notes are written in" "$(existing_or VIGIL_VAULT_LANGUAGE "English")")"
VAULT_TZ="$(ask_value "Time zone of the vault" "$(existing_or VIGIL_TZ "UTC")")"

# Two sets of lines. What this run decides — the paths, the answers above and
# the two secrets — replaces the line that sets it. The defaults are written
# only where the file does not set them, so under --force every setting the
# operator changed or added is kept, rather than the file being rewritten from
# this list.
#
# Every answer goes through env_line, which quotes what needs quoting: the
# file is read by systemd and sourced by these scripts as root, and an answer
# written bare could end its line's value and run a command there.
#
# cloudflared runs on this host and reaches vigil over loopback, so loopback
# is the peer whose CF-Connecting-IP is believed — the rate limits and the
# consent lockout then count the real client, not one bucket for everyone.
#
# The domain list is deliberately NOT written here: it is read at runtime
# from _domains.yml, never maintained as a regex or list in code. A list kept
# in two places always drifts.
ENV_DEFAULTS="$(
  cat <<'EOF'
VIGIL_PORT=4000
VIGIL_BIND=127.0.0.1
VIGIL_EXCLUDE=
VIGIL_STATE_DIR=/var/lib/vigil
VIGIL_SKILLKEY_TTL=3600
VIGIL_RATE_LIMIT_RPM=60
VIGIL_TRUSTED_PROXY_HEADER=CF-Connecting-IP
VIGIL_TRUSTED_PROXIES=127.0.0.1/32,::1/128
EOF
)"

# The secrets are in hand from here to the write; not traced.
hide_trace
ENV_DECIDED="$(
  env_line VIGIL_VAULT_PATH "$VAULT" &&
    env_line VIGIL_GIT_REMOTE "$GIT_REMOTE" &&
    env_line VIGIL_GIT_BRANCH "$GIT_BRANCH" &&
    env_line VIGIL_TZ "$VAULT_TZ" &&
    env_line VIGIL_ISSUER "$ISSUER" &&
    env_line VIGIL_RESOURCE "$RESOURCE" &&
    env_line VIGIL_AUTH_PASSWORD "$AUTH_PASSWORD" &&
    env_line VIGIL_SKILLKEY_SECRET "$SKILLKEY_SECRET" &&
    env_line VIGIL_VAULT_OWNER "$VAULT_OWNER" &&
    env_line VIGIL_VAULT_LANGUAGE "$VAULT_LANGUAGE"
)"
env_file_update "$ENV_FILE" <<<"$ENV_DECIDED"
show_trace
env_file_update "$ENV_FILE" --add-missing <<<"$ENV_DEFAULTS"
record_done "wrote runtime config to ${ENV_FILE}"

## ── Step 5 — dependency audit ────────────────────────────────────────────

step "5/9  Dependency audit"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix deps.get && mix hex.audit && mix deps.audit"
else
  # All environments' deps: `mix test` in the build step needs the test deps.
  # The verdict is the exit status — hex.audit fails on a retired package,
  # deps.audit on a known vulnerability.
  if AUDIT_OUTPUT="$(as_vigil bash -c 'cd /opt/vigil/repo && mix deps.get && mix hex.audit && mix deps.audit' 2>&1)"; then
    echo "$AUDIT_OUTPUT"
    ok "Dependency audit clean."
  else
    echo "$AUDIT_OUTPUT"
    if [ "$IGNORE_AUDIT" != "1" ]; then
      err "Dependency audit failed (retired package or known vulnerability). Override only with --ignore-audit."
      exit 2
    fi
    warn "Dependency audit failed, overridden with --ignore-audit."
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
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash -c, not here
  as_vigil bash -c 'cd /opt/vigil/repo && MIX_ENV=prod mix release --overwrite --path "$1"' \
    _ "/opt/vigil/releases/${SHORT_SHA}"
  ln -sfn "/opt/vigil/releases/${SHORT_SHA}" /opt/vigil/current
  chown -h vigil:vigil /opt/vigil/current
  ok "Built release ${SHORT_SHA}, /opt/vigil/current points at it."
fi
record_done "mix test green, release built"

## ── Step 7 — start, token bootstrap, skill bootstrap ─────────────────────

step "7/9  Start, token bootstrap, skill bootstrap"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] commit and push skills/vigil-vault-conventions.md if missing, systemctl restart vigil, wait for health, seed tokens"
else
  # The conventions skill is protected: skill_write refuses it, so it is
  # committed to the vault directly, like a hand edit, before the server is
  # there to write alongside it. An adopted vault may already carry its own,
  # tuned by its owner — that one is kept as it is.
  case "$(install_conventions_skill "$VAULT" "${SCRIPT_DIR}/templates/vigil-vault-conventions.md" "$GIT_REMOTE" "$GIT_BRANCH")" in
    kept) ok "Skill 'vigil-vault-conventions' already in the vault — kept as it is." ;;
    pushed) ok "Created skill 'vigil-vault-conventions'." ;;
    committed)
      warn "Skill 'vigil-vault-conventions' committed, but the push failed — the server pushes it with its next write, or push it by hand."
      ;;
    *)
      err "Could not commit skills/vigil-vault-conventions.md to ${VAULT}."
      exit 1
      ;;
  esac

  # restart, not start: under --force the service may be running on the
  # secrets this run replaced, and start leaves a running service as it is —
  # the new password would not be live until the next restart. On a first run
  # restart starts it. start_service clears the unit's failed-start count
  # first: a unit that gave up on an earlier attempt would refuse this one.
  start_service restart
  wait_until_healthy || exit 1

  # The tokens are in hand from here on; the stretch that uses them is not
  # traced under --verbose.
  hide_trace

  # The owner's pair lives 90 days (vigil_seed_token's default) and is printed
  # in step 9. Under --keep-token the owner keeps the tokens carried over from
  # the old container and nothing is printed, so nothing long-lived is minted:
  # verify() still needs a bearer for each scope, and those live 15 minutes,
  # like the pair update.sh mints for verify().
  if [ "$KEEP_TOKEN" = "1" ]; then
    RW_TOKEN="$(vigil_seed_token "$RESOURCE" vault 900)"
    RO_TOKEN="$(vigil_seed_token "$RESOURCE" vault:read 900)"
  else
    RW_TOKEN="$(vigil_seed_token "$RESOURCE" vault)"
    RO_TOKEN="$(vigil_seed_token "$RESOURCE" vault:read)"
  fi

  if [ "$KEEP_TOKEN" = "1" ] && [ ! -s /var/lib/vigil/oauth_tokens.dets ]; then
    warn "--keep-token: /var/lib/vigil/oauth_tokens.dets is missing or empty — no previous tokens to carry over."
    echo
    echo "  For seamless access without re-authorizing existing clients:"
    echo "  back up oauth_tokens.dets + oauth_clients.dets on the old container"
    echo "  and copy them into /var/lib/vigil/ (stop the service briefly for that)."
    echo
    record_next_step "carry over oauth_tokens.dets/oauth_clients.dets from the old container, if wanted"
  fi
  show_trace
fi
record_done "service (re)started, tokens seeded, conventions skill created"

# The push safety net: a write whose push failed is committed and answered
# `pushed: false`; vigil-push.timer pushes it within 15 minutes if no later
# write does, and a push that fails starts vigil-notify@. The cron line it
# replaces is removed if this host still has one. The units are the copies
# the preflight took and judged.
install_push_units
record_done "push safety net: vigil-push.timer enabled"

## ── Step 8 — verify() ────────────────────────────────────────────────────

step "8/9  verify()"

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] verify() would run now"
else
  hide_trace
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
  show_trace
fi

## ── Step 9 — summary and token output ────────────────────────────────────

step "9/9  Summary"

if [ "$DRY_RUN" != "1" ] && [ "$KEEP_TOKEN" != "1" ]; then
  # Printed once, to the terminal; a trace would print each a second time.
  hide_trace
  echo
  echo "  ──────────────────────────────────────────────────────"
  echo "  RW token (full access — for a client that sends it as a header, such as"
  echo "  Claude Code or Cursor; see docs/clients.md):"
  echo "  ${RW_TOKEN}"
  echo
  echo "  RO token (read-only, for read-only clients):"
  echo "  ${RO_TOKEN}"
  echo "  ──────────────────────────────────────────────────────"
  echo
  echo "  Both live 90 days. Neither value is stored anywhere — the server keeps"
  echo "  only its digest — so copy them now. List or revoke them, and every"
  echo "  other grant, with: sudo ./scripts/grants.sh list"
  echo
  show_trace
fi

ok "init.sh finished."
