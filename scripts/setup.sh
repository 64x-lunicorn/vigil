#!/usr/bin/env bash
# scripts/setup.sh — clean Debian 13 → an installed but not yet started vigil
# service. Runs as root, once per container, idempotent.
# Does not touch secrets, vault content, or starting the service.
#
# Nutzung: sudo ./scripts/setup.sh [--repo-url <url>] [--skip-cloudflared]
#            [--otp-version <x> --force] [--dry-run] [--non-interactive]
#            [--verbose] [--help]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO_URL="git@github.com:Lunicorn-lab/vigil.git"
SKIP_CLOUDFLARED=0
OTP_VERSION_OVERRIDE=""
FORCE=0

# GitHub's ED25519 host key fingerprint, publicly documented at
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# — check it against that page before using this script,
# in case GitHub ever rotates its host keys (last done in 2023).
GITHUB_ED25519_FINGERPRINT="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

usage() {
  cat <<'EOF'
scripts/setup.sh — Debian 13 → an installed but not started vigil service.

Reihenfolge: setup.sh → init.sh → update.sh (bei Bedarf, wiederholt)

  --repo-url <url>       Code-Repo (Default: git@github.com:Lunicorn-lab/vigil.git)
  --skip-cloudflared      set the tunnel up manually; this script skips cloudflared
  --otp-version <x>       override .tool-versions (only together with --force)
  --force                 erlaubt --otp-version, sonst ohne Wirkung
  --dry-run               log changes with [DRY RUN] instead of applying them
  --non-interactive       run through without any prompts
  --verbose               extra debug output (set -x)
  --help                  diese Hilfe
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
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --skip-cloudflared)
      SKIP_CLOUDFLARED=1
      shift
      ;;
    --otp-version)
      OTP_VERSION_OVERRIDE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
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
      err "Unbekannte Option: $1 (siehe --help)"
      exit 2
      ;;
  esac
done

if [ -n "$OTP_VERSION_OVERRIDE" ] && [ "$FORCE" != "1" ]; then
  err "--otp-version verlangt --force."
  exit 2
fi

## ── Step 1 — preflight ───────────────────────────────────────────────────

step "1/9  Preflight"
require_root "$@"

if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
else
  err "/etc/os-release missing — not a recognizable Debian system."
  exit 2
fi

if [ "${VERSION_ID:-}" != "13" ] && [ "${VERSION_CODENAME:-}" != "trixie" ]; then
  err "Erwartet: Debian 13 (trixie). Gefunden: ${PRETTY_NAME:-unbekannt}."
  exit 2
fi
ok "Debian-Version: ${PRETTY_NAME:-13 (trixie)}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64 | arm64) ok "Architektur: ${ARCH}" ;;
  *)
    err "Unsupported architecture: ${ARCH} (expected amd64 or arm64)."
    exit 2
    ;;
esac

FREE_KB="$(df --output=avail -k / | tail -1 | tr -d ' ')"
if [ "$FREE_KB" -lt 2097152 ]; then
  err "Less than 2 GB free on / (${FREE_KB} KB). Fix: free up space or grow the disk."
  exit 2
fi
ok "Free space on /: $((FREE_KB / 1024)) MB"

RAM_KB="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
if [ "$RAM_KB" -lt 1048576 ]; then
  err "Weniger als 1 GB RAM (${RAM_KB} KB)."
  exit 2
fi
ok "RAM: $((RAM_KB / 1024)) MB"

if curl -fsI --max-time 10 https://deb.debian.org >/dev/null 2>&1; then
  ok "Netz: deb.debian.org erreichbar"
else
  err "deb.debian.org unreachable. Fix: check network/DNS/proxy."
  exit 2
fi

if curl -fsI --max-time 10 https://github.com >/dev/null 2>&1; then
  ok "Netz: github.com erreichbar"
else
  err "github.com unreachable. Fix: check network/DNS/proxy."
  exit 2
fi

# Without a UTF-8 locale the BEAM treats filenames as raw bytes rather than
# Unicode — vault notes with non-ASCII characters in their name then fail
# with "no such file or directory" on a path File.ls itself just
# returned. C.UTF-8 has been part of glibc since Debian 9, so no locale-gen is
# needed — but without this check it only surfaces at the first write attempt
# with a misleading error, rather than during preflight.
if locale -a 2>/dev/null | grep -qi '^C\.utf8$\|^C\.UTF-8$'; then
  ok "UTF-8 locale (C.UTF-8) available."
