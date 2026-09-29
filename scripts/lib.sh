#!/usr/bin/env bash
# scripts/lib.sh — shared library for setup.sh / init.sh / update.sh.
# Sourced via `source "$(dirname "$0")/lib.sh"`; has no execution path of its
# own.
#
# Exit codes (identical across all three scripts):
#   0  success
#   1  runtime error (unexpected — anything not explicitly 2/3/4)
#   2  preflight failed — nothing was changed
#   3  acceptance (verify()) failed — state has been described
#   4  user aborted
#
# Hard rule: log/warn/err NEVER receive a variable that can contain a secret.
# Secrets are printed straight to the terminal and never to journald.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "${0%.sh}")"
SCRIPT_START="$(date +%s)"
LAST_STEP="Start"

DRY_RUN="${DRY_RUN:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
VERBOSE="${VERBOSE:-0}"

DONE_ITEMS=()
WARNINGS=()
NEXT_STEPS=()

## ── The installation layout ──────────────────────────────────────────────
#
# Every path and account the shared functions below reach for, named once.
# update.sh named its own set in #140 and the functions here kept their
# literals, which meant an override reached half the script — so update.sh had
# to refuse the overrides outside its own test. They live here now, and that
# refusal is gone.
#
# The defaults are the production install. Overriding them is what
# scripts/test/verify_test.sh and scripts/test/update_test.sh do; nothing else
# should.
#
# The *shell* names are unprefixed on purpose: `source_env_for_verify` does
# `set -a; source "$ENV_FILE"`, and /etc/vigil/env owns the VIGIL_* namespace,
# so a shell variable spelled VIGIL_STATE_DIR would be overwritten halfway
# through a run by the file it was used to find.
#
# The *override* names collide with that namespace deliberately:
# VIGIL_STATE_DIR is what init.sh writes into /etc/vigil/env and what
# runtime.exs reads, and the scripts and the application had better agree about
# where the state dir is. They are read once, here, before any env file is
# sourced.
# The directives below are on the names a sourcing script reads but this file
# does not: ShellCheck cannot see across the `source` line.
PREFIX="${VIGIL_PREFIX:-/opt/vigil}"
STATE_DIR="${VIGIL_STATE_DIR:-/var/lib/vigil}"
# shellcheck disable=SC2034 # read by the sourcing script
VAULT="${VIGIL_VAULT_DIR:-${STATE_DIR}/vault}"
# shellcheck disable=SC2034 # read by the sourcing script
ENV_FILE="${VIGIL_ENV_FILE:-/etc/vigil/env}"
# shellcheck disable=SC2034 # read by the sourcing script
UNIT_FILE="${VIGIL_UNIT_FILE:-/etc/systemd/system/vigil.service}"
# Where the push safety net's units go: beside the service's.
SYSTEMD_DIR="$(dirname "$UNIT_FILE")"
# The cron line the push safety net used to be, removed wherever it is found.
OLD_PUSH_CRON_FILE="${VIGIL_PUSH_CRON_FILE:-/etc/cron.d/vigil-push-safety-net}"

SERVICE="${VIGIL_SERVICE_NAME:-vigil}"
SERVICE_USER="${VIGIL_SERVICE_USER:-vigil}"
# shellcheck disable=SC2034 # read by the sourcing script
SERVICE_GROUP="${VIGIL_SERVICE_GROUP:-vigil}"

REPO="${PREFIX}/repo"
# shellcheck disable=SC2034 # read by the sourcing script
RELEASES="${PREFIX}/releases"
CURRENT="${PREFIX}/current"
# shellcheck disable=SC2034 # read by the sourcing script
PREVIOUS_RELEASE_FILE="${PREFIX}/.previous_release"

# What wait_until_healthy polls: vigil's own health report, unauthenticated and
# answered on this host only (docs/design.md, "The server stays in step with
# the remote"). It answers 200 once the index is loaded and the writer
# answers — a static metadata document answered as soon as the HTTP listener
# was up, whatever state the vault was in.
HEALTH_URL="${VIGIL_HEALTH_URL:-http://localhost:4000/healthz}"

## ── The vault's remote and branch ────────────────────────────────────────
#
# Every pull and push names these two, and the env file is where a deployment
# states them: VIGIL_GIT_REMOTE and VIGIL_GIT_BRANCH, read by the server and by
# every script from there rather than repeated in each. A file that does not
# state one gets the server's default (config/runtime.exs and
# Vigil.Settings.Check), and this is the one place the scripts name those.
DEFAULT_GIT_REMOTE="github"
DEFAULT_GIT_BRANCH="main"

