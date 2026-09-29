#!/usr/bin/env bash
# scripts/setup.sh — clean Debian 13 → an installed but not yet started vigil
# service. Runs as root, once per container, idempotent.
# Does not touch secrets, vault content, or starting the service.
#
# Usage: sudo ./scripts/setup.sh [--repo-url <url>] [--skip-cloudflared]
#            [--tunnel-name <name>] [--hostname <host>]
#            [--github-ssh-port 443|22|auto]
#            [--otp-version <x> --force] [--dry-run] [--non-interactive]
#            [--verbose] [--help]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# The code repo is public: https needs no deploy key. The deploy key this
# script generates is for the vault, which is private.
REPO_URL="https://github.com/64x-lunicorn/vigil.git"
SKIP_CLOUDFLARED=0
TUNNEL_NAME="vigil"
TUNNEL_HOSTNAME=""
GITHUB_SSH_PORT="443"
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

Order: setup.sh → init.sh → update.sh (as needed, repeatable)

  --repo-url <url>        code repo (default: https://github.com/64x-lunicorn/vigil.git)
  --skip-cloudflared      set the tunnel up manually; this script skips cloudflared
  --tunnel-name <name>    Cloudflare tunnel to create or reuse (default: vigil)
  --hostname <host>       public hostname routed to vigil (asked for if omitted)
  --github-ssh-port <p>   443 (default), 22 or auto — how the service user
                          reaches GitHub over SSH; auto picks 22 when it
                          answers right now, 443 otherwise
  --otp-version <x>       override .tool-versions (only together with --force)
  --force                 allows --otp-version, otherwise has no effect
  --dry-run               log changes with [DRY RUN] instead of applying them
  --non-interactive       run through without any prompts
  --verbose               extra debug output (set -x)
  --help                  this help
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
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --skip-cloudflared)
      SKIP_CLOUDFLARED=1
      shift
      ;;
    --tunnel-name)
      TUNNEL_NAME="$2"
      shift 2
      ;;
    --hostname)
      TUNNEL_HOSTNAME="$2"
      shift 2
      ;;
    --github-ssh-port)
      GITHUB_SSH_PORT="$2"
      shift 2
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
      err "Unknown option: $1 (see --help)"
      exit 2
      ;;
  esac
done

if [ -n "$OTP_VERSION_OVERRIDE" ] && [ "$FORCE" != "1" ]; then
  err "--otp-version requires --force."
  exit 2
fi

## ── Step 1 — preflight ───────────────────────────────────────────────────

step "1/9  Preflight"
require_root ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}

if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
else
  err "/etc/os-release missing — not a recognizable Debian system."
  exit 2
fi

if [ "${VERSION_ID:-}" != "13" ] && [ "${VERSION_CODENAME:-}" != "trixie" ]; then
  err "Expected: Debian 13 (trixie). Found: ${PRETTY_NAME:-unknown}."
  exit 2
fi
ok "Debian version: ${PRETTY_NAME:-13 (trixie)}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64 | arm64) ok "Architecture: ${ARCH}" ;;
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
  err "Less than 1 GB RAM (${RAM_KB} KB)."
  exit 2
fi
ok "RAM: $((RAM_KB / 1024)) MB"

if curl -fsI --max-time 10 https://deb.debian.org >/dev/null 2>&1; then
  ok "Network: deb.debian.org reachable"
else
  err "deb.debian.org unreachable. Fix: check network/DNS/proxy."
  exit 2
fi

if curl -fsI --max-time 10 https://github.com >/dev/null 2>&1; then
  ok "Network: github.com reachable"
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

