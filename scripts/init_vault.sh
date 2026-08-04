#!/usr/bin/env bash
# Creates a fresh vigil vault. Run once by hand, never by the server.
# Idempotent: a second run only adds what is missing and overwrites nothing.
set -euo pipefail

VAULT_DIR="${1:-.}"
# shellcheck disable=SC2206 # VIGIL_INIT_DOMAINS is deliberately word-split
DOMAINS=(${VIGIL_INIT_DOMAINS:-admin gear home journal projects training} skills)

mkdir -p "$VAULT_DIR"
cd "$VAULT_DIR"

if [ ! -d .git ]; then
  git init -b main
  echo "initialized git repository in $VAULT_DIR (main)"
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
echo "  git remote add origin git@github.com:<org>/vault.git"
echo "  git push -u origin main"
