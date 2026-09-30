#!/usr/bin/env bash
# Creates a fresh vigil vault. Run once by hand, never by the server.
# Idempotent: a second run only adds what is missing and overwrites nothing.
#
# Usage: scripts/init_vault.sh [<vault dir>]   (default: the current directory)
#        scripts/init_vault.sh --help
# Exit codes, as scripts/lib.sh names them: 0 success, 1 runtime error,
# 2 an option it does not know (nothing was changed).
set -euo pipefail

usage() {
  cat <<'EOF'
scripts/init_vault.sh — create a vigil vault, or add what one is missing.

  scripts/init_vault.sh [<vault dir>]   default: the current directory

Creates the domain directories, _domains.yml, .gitignore, the Obsidian
templates and a first commit; overwrites nothing that is there. The domains
are VIGIL_INIT_DOMAINS (space separated) when set, the branch
VIGIL_GIT_BRANCH.

  --help      this help
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "init_vault.sh: unknown option: $1 (see --help)" >&2
    exit 2
    ;;
esac
if [ $# -gt 1 ]; then
  echo "init_vault.sh: one vault directory at most (see --help)" >&2
  exit 2
fi

VAULT_DIR="${1:-.}"
# The Obsidian templates ship beside this script. Resolved before the cd below.
OBSIDIAN_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates/obsidian"
# shellcheck disable=SC2206 # VIGIL_INIT_DOMAINS is deliberately word-split
DOMAINS=(${VIGIL_INIT_DOMAINS:-admin gear home journal projects training} skills)

mkdir -p "$VAULT_DIR"
cd "$VAULT_DIR"

# On VIGIL_GIT_BRANCH when it is set (scripts/init.sh sets it), otherwise on
# whatever branch this machine's git starts a repository on.
if [ ! -e .git ]; then
  git init ${VIGIL_GIT_BRANCH:+-b "$VIGIL_GIT_BRANCH"}
  echo "initialized git repository in $VAULT_DIR ($(git symbolic-ref --short HEAD))"
fi

for domain in "${DOMAINS[@]}"; do
  mkdir -p "$domain"
done

if [ ! -f _domains.yml ]; then
  cat > _domains.yml <<'EOF'
admin:     "Finances, insurance, contracts, paperwork"
gear:      "Equipment: bikes, components, maintenance"
home:      "House, energy, repairs"
projects:  "Software projects. One subdirectory per project, main note = project name"
training:  "Body: planning, nutrition, recovery, metrics"
journal:
  description: "Chronological, hidden from the default search"
  naming:
    pattern: '^\d{4}-\d{2}-\d{2}\.md$'
    scope: filename
    suggestion: date
    hint: "Journal notes are named YYYY-MM-DD.md (date of the entry)"
EOF
  echo "created _domains.yml"
else
  echo "_domains.yml already exists, left untouched"
fi

if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOF'
.obsidian/
.trash/
.DS_Store
EOF
  echo "created .gitignore"
fi

mkdir -p projects/vigil
if [ ! -f projects/vigil/vigil.md ]; then
  cat > projects/vigil/vigil.md <<'EOF'
---
type: reference
---
# vigil

Elixir server that reads this vault and serves it over MCP as a memory backend.
EOF
  echo "created projects/vigil/vigil.md"
fi

# Templater templates, their user script and a Dataview dashboard, for editing
# the vault in Obsidian (docs/guide.md, "Editing by hand"). `_templates/` is not
# a domain and a root file is not a note, so vigil reads neither. A file the
# vault already has is the owner's and is never overwritten.
while IFS= read -r -d '' template; do
  relative="${template#"$OBSIDIAN_TEMPLATES"/}"
  if [ -e "$relative" ]; then
    echo "$relative already exists, left untouched"
  else
    mkdir -p "$(dirname "$relative")"
    cp "$template" "$relative"
    echo "created $relative"
  fi
done < <(find "$OBSIDIAN_TEMPLATES" -type f -print0 | sort -z)

for domain in "${DOMAINS[@]}"; do
  if [ -z "$(find "$domain" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null)" ]; then
    touch "$domain/.gitkeep"
  fi
done

if ! git diff --cached --quiet 2>/dev/null || [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "init vault" || echo "nothing to commit"
else
  echo "no changes to commit"
fi

echo
echo "Done. Now set a remote, for example:"
echo "  git remote add <remote> git@github.com:<org>/vault.git"
echo "  git push -u <remote> $(git symbolic-ref --short HEAD)"