# The toolchain, held as one: every Erlang package installed here and Elixir.
# Holding only some of them let the others move on their own, so the OTP a
# release bundled depended on which package an upgrade happened to reach. An
# Erlang/OTP security update is taken deliberately, all of them together, and
# reaches the service by `update.sh --rebuild` (docs/guide.md, "Erlang/OTP
# security updates").
TOOLCHAIN_PACKAGES=(
  erlang-base erlang-dev erlang-crypto erlang-ssl erlang-public-key
  erlang-inets erlang-xmerl erlang-tools elixir
)
PACKAGES=(
  git curl ca-certificates jq openssl util-linux openssh-client gnupg
  build-essential libssl-dev
  "${TOOLCHAIN_PACKAGES[@]}"
)

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] apt-get update && apt-get install -y --no-install-recommends ${PACKAGES[*]}"
  log "[DRY RUN] apt-mark hold every Erlang package and elixir"
else
  apt-get update
  apt-get install -y --no-install-recommends "${PACKAGES[@]}"
  apt-mark hold "${TOOLCHAIN_PACKAGES[@]}" >/dev/null
fi
record_done "installed packages, held every Erlang package and elixir"

# Debian's erlang-base ships epmd.socket, enabled: systemd then listens on
# port 4369 on every interface and starts epmd for whoever connects. vigil
# runs without epmd (rel/vm.args.eex), and `-start_epmd false` closes nothing
# systemd holds open — so the socket and the service are stopped and masked,
# and nothing listens on 4369 whatever a later package upgrade enables.
if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] systemctl disable --now epmd.socket epmd.service && systemctl mask epmd.socket epmd.service"
else
  systemctl disable --now epmd.socket epmd.service >/dev/null 2>&1 || true
  systemctl mask epmd.socket epmd.service >/dev/null
  ok "epmd.socket and epmd.service stopped and masked: nothing listens on port 4369."
fi
record_done "masked epmd.socket and epmd.service"

check_tool_versions() {
  local file="/opt/vigil/repo/.tool-versions"
  if [ ! -f "$file" ]; then
    warn ".tool-versions not present yet (repo not cloned) — this check follows after step 5."
    return
  fi

  local target_elixir target_otp actual_elixir actual_otp
  target_elixir="$(awk '/^elixir/ {print $2}' "$file" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  target_otp="$(awk '/^erlang/ {print $2}' "$file" | cut -d. -f1)"
  actual_elixir="$(elixir --version 2>/dev/null | grep -oP 'Elixir \K[0-9]+\.[0-9]+' || true)"
  actual_otp="$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || true)"

  if [ -n "$OTP_VERSION_OVERRIDE" ]; then
    log "OTP version check skipped (--otp-version ${OTP_VERSION_OVERRIDE} --force)."
    return
  fi

  if [ "$target_elixir" != "$actual_elixir" ] || [ "$target_otp" != "$actual_otp" ]; then
    err "Version mismatch: .tool-versions requires Elixir ${target_elixir}.x / OTP ${target_otp}, Debian 13 provides Elixir ${actual_elixir}.x / OTP ${actual_otp}."
    err "Fix: either update .tool-versions in the repo to 'elixir ${actual_elixir}.x-otp-${actual_otp}', or use a different Debian version."
    exit 2
  fi
  ok ".tool-versions matches the installed version (Elixir ${actual_elixir}.x / OTP ${actual_otp})."
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
  install -d -m 0755 -o root -g root /opt/vigil
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
    wrong="$(find "$path" '!' -user vigil -o '!' -group vigil 2>/dev/null | head -20 || true)"
    if [ -n "$wrong" ]; then
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

case "$GITHUB_SSH_PORT" in
  auto | 22 | 443) ;;
  *)
    err "--github-ssh-port must be auto, 22 or 443 (got '${GITHUB_SSH_PORT}')."
    exit 2
    ;;
esac

# Host and port are arguments to the fixed script, never spliced into it.
tcp_reachable() {
  # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash -c
  timeout 5 bash -c '</dev/tcp/$1/$2' _ "$1" "$2" 2>/dev/null
}