else
  err "No UTF-8 locale available (C.UTF-8 missing). Fix: apt-get install -y locales && locale-gen C.UTF-8"
  exit 2
fi

if [ -f /etc/vigil/env ]; then
  log "This container is already initialized. setup.sh is idempotent and changes no secrets."
fi

record_done "preflight passed"

## ── Step 2 — packages ────────────────────────────────────────────────────

step "2/9  Install packages"

PACKAGES=(
  git curl ca-certificates jq openssl util-linux openssh-client
  build-essential libssl-dev
  erlang-base erlang-dev erlang-crypto erlang-ssl erlang-public-key
  erlang-inets erlang-xmerl erlang-tools elixir
)

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] apt-get update && apt-get install -y --no-install-recommends ${PACKAGES[*]}"
else
  apt-get update
  apt-get install -y --no-install-recommends "${PACKAGES[@]}"
  apt-mark hold erlang-base erlang-dev elixir >/dev/null
fi
record_done "installed and pinned packages (erlang-base, erlang-dev, elixir)"

check_tool_versions() {
  local file="/opt/vigil/repo/.tool-versions"
  if [ ! -f "$file" ]; then
    warn ".tool-versions not present yet (repo not cloned) — this check follows after step 5."
    return
  fi

  local ziel_elixir ziel_otp actual_elixir actual_otp
  ziel_elixir="$(awk '/^elixir/ {print $2}' "$file" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  ziel_otp="$(awk '/^erlang/ {print $2}' "$file" | cut -d. -f1)"
  actual_elixir="$(elixir --version 2>/dev/null | grep -oP 'Elixir \K[0-9]+\.[0-9]+' || true)"
  actual_otp="$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || true)"

  if [ -n "$OTP_VERSION_OVERRIDE" ]; then
    log "OTP version check skipped (--otp-version ${OTP_VERSION_OVERRIDE} --force)."
    return
  fi

  if [ "$ziel_elixir" != "$actual_elixir" ] || [ "$ziel_otp" != "$actual_otp" ]; then
    err "Versions-Mismatch: .tool-versions verlangt Elixir ${ziel_elixir}.x / OTP ${ziel_otp}, Debian 13 liefert Elixir ${actual_elixir}.x / OTP ${actual_otp}."
    err "Fix: either update .tool-versions in the repo to 'elixir ${actual_elixir}.x-otp-${actual_otp}', or use a different Debian version."
    exit 2
  fi
  ok ".tool-versions passt zur installierten Version (Elixir ${actual_elixir}.x / OTP ${actual_otp})."
}

## ── Step 3 — system user and directories ─────────────────────────────────

step "3/9  System user and directories"

if id vigil >/dev/null 2>&1; then
  log "User 'vigil' already exists."
else
  run_step "create user 'vigil'" -- \
    useradd --system --home-dir /var/lib/vigil --shell /usr/sbin/nologin --create-home vigil
fi

if [ "$DRY_RUN" != "1" ]; then
  install -d -m 0755 -o root -o root /opt/vigil
  install -d -m 0755 -o vigil -g vigil /opt/vigil/repo
  install -d -m 0755 -o vigil -g vigil /opt/vigil/releases
  install -d -m 0750 -o vigil -g vigil /var/lib/vigil
  install -d -m 0750 -o vigil -g vigil /var/lib/vigil/vault
  install -d -m 0700 -o root -g root /etc/vigil
else
  log "[DRY RUN] create/fix directories and permissions"
fi

# No directory under /opt/vigil or /var/lib/vigil may ever belong to another
# user (an outage was caused by a directory created under a different user via
# git mv) — check and fix recursively rather than failing on it.
for path in /opt/vigil/repo /opt/vigil/releases /var/lib/vigil; do
  if [ -d "$path" ]; then
    falsch="$(find "$path" '!' -user vigil -o '!' -group vigil 2>/dev/null | head -20 || true)"
    if [ -n "$falsch" ]; then
      warn "Wrong ownership found under ${path}, fixing it (chown -R vigil:vigil)."
      run_step "fix ownership of ${path}" -- chown -R vigil:vigil "$path"
    fi
  fi
done

record_done "system user and directories in place"

## ── Step 4 — SSH identity of the service user ────────────────────────────