# env_file_value <NAME> — what the env file sets NAME to, without the quotes a
# value with a space is written in and without the backslashes env_line puts
# inside them; empty when the line is missing. Read rather than sourced, so
# that asking for one value does not bring the whole VIGIL_* namespace into
# the calling shell.
#
# A caller that cannot read the file is a unit's process: systemd read it as
# root (EnvironmentFile=) and exported every line, so the value is asked of
# the environment instead — the same file, read by the one who may.
env_file_value() {
  if [ ! -r "$ENV_FILE" ]; then
    printenv "$1" 2>/dev/null || true
    return 0
  fi
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 |
    sed -e '/^".*"$/ {
      s/^"\(.*\)"$/\1/
      s/\\\([\\"$`]\)/\1/g
    }'
}

# env_line <NAME> <value> — the line that sets NAME to value in the env file,
# read back as that value by the three things that read the file: systemd's
# EnvironmentFile=, `source` in these scripts (as root), and env_file_value.
# A value of only the characters no shell or systemd treats specially is
# written bare; anything else goes in double quotes with \, ", $ and ` escaped
# — the four both bash and systemd unescape there, and the only four that
# could end the quotes or run something when root sources the file. Not
# `printf %q`: its \  and $'…' forms are bash's, and systemd and env_file_value
# would read them as different values. A value with a line break is refused:
# the file is one setting per line.
env_line() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'* | *$'\r'*)
      err "${name}: a value with a line break cannot be written to the env file."
      return 1
      ;;
  esac
  if [[ "$value" =~ ^[A-Za-z0-9_./:,+=@%-]*$ ]]; then
    printf '%s=%s\n' "$name" "$value"
    return 0
  fi
  # sed rather than ${value//…}: how a replacement's backslashes are read
  # changed between bash 3.2 and 5.2.
  printf '%s="%s"\n' "$name" "$(printf '%s' "$value" | sed 's/[\\"$`]/\\&/g')"
}

# env_file_update <path> [--add-missing] — reads NAME=value lines on stdin
# (env_line's) and puts each into the file: in place of the line that sets
# NAME, or appended when none does. Every other line — the settings nobody
# named, the comments — is kept as it was. With --add-missing a NAME the file
# already sets keeps its line, and only the others are added.
#
# On stdin rather than as arguments so that a secret is never a word a trace
# prints, and the tracing is off while the lines are in hand. Atomic, like
# write_file_atomically: a temp file in the same directory, then mv. The new
# file has the old one's mode and owner; a file that did not exist yet is
# 0600 root:root, which is what /etc/vigil/env is.
env_file_update() {
  local path="$1" add_missing=0
  [ "${2:-}" = "--add-missing" ] && add_missing=1
  hide_trace
  local line name i tmp mode owner
  local names=() lines=() written=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    name="${line%%=*}"
    if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [ "$name" = "$line" ]; then
      err "env_file_update: not a NAME=value line (for ${path})."
      show_trace
      return 1
    fi
    names+=("$name")
    lines+=("$line")
    written+=(0)
  done
  if [ "${#names[@]}" -eq 0 ]; then
    show_trace
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] set $(IFS=' ' && echo "${names[*]}") in ${path}, keeping every other line"
    show_trace
    return 0
  fi

  if [ -f "$path" ]; then
    mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
    owner="$(stat -c '%u:%g' "$path" 2>/dev/null || stat -f '%u:%g' "$path")"
  else
    mode=0600
    owner=0:0
  fi

  tmp="$(mktemp "${path}.XXXXXX")"
  if [ -f "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      name="${line%%=*}"
      for i in "${!names[@]}"; do
        [ "$line" != "$name" ] && [ "${names[$i]}" = "$name" ] || continue
        if [ "$add_missing" = "1" ]; then
          written[i]=1
          break
        fi
        # A second line setting the same name is dropped: the value is the one
        # line this call wrote, not one of two.
        if [ "${written[$i]}" = "0" ]; then
          printf '%s\n' "${lines[$i]}"
          written[i]=1
        fi
        continue 2
      done
      printf '%s\n' "$line"
    done <"$path" >"$tmp"
  fi
  for i in "${!names[@]}"; do
    [ "${written[$i]}" = "0" ] && printf '%s\n' "${lines[$i]}" >>"$tmp"
  done
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
  show_trace
}

# vault_git_remote — the remote every pull and push names.
vault_git_remote() {
  local remote
  remote="$(env_file_value VIGIL_GIT_REMOTE)"
  echo "${remote:-$DEFAULT_GIT_REMOTE}"
}

# vault_git_branch [<vault>] — the branch every pull and push names. Unset, it
# is the vault's checked-out branch when that tracks a branch on the remote,
# and the default otherwise: the rule Vigil.Settings.Check applies at boot, so
# a script and the server it serves never name two branches.
vault_git_branch() {
  local vault="${1:-$VAULT}"
  local branch head
  branch="$(env_file_value VIGIL_GIT_BRANCH)"
  if [ -z "$branch" ]; then
    head="$(as_vigil git -C "$vault" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -n "$head" ] &&
      [ "$(as_vigil git -C "$vault" config "branch.${head}.remote" 2>/dev/null || true)" = "$(vault_git_remote)" ]; then
      branch="$head"
    fi
  fi
  echo "${branch:-$DEFAULT_GIT_BRANCH}"
}

# install_conventions_skill <vault> <template> <remote> <branch> — puts the
# conventions skill into the vault as a commit of its own, named after the
# template's file name, and pushes it. Prints `kept` when the vault already
# holds one (an adopted vault's own, tuned by its owner, is never replaced),
# `pushed` when the commit reached the remote, `committed` when only the push
# failed, `failed` when there is no commit. The server refuses to write this skill through MCP (docs/design.md,
# "skills/ — one repository, two systems"), so it arrives the way a hand edit
# does: as a commit, before the server starts.
install_conventions_skill() {
  local vault="$1" template="$2" remote="$3" branch="$4"
  local rel
  rel="skills/$(basename "$template")"
  if [ -f "${vault}/${rel}" ]; then
    echo kept
    return 0
  fi
  # Called in a command substitution, where `set -e` does not reach: each step
  # says whether it worked.
  if ! { as_vigil mkdir -p "${vault}/skills" &&
    as_vigil tee "${vault}/${rel}" <"$template" >/dev/null &&
    as_vigil git -C "$vault" add -- "$rel" &&
    as_vigil git -C "$vault" -c user.name=vigil -c user.email=vigil@local -c commit.gpgsign=false \
      commit -q -m "init: ${rel}" -- "$rel"; } >/dev/null 2>&1; then
    echo failed
    return 0
  fi
  if as_vigil git -C "$vault" push -q "$remote" "$branch" >/dev/null 2>&1; then
    echo pushed
  else
    echo committed
  fi
}

# The directories Obsidian keeps inside a vault that belong to the device it
# runs on and never to the vault's history: `.obsidian/`, its settings and
# plugins, and `.trash/`, where a note deleted with the trash setting at
# "Obsidian trash" goes. Committed, Obsidian Git pushes both to every other
# clone — one device's settings, and every note ever deleted.
OBSIDIAN_LOCAL_DIRS=(.obsidian .trash)

# ignore_obsidian_dirs <vault> <mode> — mode "check" | "apply". For each of
# OBSIDIAN_LOCAL_DIRS the vault's .gitignore does not name, or the index still
# tracks, prints one line: in "check" what would be done, changing nothing; in
# "apply" what was done — the entry appended to .gitignore, the directory
# removed from the index (its files stay on disk). Prints nothing when all are
# in order. Commits nothing: what it stages is the caller's to commit.
# Returns 1 when a change fails: it is called in a command substitution, where
# `set -e` does not reach.
ignore_obsidian_dirs() {
  local vault="$1" mode="$2"
  local gitignore="${vault}/.gitignore"
  local dir needs_append is_tracked

  for dir in "${OBSIDIAN_LOCAL_DIRS[@]}"; do
    needs_append=1
    is_tracked=0
    if [ -f "$gitignore" ] && grep -qxF "${dir}/" "$gitignore"; then
      needs_append=0
    fi
    if as_vigil git -C "$vault" ls-files --error-unmatch -- "$dir" >/dev/null 2>&1; then
      is_tracked=1
    fi
    [ "$needs_append" = "0" ] && [ "$is_tracked" = "0" ] && continue

    if [ "$mode" = "check" ]; then
      echo "gitignore: add ${dir}/$(
        [ "$is_tracked" = "1" ] && echo ", and remove the already-tracked ${dir} directory from the index"
      )"
      continue
    fi

    if [ "$needs_append" = "1" ]; then
      # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c, not here
      as_vigil bash -c '
        file="$1"
        # A last byte that is not a newline survives the command substitution.
        if [ -n "$(tail -c1 "$file" 2>/dev/null)" ]; then
          printf "\n" >>"$file"
        fi
        printf "%s/\n" "$2" >>"$file"
      ' _ "$gitignore" "$dir" || return 1
    fi
    if [ "$is_tracked" = "1" ]; then
      as_vigil git -C "$vault" rm -r -q --cached -- "$dir" >/dev/null || return 1
    fi
    echo "added ${dir}/ to .gitignore$(
      [ "$is_tracked" = "1" ] && echo " (and removed the already-tracked ${dir} directory from the index)"
    )"
  done
}

## ── Logging ──────────────────────────────────────────────────────────────

_timestamp() { date +%H:%M:%S; }

_journal() {
  # logger may be missing in containers/minimal systems — never abort over it.
  logger -t "vigil-${SCRIPT_NAME}" -- "$1" 2>/dev/null || true
}

log() {
  echo "[$(_timestamp)] ▸ $1"
  _journal "$1"
}

ok() {
  echo "[$(_timestamp)] ✓ $1"
  _journal "$1"
}

warn() {
  echo "[$(_timestamp)] ! $1" >&2
  _journal "WARNING: $1"
  WARNINGS+=("$1")
}

err() {
  echo "[$(_timestamp)] ✗ $1" >&2
  _journal "ERROR: $1"
}

step() {
  LAST_STEP="$1"
  echo
  echo "── $1 ──"
}

record_done() { DONE_ITEMS+=("$1"); }
record_next_step() { NEXT_STEPS+=("$1"); }

## ── Tracing and secrets ──────────────────────────────────────────────────
#
# --verbose is `set -x`, and a trace prints every word after expansion — a
# token's, a secret's, every line of an env file that is sourced. Code that
# holds one runs between hide_trace and show_trace: the first turns tracing
# off without tracing itself, the second turns it back on if it was on. They
# nest, so a function that hides its own work can be called from a stretch
# that is hidden already, and only the outermost show_trace turns it back on.
# A secret passed to a function is traced at the call, so the call has to be
# inside the stretch too — not only the function's body.
TRACE_HIDDEN=0
TRACE_WAS_ON=0

hide_trace() {
  { local was_on=0; case "$-" in *x*) was_on=1 ;; esac; set +x; } 2>/dev/null
  if [ "$TRACE_HIDDEN" -eq 0 ]; then
    TRACE_WAS_ON="$was_on"
  fi
  TRACE_HIDDEN=$((TRACE_HIDDEN + 1))
}

show_trace() {
  if [ "$TRACE_HIDDEN" -gt 0 ]; then
    TRACE_HIDDEN=$((TRACE_HIDDEN - 1))
  fi
  if [ "$TRACE_HIDDEN" -eq 0 ] && [ "$TRACE_WAS_ON" = "1" ]; then
    set -x
  fi
  return 0
}

## ── Error trap ───────────────────────────────────────────────────────────

error_trap() {
  local rc="$1" line_no="$2"
  err "Aborted at line ${line_no} (exit ${rc}). Last step: ${LAST_STEP}."
  err "No further changes were made."
}

trap 'error_trap $? $LINENO' ERR

## ── Final summary (always runs, including on abort) ──────────────────────

# summary [rc] — the exit code comes from the caller when it has one: update.sh
# runs its own cleanup in the EXIT trap first, and hands on the code it saw.
summary() {
  local rc="${1:-$?}"
  local duration=$(( $(date +%s) - SCRIPT_START ))
  local minutes=$(( duration / 60 ))
  local seconds=$(( duration % 60 ))
  local duration_text="${minutes}m ${seconds}s"

  echo
  echo "────────────────────────────────────────"
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ ${SCRIPT_NAME}.sh finished (${duration_text})"
  else
    echo "  ✗ ${SCRIPT_NAME}.sh aborted — exit ${rc} (${duration_text})"
  fi

  if [ "${#DONE_ITEMS[@]}" -gt 0 ]; then
    echo
    echo "  Done:"
    for e in "${DONE_ITEMS[@]}"; do echo "    • ${e}"; done
  fi

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "  Warnings (${#WARNINGS[@]}):"
    for w in "${WARNINGS[@]}"; do echo "    ! ${w}"; done
  fi

  if [ "${#NEXT_STEPS[@]}" -gt 0 ]; then
    echo
    echo "  Next:"
    local i=1
    for n in "${NEXT_STEPS[@]}"; do
      echo "    ${i}. ${n}"
      i=$((i + 1))
    done
  fi
  echo "────────────────────────────────────────"
}

trap summary EXIT

## ── Helpers ──────────────────────────────────────────────────────────────

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root. Fix: sudo $0 $*"
    exit 2
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command missing: $1. Fix: apt-get install -y <matching package>."
    exit 2
  fi
}

ask_yes_no() {
  local question="$1" default="${2:-y}" response prompt
  if [ "$NON_INTERACTIVE" = "1" ]; then
    [ "$default" = "y" ]
    return
  fi
  case "$default" in
    y) prompt="[Y/n]" ;;
    n) prompt="[y/N]" ;;
    *) prompt="[y/n]" ;;
  esac
  read -r -p "${question} ${prompt} " response
  response="${response:-$default}"
  case "$response" in
    y | Y | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the chosen value on stdout: value=$(ask_value "Prompt" "default")
ask_value() {
  local prompt="$1" default="$2" value
  if [ "$NON_INTERACTIVE" = "1" ]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "${prompt} [${default}]: " value
  printf '%s\n' "${value:-$default}"
}

# Requires the word "yes" to be typed — never a bare Enter. Under
# --non-interactive this aborts rather than silently assuming consent.
confirm_destructive() {
  local description="$1" response
  warn "$description"
  if [ "$NON_INTERACTIVE" = "1" ]; then
    err "Destructive action needs interactive confirmation, not available under --non-interactive: ${description}"
    return 1
  fi
  printf 'Type exactly "yes" to continue: '
  read -r response
  [ "$response" = "yes" ]
}

# as_vigil <cmd...>  — e.g. as_vigil git -C "$VAULT" fetch
#                        or   as_vigil bash -c 'cd "$1" && mix test' _ "$REPO"
# Always starts from the service account's home (the state dir), never from the caller's
# cwd. root often runs these scripts from directories vigil cannot access
# (/root/... for instance); without an explicit cd even a plain "git
# --version" fails with "Permission denied" while stat'ing the inherited
# working directory.
#
# runuser rather than `su -c`: the command and its arguments are handed over
# as words, never joined into a string a shell parses again, so a value with
# a quote in it stays one argument. The inner bash is a fixed script that
# only changes directory; what it runs arrives as "$@". A caller that needs a
# shell of its own passes values the same way: as arguments after the
# script, never spliced into it.
as_vigil() {
  # LANG/LC_ALL: without a UTF-8 locale the BEAM (mix test, mix release)
  # treats filenames as raw bytes instead of Unicode — vault fixtures with
  # non-ASCII names then fail with "no such file or directory" on a path
  # File.ls itself just returned. C.UTF-8 is part of glibc, no locale-gen
  # needed.
  # shellcheck disable=SC2016 # $1 and $@ are expanded by the inner bash
  runuser -u "$SERVICE_USER" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    bash -c 'cd -- "$1" || exit; shift; exec "$@"' as_vigil "$STATE_DIR" "$@"
}

# run_step "<description>" -- <cmd...>  — honours --dry-run consistently.
run_step() {
  local description="$1"
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] ${description}: $*"
    return 0
  fi
  log "$description"
  "$@"
}

# write_file_atomically <path> <mode> <owner> <content>
# temp file in the same directory + mv, never a half-written file.
write_file_atomically() {
  local path="$1" mode="$2" owner="$3" content="$4" tmp
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] write file: ${path} (mode ${mode}, owner ${owner})"
    return 0
  fi
  tmp="$(mktemp "${path}.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

# generate_secret — 48 random bytes, base64: what init.sh makes both
# VIGIL_AUTH_PASSWORD and VIGIL_SKILLKEY_SECRET of, one call each, so the two
# are never the same value. 48 rather than the 32 the boot check asks the
# SkillKey secret for, and one 64-character line with no padding: nothing in
# it that systemd's EnvironmentFile or `source` would read differently.
# Printed to stdout — the caller captures it, and it never reaches log/warn/err.
generate_secret() {
  openssl rand -base64 48
}

# wait_until_healthy — waits up to 30s for the local endpoint to answer.
# Required after every systemctl start/restart, BEFORE anything tries to talk
# to the node (bearer call or `bin/vigil rpc`) — otherwise that fails with
# "noconnection"/connection refused because the BEAM has not finished booting.
wait_until_healthy() {
  local i=0
  while ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      err "Service did not become healthy within 30s. journalctl -u ${SERVICE} -n 50:"
      journalctl -u "$SERVICE" -n 50 --no-pager >&2
      return 1
    fi
    sleep 1
  done
  ok "Service is up and answering."
}

## ── The systemd unit's sandbox (shared by setup.sh/update.sh) ────────────

# The highest exposure `systemd-analyze security` may give the unit, in the
# tenths --threshold counts in: 30 is 3.0. The target is recorded in
# docs/guide.md (Security model); a unit above it is not installed.
UNIT_EXPOSURE_THRESHOLD=30

# check_unit_exposure <unit file> — scores the file itself (--offline), so a
# unit can be judged before it replaces the installed one. Returns 1, and
# prints the report's worst lines, when the score is above the threshold or
# systemd-analyze cannot score it at all.
check_unit_exposure() {
  local unit="$1" report
  if report="$(systemd-analyze security --offline=true --threshold="$UNIT_EXPOSURE_THRESHOLD" "$unit" 2>&1)"; then
    ok "systemd-analyze security: $(echo "$report" | tail -1)"
    return 0
  fi
  err "systemd-analyze security scores the unit above $((UNIT_EXPOSURE_THRESHOLD / 10)).$((UNIT_EXPOSURE_THRESHOLD % 10)):"
  echo "$report" | tail -25 >&2
  return 1
}

## ── The push safety net (shared by init.sh/update.sh) ────────────────────

# The units that make it, all from deploy/: the push itself, the timer that
# starts it, and the notification its OnFailure= starts.
PUSH_UNITS=(vigil-push.service vigil-push.timer vigil-notify@.service)

# install_push_timer <deploy dir> — installs the three units, removes the cron
# file they replace, and enables the timer. Idempotent: init.sh runs it once,
# update.sh on every update, which is how a host set up with the cron line
# moves over. The push unit is verified and its sandbox scored before any file
# is replaced, as update.sh does for the service's unit, so a unit that would
# not load or that loosened the sandbox is not installed. Returns 1 then,
# having changed nothing.
install_push_timer() {
  local source_dir="$1" candidate_dir unit analysis unexpected
  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] install ${PUSH_UNITS[*]} into ${SYSTEMD_DIR}, remove ${OLD_PUSH_CRON_FILE}, enable vigil-push.timer"
    return 0
  fi

  candidate_dir="$(mktemp -d)"
  for unit in "${PUSH_UNITS[@]}"; do
    cp "${source_dir}/${unit}" "${candidate_dir}/${unit}"
  done
  # The candidate directory first in the unit path, so OnFailure='s template
  # and the timer's service are found among the candidates. Same filter as
  # setup.sh: a missing executable is expected on a host whose code checkout
  # is not in place yet, anything else is not.
  analysis="$(SYSTEMD_UNIT_PATH="${candidate_dir}:" systemd-analyze verify \
    "${candidate_dir}/vigil-push.service" "${candidate_dir}/vigil-push.timer" 2>&1 || true)"
  unexpected="$(echo "$analysis" | grep -v -E "Executable .* does not exist|is not executable: No such file or directory|^$" || true)"
  if [ -n "$unexpected" ]; then
    rm -rf "$candidate_dir"
    err "systemd-analyze verify reports problems with the push safety net's units:"
    echo "$unexpected" >&2
    return 1
  fi
  if ! check_unit_exposure "${candidate_dir}/vigil-push.service"; then
    rm -rf "$candidate_dir"
    return 1
  fi

  for unit in "${PUSH_UNITS[@]}"; do
    install -m 0644 "${candidate_dir}/${unit}" "${SYSTEMD_DIR}/${unit}"
  done
  rm -rf "$candidate_dir"
  if [ -e "$OLD_PUSH_CRON_FILE" ]; then
    rm -f "$OLD_PUSH_CRON_FILE"
    ok "Removed the push safety net's cron file (${OLD_PUSH_CRON_FILE})."
  fi
  systemctl daemon-reload
  systemctl enable --now vigil-push.timer >/dev/null
  ok "Push safety net: vigil-push.timer enabled, failures start vigil-notify@vigil-push.service."
}

## ── Token bootstrap (shared by init.sh/update.sh) ────────────────────────

# vigil_seed_token <resource> <scope>  — prints the new token on stdout.
#
# If the service is already running this must NOT go through
# `mix vigil.seed_token`: that starts a second, standalone BEAM process which
# opens the same dets files the running Vigil.OAuth.Store already holds open.
# dets is not built for multi-process access, so the freshly seeded token ends
# up in a copy the running service never sees and every call with it fails
# with 401. Seed through `bin/vigil rpc` in the already-running node instead —
# same process, no concurrency. If the service is not running yet (first-time
# setup before the first start), the standalone path via the code checkout is
# fine and only needs fetched deps, no release binary.
#
# Both paths mint through `Vigil.OAuth.Token`, which owns the token record —
# an rpc expression that writes the map itself is how this one came to be a
# variant that carried no grant_id. The rpc expression is Elixir no compiler
# reads, so it also names the production persistence itself, the way
# `mix vigil.seed_token` does — and `Vigil.ScriptCallsTest` holds its arity to
# the one `Vigil.OAuth.Token` exports, which is how it fell behind once already.
#
# An optional third argument is the lifetime in seconds, 90 days by default —
# the same default as `mix vigil.seed_token`. The tokens init.sh prints for
# the owner keep the default; the ones init.sh --keep-token and update.sh mint
# only to run verify() get minutes, so nobody piles up live full-access tokens
# nobody holds. Any of them can be revoked early with scripts/grants.sh.
vigil_seed_token() {
  local resource="$1" scope="$2" ttl_seconds="${3:-7776000}"
  if systemctl is-active --quiet "$SERVICE"; then
    local ausdruck
    ausdruck="IO.puts(Vigil.OAuth.Token.issue_out_of_band(Vigil.OAuth.Store.over_tables(), \"${resource}\", \"${scope}\", String.to_integer(\"${ttl_seconds}\"), System.system_time(:second)))"
    as_vigil "${CURRENT}/bin/vigil" rpc "$ausdruck" | tail -1
  else
    # shellcheck disable=SC2016 # $1..$5 are expanded by the inner bash -c, not here
    as_vigil bash -c 'cd "$1" && MIX_ENV=prod mix vigil.seed_token --state-dir "$2" --resource "$3" --scope "$4" --ttl-seconds "$5"' \
      _ "$REPO" "$STATE_DIR" "$resource" "$scope" "$ttl_seconds" | tail -1
  fi
}

## ── MCP calls used by verify() ───────────────────────────────────────────

# curl_config_string <value> — value as a double-quoted string in curl's
# config syntax: \\ and \" escaped, a line break written as \n, which curl
# reads back as one.
curl_config_string() {
  printf '"%s"' "$(printf '%s\n' "$1" | sed 's/[\\"]/\\&/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# mcp_post <base_url> <token> <body> [<session_id>] [<curl option>...] — POSTs
# a JSON-RPC body to /mcp with the token as the bearer.
#
# The token, the session id and the body (which carries the SkillKey) reach
# curl as a config on its stdin (`-K -`), never as arguments: a process's
# argument vector is readable by every local user in `ps` and /proc. The
# tracing is off while they are in hand; the caller's call is its own to hide.
mcp_post() {
  local base_url="$1" token="$2" body="$3" session_id="${4:-}"
  shift 3
  [ $# -gt 0 ] && shift
  hide_trace
  local rc=0
  {
    printf 'header = %s\n' "$(curl_config_string "Authorization: Bearer ${token}")"
    if [ -n "$session_id" ]; then
      printf 'header = %s\n' "$(curl_config_string "mcp-session-id: ${session_id}")"
    fi
    printf 'data-binary = %s\n' "$(curl_config_string "$body")"
  } | curl -K - -fsS -X POST -H "Content-Type: application/json" "$@" "${base_url}/mcp" || rc=$?
  show_trace
  return "$rc"
}

# mcp_session <base_url> <token>  → prints the Mcp-Session-Id `initialize`
# issues for <token>. A tool call is made in a session, a session is bound to
# the token that initialized it, and an id the server did not issue is a 404 —
# so every call starts its own, the way a client does after a restart.
mcp_session() {
  local base_url="$1" token="$2"
  mcp_post "$base_url" "$token" \
    '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"vigil-verify","version":"0"}}}' \
    "" -o /dev/null -D - |
    tr -d '\r' | awk 'tolower($1) == "mcp-session-id:" { print $2; exit }'
}

# mcp_call <base_url> <token> <tool> [<json_args>]  → prints the raw JSON-RPC
# response on stdout.
mcp_call() {
  local base_url="$1" token="$2" tool="$3"
  # Do NOT write this as "${4:-{}}": bash closes the parameter expansion at
  # the FIRST closing brace after ":-", so a literal "{}" default is parsed as
  # "{" and a stray "}" is left dangling in the string — every call WITH a
  # real 4th argument then got a surplus "}" appended to the JSON (broken
  # JSON, answered by the server with "Parse error"). And do NOT write it as
  # `local args="$4"` either: without a 4th argument $4 is an unbound
  # parameter, and with set -u (active, see the top of this file) that kills
  # the entire shell without any error message, from inside verify().
  # "${4:-}" (empty default) avoids both traps at once. Both found empirically
  # in a Docker test.
  local args="${4:-}"
  if [ -z "$args" ]; then
    args="{}"
  fi
  local session_id
  session_id="$(mcp_session "$base_url" "$token")" || return 1
  [ -n "$session_id" ] || return 1
  mcp_post "$base_url" "$token" \
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}" \
    "$session_id"
}

# True for a tool-level isError:true AND for a JSON-RPC-level error (a parse
# error, say, if the JSON we sent was broken) — from verify()'s point of view
# both mean "that did not work".
mcp_is_error() {
  jq -e '(.result.isError == true) or (.error != null)' >/dev/null 2>&1
}

# mcp_payload <jq-filter>  — for SUCCESS responses: result.content[0].text is
# itself JSON (tool result + envelope); the filter is applied to that.
mcp_payload() {
  jq -r '.result.content[0].text' | jq -r "$1"
}

# mcp_error_text  — for ERROR responses (isError:true): result.content[0].text
# is a plain string there, NOT JSON, so a second jq parse over it (which
# mcp_payload does) fails. Hence a separate, simple function rather than
# abusing mcp_payload with a raw '.'.
mcp_error_text() {
  jq -r '.result.content[0].text // .error.message // empty'
}

## ── verify() — the central acceptance function ───────────────────────────
#
# Expects to be set: VIGIL_VAULT, VIGIL_RW_TOKEN, VIGIL_RO_TOKEN,
# VIGIL_RESOURCE (public MCP endpoint URL, e.g. https://vault.example.org/mcp),
# VIGIL_LOCAL_URL (e.g. http://localhost:4000), VIGIL_ALLOW_UNPROTECTED (0/1).
# The vault's remote and branch are read from the env file, like everywhere
# else (vault_git_remote, vault_git_branch).
# Returns 0 when every mandatory check passes, 1 otherwise.

# Each check is a function of its own: it prints its verdict and answers 0 or
# 1, and verify() is the loop over them. That is what scripts/test/verify_test.sh
# needs — the acceptance function the whole rollback decision hangs on used to
# be one 210-line block that could only be run against a real vault host, so
# the one thing nothing could test was the thing that decides whether a
# delivery stands or is rolled back.
#
# Two values are shared, and are the globals they always were: VIGIL_SKILL_KEY,
# fetched once up front, and VIGIL_TEST_DOMAIN, which check 7 discovers and
# checks 9, 10 and 12 reuse.

# The SkillKey the checks that make a deliberate write attempt (7, 10, 12)
# need. Check 9 deliberately omits it.
verify_fetch_skill_key() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "skill_read" '{"name":"vigil-vault-conventions"}' 2>/dev/null || true)"
  # sed rather than `grep -oP`: PCRE is a GNU extension, and verify() has to be
  # runnable off the vault host for scripts/test/verify_test.sh to exist at all.
  VIGIL_SKILL_KEY="$(echo "$response" | mcp_payload '.result.content' 2>/dev/null |
    sed -n 's/.*SkillKey: \([0-9a-f][0-9a-f]*\).*/\1/p' | head -1 || true)"
}

# 1. Service active
verify_service_active() {
  if systemctl is-active --quiet "$SERVICE"; then
    echo "  ✓ [1] systemctl is-active ${SERVICE}"
  else
    echo "  ✗ [1] Service is not running — journalctl -u ${SERVICE} -n 50"
    return 1
  fi
}

# 2. Public endpoint answers with 403 (Cloudflare Access)
verify_public_endpoint_protected() {
  if [ "$VIGIL_ALLOW_UNPROTECTED" = "1" ]; then
    warn "verify() [2] skipped (--allow-unprotected): Cloudflare Access check not performed."
    return 0
  fi

  local status
  status="$(curl -o /dev/null -s -w '%{http_code}' "${VIGIL_RESOURCE}" || echo "000")"
  if [ "$status" = "403" ]; then
    echo "  ✓ [2] Public endpoint answers with 403 (Cloudflare Access active)"
  else
    echo "  ✗ [2] Public endpoint answers with ${status} instead of 403."
    if [ "$status" = "401" ]; then
      echo "        401 means the request reaches Elixir — Cloudflare Access is NOT in front."
    elif [ "$status" = "200" ]; then
      echo "        200 means the endpoint is completely unprotected."
    fi
    return 1
  fi
}

# 3. Local call with a valid RW token
verify_local_call_answers() {
  if mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "current" >/dev/null 2>&1; then
    echo "  ✓ [3] Local call with a valid RW token answers"
  else
    echo "  ✗ [3] Service does not answer a valid token (${VIGIL_LOCAL_URL}/mcp)"
    return 1
  fi
}

# 4. Git remote reachable
verify_git_remote_reachable() {
  local remote
  remote="$(vault_git_remote)"
  if as_vigil git -C "$VIGIL_VAULT" ls-remote "$remote" >/dev/null 2>&1; then
    echo "  ✓ [4] git ls-remote ${remote} succeeded"
  else
    echo "  ✗ [4] git ls-remote ${remote} failed — host key or deploy key missing"
    return 1
  fi
}

# 5. reload → no pull_failed
verify_reload_pulls() {
  local reload_response pull_failed
  reload_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "reload")"
  pull_failed="$(echo "$reload_response" | mcp_payload '.result.pull_failed // empty')"
  if [ -z "$pull_failed" ]; then
    echo "  ✓ [5] reload → no pull_failed"
  else
    echo "  ✗ [5] reload reports pull_failed: ${pull_failed}"
    return 1
  fi
}

# 6. Chunk count has not dropped (warning, not an abort)
verify_chunk_count() {
  local last_chunks_file="${STATE_DIR}/.last_chunks"
  local chunks_now chunks_before=0

  # awk rather than `grep -oP ... | tail -1`: same reason as the SkillKey above,
  # and it takes the last match itself.
  # Lowercase `chunks` is what Vigil.Store logs. The pattern was `Chunks` from
  # the day it was written, so this check had never once read a count on a real
  # host: it warned "could not read the chunk count" every time, and a parser
  # regression that halved the vault went unnoticed. Both spellings are
  # accepted rather than only the right one — the log line is not this file's
  # to promise.
  chunks_now="$(journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null |
    awk 'match($0, /[0-9]+ [Cc]hunks/) {
           s = substr($0, RSTART, RLENGTH); sub(/ [Cc]hunks$/, "", s); last = s
         }
         END { if (last != "") print last }' || true)"
  if [ -f "$last_chunks_file" ]; then
    chunks_before="$(cat "$last_chunks_file")"
  fi
  if [ -n "$chunks_now" ]; then
    if [ "$chunks_now" -ge "$chunks_before" ]; then
      echo "  ✓ [6] Chunk count ${chunks_now} ≥ previous ${chunks_before}"
    else
      warn "verify() [6]: chunk count dropped from ${chunks_before} to ${chunks_now} — possible parser regression."
    fi
    if [ "$DRY_RUN" != "1" ]; then
      # As the service user: written as root (umask 077) it is the one file
      # under the state dir the next update.sh refuses on "wrong ownership".
      # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c
      as_vigil bash -c 'printf "%s\n" "$1" >"$2"' _ "$chunks_now" "$last_chunks_file"
    fi
  else
    warn "verify() [6]: could not read the chunk count from journalctl."
  fi

  # Explicitly, because this check is advisory and that is the whole point of
  # it. Inline it could not touch all_ok; as a function its status would be
  # whatever the last command left behind — the write above — so a state dir
  # that is full or read-only would roll a release back over a metric that is
  # allowed to be missing entirely.
  return 0
}

# 7. Write a test note → success (implies push, see Vigil.Store), then delete it
#
# The domain is deliberately NOT hardcoded: init.sh asks for the domain
# list interactively, so a fixed "admin/" (or "journal/") would make
# verify() fail on any vault without that domain — and check 12 below needs
# the same directory to exist physically. Instead: try every domain
# directory in the vault and take the first one where a create actually goes
# through. That also skips domains with a naming.pattern (journal/ with
# YYYY-MM-DD.md, say) that an ad-hoc test path cannot satisfy, without
# having to parse _domains.yml in bash.
verify_write_and_push() {
  local create_response delete_response
  local test_path="" last_error="no domain directories found in the vault"
  VIGIL_TEST_DOMAIN=""

  local candidate
  for candidate in $(as_vigil ls -1 "$VIGIL_VAULT" 2>/dev/null || true); do
    [ -d "${VIGIL_VAULT}/${candidate}" ] || continue
    case "$candidate" in skills | .* | _*) continue ;; esac

    local attempt_path="${candidate}/verify-test-$$.md"
    create_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
      "{\"path\":\"${attempt_path}\",\"type\":\"reference\",\"content\":\"# Verify-Test\\ntemp\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"

    if echo "$create_response" | mcp_is_error; then
      last_error="$(echo "$create_response" | mcp_error_text 2>/dev/null || echo "$create_response")"
    else
      test_path="$attempt_path"
      VIGIL_TEST_DOMAIN="$candidate"
      break
    fi
  done

  if [ -z "$test_path" ]; then
    echo "  ✗ [7] Could not write a test note in any domain. Last error: ${last_error}"
    return 1
  fi

  echo "  ✓ [7] Test note written and pushed (domain: ${VIGIL_TEST_DOMAIN})"
  delete_response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "delete_note" \
    "{\"path\":\"${test_path}\",\"confirm\":true,\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"
  if echo "$delete_response" | mcp_is_error; then
    warn "verify() [7]: test note could not be deleted again, please clean up manually: ${test_path}"
  fi
}

# 8. No pending local commits
verify_nothing_unpushed() {
  local pending branch
  branch="$(vault_git_branch "$VIGIL_VAULT")"
  pending="$(as_vigil git -C "$VIGIL_VAULT" rev-list --count "$(vault_git_remote)/${branch}..${branch}" 2>/dev/null || echo "?")"
  if [ "$pending" = "0" ]; then
    echo "  ✓ [8] No pending local commits in the vault"
  else
    echo "  ✗ [8] ${pending} local commits not pushed"
    return 1
  fi
}

# 9. Write attempt without skill_key → error
# Path and domain are irrelevant here: the SkillKey gate in Vigil.MCP.Tools
# fires before any Store validation, so the call must never reach the
# domain at all.
verify_skill_key_enforced() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN:-admin}/verify-nope-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\"}")"
  if echo "$response" | mcp_is_error && echo "$response" | mcp_error_text 2>/dev/null | grep -qi "SkillKey"; then
    echo "  ✓ [9] Writing without skill_key is rejected"
  else
    echo "  ✗ [9] SkillKey is not enforced"
    return 1
  fi
}

# 10. Write attempt with the RO token → permission error
verify_read_only_token_refused() {
  local response
  response="$(mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RO_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN:-admin}/verify-ro-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}")"
  if echo "$response" | mcp_is_error; then
    echo "  ✓ [10] Write attempt with the RO token is rejected"
  else
    echo "  ✗ [10] Role separation is not working — the RO token could write"
    return 1
  fi
}

# 11. Domain drift between _domains.yml and the actual directories
verify_no_domain_drift() {
  if journalctl -u "$SERVICE" -n 50 --no-pager 2>/dev/null | grep -q "has no entry in _domains.yml\|has no matching directory"; then
    echo "  ✗ [11] Domain drift between _domains.yml and vault directories (see journalctl -u ${SERVICE})"
    return 1
  else
    echo "  ✓ [11] No domain drift in the recent logs"
  fi
}

# 12. Provoke a write error, then check read/search still answer (the key check)
# Uses the demonstrably writable domain determined in check 7.
verify_survives_write_error() {
  if [ -z "${VIGIL_TEST_DOMAIN:-}" ]; then
    echo "  ✗ [12] skipped — check 7 found no writable domain"
    return 1
  fi

  local check12_ok=1
  local test_domain_dir="${VIGIL_VAULT}/${VIGIL_TEST_DOMAIN}"

  # The directory is made unwritable on purpose, so it has to be restored even
  # if something between here and the restore aborts. The path is expanded into
  # the trap when the trap is set, rather than read from a local when it fires:
  # a RETURN trap that names a local runs after that local is gone.
  # The mode it had, not a guessed one: a domain deliberately at 0700 or 2770
  # was silently changed to 0750 by running verify().
  local original_mode
  original_mode="$(stat -c '%a' "$test_domain_dir" 2>/dev/null ||
    stat -f '%Lp' "$test_domain_dir" 2>/dev/null || echo "750")"

  local quoted_dir
  quoted_dir="$(printf '%q' "$test_domain_dir")"
  # shellcheck disable=SC2064 # expanding now is the point — see above
  trap "chmod ${original_mode} ${quoted_dir} 2>/dev/null || true" RETURN

  chmod 0555 "$test_domain_dir" 2>/dev/null || check12_ok=0
  mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "create" \
    "{\"path\":\"${VIGIL_TEST_DOMAIN}/verify-crash-$$.md\",\"type\":\"reference\",\"content\":\"# X\\nx\",\"skill_key\":\"${VIGIL_SKILL_KEY:-}\"}" \
    >/dev/null 2>&1 || true
  chmod "$original_mode" "$test_domain_dir" 2>/dev/null || true
  trap - RETURN

  if mcp_call "$VIGIL_LOCAL_URL" "$VIGIL_RW_TOKEN" "search" '{"query":"vigil"}' >/dev/null 2>&1; then
    echo "  ✓ [12] Write error provoked, read/search still answer afterwards"
  else
    echo "  ✗ [12] Crash safety not effective — the Store dies on a write error"
    check12_ok=0
  fi

  [ "$check12_ok" = "1" ]
}

# 13. /healthz answers 200: the index is loaded and the writer answers. Asked
# of the local URL, since it answers nowhere else.
verify_healthz() {
  local status
  status="$(curl -o /dev/null -s -w '%{http_code}' "${VIGIL_LOCAL_URL}/healthz" || echo "000")"
  if [ "$status" = "200" ]; then
    echo "  ✓ [13] /healthz answers 200 — index loaded, writer answers"
  else
    echo "  ✗ [13] /healthz answers ${status} instead of 200 — curl -s ${VIGIL_LOCAL_URL}/healthz says which part is down"
    return 1
  fi
}

# The checks, in the order they run. Named here so the list is one thing rather
# than a sequence buried in a 210-line function — and so a test can ask for the
# list rather than repeat it.
VIGIL_VERIFY_CHECKS=(
  verify_service_active
  verify_public_endpoint_protected
  verify_local_call_answers
  verify_git_remote_reachable
  verify_reload_pulls
  verify_chunk_count
  verify_write_and_push
  verify_nothing_unpushed
  verify_skill_key_enforced
  verify_read_only_token_refused
  verify_no_domain_drift
  verify_survives_write_error
  verify_healthz
)

verify() {
  local all_ok=1
  local check

  # Every check hands the tokens to a function, and a trace would print them
  # at each call. The verdicts are echoed, so --verbose loses nothing it needs.
  hide_trace

  echo
  echo "=== verify() ==="

  verify_fetch_skill_key

  for check in "${VIGIL_VERIFY_CHECKS[@]}"; do
    "$check" || all_ok=0
  done

  echo
  if [ "$all_ok" = "1" ]; then
    ok "verify(): all mandatory checks passed."
  else
    err "verify(): at least one mandatory check failed."
  fi
  show_trace
  [ "$all_ok" = "1" ]
}