# Scans <host>:<port>, refuses a key that is not GitHub's documented one, and
# records it. ssh-keyscan writes a non-22 port as [host]:port, which is the
# form ssh looks up.
trust_github_host_key() {
  local host="$1" port="$2" scan found
  scan="$(ssh-keyscan -t ed25519 -p "$port" "$host" 2>/dev/null || true)"
  if [ -z "$scan" ]; then
    err "ssh-keyscan against ${host}:${port} returned nothing."
    exit 2
  fi
  found="$(echo "$scan" | ssh-keygen -lf /dev/stdin -E sha256 2>/dev/null | awk '{print $2}')"
  if [ "$found" != "$GITHUB_ED25519_FINGERPRINT" ]; then
    err "GitHub host key fingerprint mismatch on ${host}:${port}! Expected ${GITHUB_ED25519_FINGERPRINT}, found ${found}."
    err "Refusing to trust blindly — possible MITM. Aborting, known_hosts not written."
    exit 2
  fi
  ok "GitHub ED25519 fingerprint confirmed on ${host}:${port}: ${found}"
  if ! grep -qF "$scan" "$KNOWN_HOSTS" 2>/dev/null; then
    echo "$scan" >>"$KNOWN_HOSTS"
  fi
  chown vigil:vigil "$KNOWN_HOSTS"
  chmod 0644 "$KNOWN_HOSTS"
}

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] pick GitHub SSH port (${GITHUB_SSH_PORT}), ssh-keyscan, check fingerprint against ${GITHUB_ED25519_FINGERPRINT}, write known_hosts and ~/.ssh/config"
else
  # 443 by default. Some networks block outbound 22 — or start to, for a
  # while, after a burst of SSH connections trips an IPS, which a deployment
  # produces and which a check at setup time cannot foresee (seen on the
  # reference deployment: 22 answered during setup, then timed out in
  # verify()). GitHub serves the same SSH endpoint, with the same host key,
  # on ssh.github.com:443, and 443 is open wherever HTTPS is.
  if [ "$GITHUB_SSH_PORT" = "auto" ]; then
    if tcp_reachable github.com 22; then
      GITHUB_SSH_PORT=22
    elif tcp_reachable ssh.github.com 443; then
      warn "github.com:22 is not reachable from here — using ssh.github.com:443."
      GITHUB_SSH_PORT=443
    else
      err "Neither github.com:22 nor ssh.github.com:443 is reachable."
      exit 2
    fi
  fi

  if [ "$GITHUB_SSH_PORT" = "443" ]; then
    trust_github_host_key ssh.github.com 443
    GITHUB_ROUTE="  HostName ssh.github.com
  Port 443"
  else
    trust_github_host_key github.com 22
    GITHUB_ROUTE="  Port 22"
  fi

  # Owned by this script. The keepalives bound every git fetch, pull and push
  # the service user makes — including verify()'s ls-remote and the push
  # safety net — so a connection that stalls without closing ends within a
  # minute instead of hanging.
  write_file_atomically "${SSH_DIR}/config" 0600 vigil:vigil "$(
    cat <<EOF
# Written by scripts/setup.sh (--github-ssh-port ${GITHUB_SSH_PORT}).
Host github.com
${GITHUB_ROUTE}
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 4
EOF
  )"
  ok "Service user reaches GitHub over SSH on port ${GITHUB_SSH_PORT}."
fi

if [ -f "$DEPLOY_KEY" ]; then
  log "Deploy key already exists (${DEPLOY_KEY})."
else
  run_step "generate deploy key" -- \
    as_vigil ssh-keygen -t ed25519 -N '' -C "vigil@$(hostname)" -f "$DEPLOY_KEY"
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
  echo "  Repository → Settings → Deploy keys → Add deploy key, enable 'Allow write access'."
  echo

  # ssh -T always exits 1 (GitHub offers no shell), so its status says nothing
  # and, under pipefail, would sink the whole pipeline. Read what it printed.
  SSH_GREETING="$(as_vigil ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 || true)"
  if grep -qi "successfully authenticated" <<<"$SSH_GREETING"; then
    ok "Deploy key already works (ssh -T git@github.com succeeded)."
  else
    warn "Deploy key is not registered with GitHub yet (ssh -T git@github.com fails — expected until the key is added)."
    record_next_step "add the public key from ${DEPLOY_KEY}.pub to GitHub as a deploy key with write access"
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