step "4/9  SSH identity of the service user"

SSH_DIR="/var/lib/vigil/.ssh"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
DEPLOY_KEY="${SSH_DIR}/id_ed25519"

if [ "$DRY_RUN" != "1" ]; then
  install -d -m 0700 -o vigil -g vigil "$SSH_DIR"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] ssh-keyscan github.com, check fingerprint against ${GITHUB_ED25519_FINGERPRINT}, write known_hosts"
else
  SCAN="$(ssh-keyscan -t ed25519 github.com 2>/dev/null || true)"
  if [ -z "$SCAN" ]; then
    err "ssh-keyscan against github.com returned nothing."
    exit 2
  fi
  FOUND="$(echo "$SCAN" | ssh-keygen -lf /dev/stdin -E sha256 2>/dev/null | awk '{print $2}')"
  if [ "$FOUND" != "$GITHUB_ED25519_FINGERPRINT" ]; then
    err "GitHub-Hostkey-Fingerprint weicht ab! Erwartet ${GITHUB_ED25519_FINGERPRINT}, gefunden ${FOUND}."
    err "Refusing to trust blindly — possible MITM. Aborting, known_hosts not written."
    exit 2
  fi
  ok "GitHub ED25519 fingerprint confirmed: ${FOUND}"
  if ! grep -qF "$SCAN" "$KNOWN_HOSTS" 2>/dev/null; then
    echo "$SCAN" >>"$KNOWN_HOSTS"
    chown vigil:vigil "$KNOWN_HOSTS"
    chmod 0644 "$KNOWN_HOSTS"
  fi
fi

if [ -f "$DEPLOY_KEY" ]; then
  log "Deploy-Key existiert bereits (${DEPLOY_KEY})."
else
  run_step "Deploy-Key erzeugen" -- \
    su -s /bin/bash -c "ssh-keygen -t ed25519 -N '' -C 'vigil@$(hostname)' -f ${DEPLOY_KEY}" vigil
  if [ "$DRY_RUN" != "1" ]; then
    chmod 0700 "$SSH_DIR"
    chmod 0600 "$DEPLOY_KEY"
    chown vigil:vigil "$SSH_DIR" "$DEPLOY_KEY" "${DEPLOY_KEY}.pub"
  fi
fi

if [ "$DRY_RUN" != "1" ] && [ -f "${DEPLOY_KEY}.pub" ]; then
  echo
  echo "  Public key (add to GitHub as a deploy key with write access):"
  echo "  ────────────────────────────────────────"
  cat "${DEPLOY_KEY}.pub"
  echo "  ────────────────────────────────────────"
  echo "  Repository → Settings → Deploy keys → Add deploy key, 'Allow write access' aktivieren."
  echo

  if as_vigil ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
    ok "Deploy-Key funktioniert bereits (ssh -T git@github.com erfolgreich)."
  else
    warn "Deploy key is not registered with GitHub yet (ssh -T git@github.com fails — expected until the key is added)."
    record_next_step "Public Key aus ${DEPLOY_KEY}.pub bei GitHub als Deploy-Key mit Schreibrechten hinterlegen"
  fi
fi

record_done "set up the service user's SSH identity"

## ── Step 5 — clone the code repo ─────────────────────────────────────────

step "5/9  Clone the code repo"

if [ -d /opt/vigil/repo/.git ]; then
  log "Repo already exists at /opt/vigil/repo — fetching instead of cloning."
  run_step "git fetch" -- as_vigil git -C /opt/vigil/repo fetch --all
  as_vigil git -C /opt/vigil/repo status --short || true
else
  run_step "clone repo (${REPO_URL})" -- as_vigil git clone "$REPO_URL" /opt/vigil/repo
fi

check_tool_versions
record_done "code repo at /opt/vigil/repo"

## ── Step 6 — systemd unit ────────────────────────────────────────────────

step "6/9  systemd unit"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_SOURCE="${SCRIPT_DIR}/../deploy/vigil.service"

