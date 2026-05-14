#!/usr/bin/env bash
# Ghostberry one-shot installer.
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
#
# What it does (idempotent):
#   1. Verifies Debian/Raspberry Pi OS on aarch64 or x86_64
#   2. Enables memory + swap cgroups in /boot firmware cmdline (if Pi)
#   3. Ensures ≥ 2 GB swap
#   4. Installs Docker (official convenience script) + git + openssl
#   5. Clones/updates ghostberry into ${INSTALL_DIR:-/opt/ghostberry}
#   6. Runs setup.sh interactively (prompts for domain + tunnel token)
#   7. Installs the ghostberry.service systemd unit
#   8. Installs a daily cron job for backups
#   9. (with --harden) installs ufw + unattended-upgrades, locks down SSH
#  10. docker compose up -d, polls Ghost health
#
# Env knobs:
#   INSTALL_DIR        target directory (default /opt/ghostberry)
#   GHOSTBERRY_REPO    owner/name (default dm807cam/ghostberry)
#   GHOSTBERRY_REF     git ref     (default main)
#   GHOST_URL          skip the domain prompt
#   CLOUDFLARE_TUNNEL_TOKEN  skip the token prompt
#   NONINTERACTIVE=1   refuse any prompting
#   GHOSTBERRY_USER    user account to own the install (default: invoking user)
#   SKIP_DOCKER=1      assume docker is already installed and working
#   SKIP_HEALTH=1      don't wait for Ghost to become healthy at the end
#   HARDEN=1           same as passing --harden

set -euo pipefail

# ----------------------------------------------------------------------------
# Args & defaults
# ----------------------------------------------------------------------------
HARDEN="${HARDEN:-0}"
for arg in "$@"; do
  case "${arg}" in
    --harden) HARDEN=1 ;;
    --no-health) SKIP_HEALTH=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

INSTALL_DIR="${INSTALL_DIR:-/opt/ghostberry}"
GHOSTBERRY_REPO="${GHOSTBERRY_REPO:-dm807cam/ghostberry}"
GHOSTBERRY_REF="${GHOSTBERRY_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GHOSTBERRY_REPO}/${GHOSTBERRY_REF}"
GIT_URL="https://github.com/${GHOSTBERRY_REPO}.git"

# Resolve the user that should own the install. When run via sudo we want
# the original user, not root.
GHOSTBERRY_USER="${GHOSTBERRY_USER:-${SUDO_USER:-${USER:-root}}}"
if ! id -u "${GHOSTBERRY_USER}" &>/dev/null; then
  GHOSTBERRY_USER=root
fi

log()   { printf '\033[1;32m▶\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m✖\033[0m %s\n' "$*" >&2; exit 1; }
have()  { command -v "$1" &>/dev/null; }

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  fail "Run with sudo:  curl -fsSL ${RAW_BASE}/install.sh | sudo bash"
fi

OS_ID=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-} ${ID_LIKE:-}"
fi
case "${OS_ID}" in
  *debian*|*raspbian*|*ubuntu*) ;;
  *) warn "Untested on '${OS_ID:-unknown}'. Ghostberry targets Raspberry Pi OS / Debian / Ubuntu." ;;
esac

ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64|x86_64|amd64) ;;
  armv7l) warn "32-bit ARM detected. Ghost + MySQL 8 require 64-bit. Reflash with the 64-bit image." ;;
  *) warn "Unrecognized arch '${ARCH}'. Proceeding anyway." ;;
esac

# ----------------------------------------------------------------------------
# 1. Memory cgroups (Raspberry Pi only)
# ----------------------------------------------------------------------------
enable_pi_cgroups() {
  local cmdline=""
  for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "${f}" ]] && cmdline="${f}" && break
  done
  [[ -z "${cmdline}" ]] && return 0

  local changed=0
  local line
  line="$(tr -d '\n' < "${cmdline}")"
  if ! grep -q 'cgroup_enable=memory' "${cmdline}"; then
    line="${line} cgroup_enable=memory"; changed=1
  fi
  if ! grep -q 'cgroup_memory=1' "${cmdline}"; then
    line="${line} cgroup_memory=1"; changed=1
  fi
  if (( changed )); then
    cp -a "${cmdline}" "${cmdline}.ghostberry.bak"
    printf '%s\n' "${line}" > "${cmdline}"
    warn "Enabled memory cgroups in ${cmdline} — reboot required for container memory limits to take effect."
    NEEDS_REBOOT=1
  fi
}
log "Checking Raspberry Pi memory cgroups"
enable_pi_cgroups

# ----------------------------------------------------------------------------
# 2. Swap
# ----------------------------------------------------------------------------
ensure_swap() {
  local total_kb
  total_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if (( total_kb >= 2 * 1024 * 1024 )); then
    return 0
  fi
  if [[ -f /etc/dphys-swapfile ]]; then
    log "Bumping dphys-swapfile to 2048 MB"
    sed -i 's/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
    dphys-swapfile swapoff || true
    dphys-swapfile setup
    dphys-swapfile swapon
  else
    log "Adding 2 GB /swapfile"
    if [[ ! -f /swapfile ]]; then
      fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
    fi
    swapon /swapfile || true
    if ! grep -q '^/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi
}
ensure_swap

# ----------------------------------------------------------------------------
# 3. Packages: docker, git, openssl, curl
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl git openssl jq tzdata

if [[ "${SKIP_DOCKER:-0}" != "1" ]] && ! have docker; then
  log "Installing Docker (official convenience script)"
  curl -fsSL https://get.docker.com | sh
fi

# Compose v2 plugin is bundled with modern Docker installs. Sanity-check.
if ! docker compose version &>/dev/null; then
  log "Installing docker-compose-plugin"
  apt-get install -y --no-install-recommends docker-compose-plugin || \
    fail "docker compose v2 not available — install it manually and rerun."