# Hex and rebar3 are per user, and Debian's elixir package brings neither.
# Without them the first `mix deps.get` in init.sh stops at an interactive
# "Shall I install Hex?" whose prompt goes to /dev/null — it looks hung.
if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] mix local.hex --force && mix local.rebar --force (as vigil)"
else
  as_vigil bash -c 'cd /opt/vigil/repo && mix local.hex --force --if-missing >/dev/null && mix local.rebar --force --if-missing >/dev/null'
  ok "Hex and rebar3 installed for the vigil user."
fi
record_done "Hex and rebar3 for the vigil user"

## ── Step 6 — systemd unit ────────────────────────────────────────────────

step "6/9  systemd unit"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_SOURCE="${SCRIPT_DIR}/../deploy/vigil.service"

if [ ! -f "$UNIT_SOURCE" ]; then
  err "Unit template missing: ${UNIT_SOURCE}"
  exit 2
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] copy ${UNIT_SOURCE} to /etc/systemd/system/vigil.service, daemon-reload, enable"
else
  cp "$UNIT_SOURCE" /etc/systemd/system/vigil.service
  chmod 0644 /etc/systemd/system/vigil.service

  ANALYSIS="$(systemd-analyze verify /etc/systemd/system/vigil.service 2>&1 || true)"
  UNEXPECTED="$(echo "$ANALYSIS" | grep -v -E "Executable .* does not exist|is not executable: No such file or directory|^$" || true)"
  if [ -n "$UNEXPECTED" ]; then
    err "systemd-analyze verify reports unexpected problems:"
    echo "$UNEXPECTED" >&2
    exit 2
  elif [ -n "$ANALYSIS" ]; then
    warn "systemd unit points at a release binary that is not built yet (expected before init.sh)."
  else
    ok "systemd-analyze verify: no problems."
  fi
  check_unit_exposure /etc/systemd/system/vigil.service || exit 2

  systemctl daemon-reload
  systemctl enable vigil >/dev/null
fi
record_done "installed and enabled the systemd unit (not started yet)"

## ── Step 7 — cloudflared ─────────────────────────────────────────────────

step "7/9  cloudflared"

if [ "$SKIP_CLOUDFLARED" = "1" ]; then
  warn "cloudflared skipped (--skip-cloudflared) — set the tunnel up manually."
  record_next_step "set up the Cloudflare tunnel manually (see README §4)"
elif [ "$DRY_RUN" = "1" ]; then
  log "[DRY RUN] install cloudflared, write tunnel config, enable the service"