if [ ! -f "$UNIT_SOURCE" ]; then
  err "Unit-Vorlage fehlt: ${UNIT_SOURCE}"
  exit 2
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] copy ${UNIT_SOURCE} to /etc/systemd/system/vigil.service, daemon-reload, enable"
else
  cp "$UNIT_SOURCE" /etc/systemd/system/vigil.service
  chmod 0644 /etc/systemd/system/vigil.service

  ANALYSE="$(systemd-analyze verify /etc/systemd/system/vigil.service 2>&1 || true)"
  UNERWARTET="$(echo "$ANALYSE" | grep -v -E "Executable .* does not exist|is not executable: No such file or directory|^$" || true)"
  if [ -n "$UNERWARTET" ]; then
    err "systemd-analyze verify meldet unerwartete Probleme:"
    echo "$UNERWARTET" >&2
    exit 2
  elif [ -n "$ANALYSE" ]; then
    warn "systemd unit points at a release binary that is not built yet (expected before init.sh)."
  else
    ok "systemd-analyze verify: no problems."
  fi

  systemctl daemon-reload
  systemctl enable vigil >/dev/null
fi
record_done "installed and enabled the systemd unit (not started yet)"

## ── Step 7 — cloudflared ─────────────────────────────────────────────────

step "7/9  cloudflared"

if [ "$SKIP_CLOUDFLARED" = "1" ]; then
  warn "cloudflared skipped (--skip-cloudflared) — set the tunnel up manually."
  record_next_step "Cloudflare Tunnel manuell einrichten (siehe README §4)"
elif [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] install cloudflared, write tunnel config, enable the service"
else
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared bereits installiert ($(cloudflared --version 2>&1 | head -1))."
  else
    DEB_ARCH="$ARCH"
    TMP_DEB="$(mktemp --suffix=.deb)"
    curl -fsSL -o "$TMP_DEB" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb"
    dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    warn "Setting up the cloudflared tunnel needs an interactive 'cloudflared tunnel login' (browser) — skipped under --non-interactive."
    record_next_step "cloudflared tunnel login && cloudflared tunnel create vigil, dann /etc/cloudflared/config.yml von Hand anlegen"
  else
    if [ ! -f /root/.cloudflared/cert.pem ]; then
      log "cloudflared tunnel login — open the printed link in a browser."
      cloudflared tunnel login || {
        warn "cloudflared tunnel login fehlgeschlagen oder abgebrochen."
        record_next_step "cloudflared tunnel login manuell nachholen"
      }
    fi

    if [ -f /root/.cloudflared/cert.pem ]; then
      if ! cloudflared tunnel list 2>/dev/null | grep -q '\bvigil\b'; then
        cloudflared tunnel create vigil
      fi
      TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r '.[] | select(.name=="vigil") | .id' || true)"

      if [ -n "$TUNNEL_ID" ]; then
        HOSTNAME_VALUE="$(ask_value "Hostname for the tunnel (e.g. vault.example.org)" "vault.example.org")"
        install -d -m 0755 /etc/cloudflared
        write_file_atomically /etc/cloudflared/config.yml 0644 root:root "$(
          cat <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${HOSTNAME_VALUE}
    service: http://localhost:4000
  - service: http_status:404
EOF
        )"
        cloudflared service install >/dev/null 2>&1 || true
        systemctl enable cloudflared >/dev/null 2>&1 || true
        ok "Configured cloudflared tunnel 'vigil' (hostname ${HOSTNAME_VALUE}, no catch-all)."
      else
        warn "Could not determine the tunnel ID — tunnel config not written."
        record_next_step "check cloudflared tunnel list, create /etc/cloudflared/config.yml by hand"
      fi
    fi
  fi
fi
record_done "finished the cloudflared step (see warnings for manual parts still open)"

## ── Step 8 — Cloudflare Access ───────────────────────────────────────────

step "8/9  Cloudflare Access (instructions)"

cat <<'EOF'

  Cloudflare Access is NOT automated — please set it up manually:

    1. dash.cloudflare.com → Zero Trust → Access → Applications → Add an application
    2. Type: Self-hosted
    3. Application domain: the tunnel hostname configured above
    4. Add a policy of type "Service Auth"
    5. Create a service token, note the client ID and client secret
       (used by the MCP client, not by vigil itself)

  init.sh aborts hard at the end if the public endpoint does not answer with
  403 — that is, for as long as Access is not working.

EOF
warn "Cloudflare Access is not configured yet (manual step)."
record_next_step "configure Cloudflare Access (see the README) before running init.sh"

## ── Step 9 — summary ─────────────────────────────────────────────────────

step "9/9  Summary"
record_next_step "sudo ./scripts/init.sh --new-vault  (oder --existing-vault <git-url>)"
ok "setup.sh finished."