fi

# Add the target user to the docker group.
if [[ "${GHOSTBERRY_USER}" != "root" ]]; then
  if id -nG "${GHOSTBERRY_USER}" | tr ' ' '\n' | grep -qx docker; then :; else
    log "Adding ${GHOSTBERRY_USER} to docker group"
    usermod -aG docker "${GHOSTBERRY_USER}"
  fi
fi

systemctl enable --now docker

# ----------------------------------------------------------------------------
# 4. Source: clone or update
# ----------------------------------------------------------------------------
log "Fetching ghostberry into ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
chown "${GHOSTBERRY_USER}":"${GHOSTBERRY_USER}" "${INSTALL_DIR}"

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  sudo -u "${GHOSTBERRY_USER}" git -C "${INSTALL_DIR}" fetch --depth=1 origin "${GHOSTBERRY_REF}"
  sudo -u "${GHOSTBERRY_USER}" git -C "${INSTALL_DIR}" reset --hard "origin/${GHOSTBERRY_REF}"
else
  # If the dir already has files (e.g. running this script from inside a clone),
  # don't blow them away — just initialize.
  if compgen -G "${INSTALL_DIR}/*" > /dev/null; then
    warn "${INSTALL_DIR} is not empty and not a git repo; using existing contents."
  else
    sudo -u "${GHOSTBERRY_USER}" git clone --depth=1 --branch "${GHOSTBERRY_REF}" "${GIT_URL}" "${INSTALL_DIR}"
  fi
fi

cd "${INSTALL_DIR}"
chmod +x setup.sh scripts/*.sh 2>/dev/null || true

# ----------------------------------------------------------------------------
# 5. Configure (.env)
# ----------------------------------------------------------------------------
log "Configuring .env"
sudo -u "${GHOSTBERRY_USER}" \
  env GHOST_URL="${GHOST_URL:-}" \
      CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}" \
      MAIL_HOST="${MAIL_HOST:-}" \
      MAIL_PORT="${MAIL_PORT:-587}" \
      MAIL_USER="${MAIL_USER:-}" \
      MAIL_PASSWORD="${MAIL_PASSWORD:-}" \
      MAIL_FROM="${MAIL_FROM:-}" \
      NONINTERACTIVE="${NONINTERACTIVE:-0}" \
  ./setup.sh

# ----------------------------------------------------------------------------
# 6. systemd unit
# ----------------------------------------------------------------------------
log "Installing ghostberry.service"
sed "s|/opt/ghostberry|${INSTALL_DIR}|g" "${INSTALL_DIR}/ghostberry.service" \
  > /etc/systemd/system/ghostberry.service
systemctl daemon-reload
systemctl enable ghostberry.service

# ----------------------------------------------------------------------------
# 7. Cron — daily backup at 03:17 (jittered)
# ----------------------------------------------------------------------------
log "Installing daily backup cron"
CRON_FILE=/etc/cron.d/ghostberry-backup
cat > "${CRON_FILE}" <<EOF
# Ghostberry — daily encrypted backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * ${GHOSTBERRY_USER} cd ${INSTALL_DIR} && ./scripts/backup.sh >> /var/log/ghostberry-backup.log 2>&1
EOF
chmod 644 "${CRON_FILE}"
touch /var/log/ghostberry-backup.log
chown "${GHOSTBERRY_USER}":"${GHOSTBERRY_USER}" /var/log/ghostberry-backup.log

# ----------------------------------------------------------------------------
# 8. Optional hardening
# ----------------------------------------------------------------------------
if [[ "${HARDEN}" == "1" ]]; then
  log "Applying host hardening (ufw + unattended-upgrades)"
  apt-get install -y --no-install-recommends ufw unattended-upgrades
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH || ufw allow 22/tcp
  ufw --force enable
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

# ----------------------------------------------------------------------------
# 9. Start
# ----------------------------------------------------------------------------
log "Starting Ghostberry"
systemctl start ghostberry.service

if [[ "${SKIP_HEALTH:-0}" != "1" ]]; then
  log "Waiting for Ghost to become healthy (up to 5 minutes)"
  HEALTHY=0
  for _ in $(seq 1 60); do
    if (cd "${INSTALL_DIR}" && docker compose ps ghost 2>/dev/null | grep -q '(healthy)'); then
      HEALTHY=1; break
    fi
    sleep 5
  done
  if (( ! HEALTHY )); then
    warn "Ghost not healthy yet. Inspect with:"
    warn "  sudo journalctl -u ghostberry.service -e"
    warn "  cd ${INSTALL_DIR} && docker compose logs --tail=100"
  else
    log "Ghost is healthy."
  fi
fi

GHOST_URL_DISPLAY="$(grep -E '^GHOST_URL=' "${INSTALL_DIR}/.env" | cut -d= -f2-)"

cat <<EOF

────────────────────────────────────────────────────────────────────────
✅ Ghostberry installed at ${INSTALL_DIR}
   Admin URL: ${GHOST_URL_DISPLAY}/ghost
   Service:   sudo systemctl status ghostberry
   Logs:      cd ${INSTALL_DIR} && docker compose logs -f
   Backup:    cd ${INSTALL_DIR} && ./scripts/backup.sh
   Restore:   cd ${INSTALL_DIR} && ./scripts/restore.sh backups/<file>
   Update:    cd ${INSTALL_DIR} && ./scripts/update.sh

EOF

if [[ "${NEEDS_REBOOT:-0}" == "1" ]]; then
  warn "Memory cgroups were enabled in the boot cmdline — reboot to activate them:"
  warn "  sudo reboot"
fi