else
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared already installed ($(cloudflared --version 2>&1 | head -1))."
  else
    # Cloudflare's signed apt repository rather than an unverified .deb: apt
    # checks the signature, and cloudflared then updates with the system.
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      >/etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y --no-install-recommends cloudflared
  fi

  if [ "$NON_INTERACTIVE" = "1" ]; then
    warn "Setting up the cloudflared tunnel needs an interactive 'cloudflared tunnel login' (browser) — skipped under --non-interactive."
    record_next_step "cloudflared tunnel login && cloudflared tunnel create ${TUNNEL_NAME}, then create /etc/cloudflared/config.yml by hand and rm /root/.cloudflared/cert.pem"
  else
    if [ ! -f /root/.cloudflared/cert.pem ]; then
      log "cloudflared tunnel login — open the printed link in a browser."
      cloudflared tunnel login || {
        warn "cloudflared tunnel login failed or was cancelled."
        record_next_step "run cloudflared tunnel login manually later"
      }
    fi

    if [ -f /root/.cloudflared/cert.pem ]; then
      TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name==$n) | .id' || true)"

      # A tunnel of this name that exists in the account but whose credentials
      # are not on this host belongs to another machine — typically the
      # container this one replaces. Reusing its ID would write a config
      # cloudflared cannot start with. Say so instead.
      if [ -n "$TUNNEL_ID" ] && [ ! -f "/root/.cloudflared/${TUNNEL_ID}.json" ]; then
        err "Tunnel '${TUNNEL_NAME}' (${TUNNEL_ID}) exists in the account, but its credentials are not on this host."
        err "Fix: stop it on the old host and 'cloudflared tunnel delete ${TUNNEL_NAME}', or re-run with --tunnel-name <new-name>."
        exit 2
      fi

      if [ -z "$TUNNEL_ID" ]; then
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name==$n) | .id' || true)"
      fi

      if [ -n "$TUNNEL_ID" ]; then
        HOSTNAME_VALUE="${TUNNEL_HOSTNAME:-$(ask_value "Hostname for the tunnel (e.g. vault.example.org)" "vault.example.org")}"
        install -d -m 0755 /etc/cloudflared
        # 127.0.0.1, not localhost: vigil binds IPv4 loopback, and localhost
        # may resolve to ::1 first.
        write_file_atomically /etc/cloudflared/config.yml 0644 root:root "$(
          cat <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${HOSTNAME_VALUE}
    service: http://127.0.0.1:4000
  - service: http_status:404
EOF
        )"
        # The DNS record is what makes the hostname reach this tunnel. An
        # existing record for the hostname (the old tunnel's) is replaced.
        DNS_ROUTED=0
        if cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$HOSTNAME_VALUE"; then
          DNS_ROUTED=1
          ok "DNS: ${HOSTNAME_VALUE} → tunnel '${TUNNEL_NAME}'."
        else
          warn "Could not route ${HOSTNAME_VALUE} to tunnel '${TUNNEL_NAME}'."
          record_next_step "cloudflared tunnel route dns --overwrite-dns ${TUNNEL_NAME} ${HOSTNAME_VALUE}"
        fi
        cloudflared service install >/dev/null 2>&1 || true
        systemctl enable --now cloudflared >/dev/null 2>&1 || true
        ok "Configured cloudflared tunnel '${TUNNEL_NAME}' (hostname ${HOSTNAME_VALUE}, no catch-all)."

        # cert.pem is the account certificate `cloudflared tunnel login` left:
        # it creates, routes and deletes tunnels anywhere in the Cloudflare
        # account, and nothing on this host needs it once the tunnel exists —
        # the tunnel runs on its own credentials file. Removed once the DNS
        # route is in place; kept, with a next step saying to remove it, while
        # the route still has to be made by hand. Running this step again logs
        # in again.
        if [ "$DNS_ROUTED" = "1" ]; then
          rm -f /root/.cloudflared/cert.pem
          ok "Removed the account certificate /root/.cloudflared/cert.pem (the tunnel runs on /root/.cloudflared/${TUNNEL_ID}.json)."
        else
          warn "The account certificate /root/.cloudflared/cert.pem is still on this host."
          record_next_step "once the DNS route is made: rm /root/.cloudflared/cert.pem (it controls every tunnel in the Cloudflare account)"
        fi
      else
        warn "Could not determine the tunnel ID — tunnel config not written."
        record_next_step "check cloudflared tunnel list, create /etc/cloudflared/config.yml by hand, then rm /root/.cloudflared/cert.pem"
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
record_next_step "configure Cloudflare Access (see docs/clients.md) before running init.sh"

## ── Step 9 — summary ─────────────────────────────────────────────────────

step "9/9  Summary"
record_next_step "sudo ./scripts/init.sh --new-vault  (or --existing-vault <git-url>)"
ok "setup.sh finished."
