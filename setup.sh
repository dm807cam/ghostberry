#!/usr/bin/env bash
# Ghostberry setup — idempotent .env writer.
#
# Can be run interactively or driven by env vars:
#   GHOST_URL                Full URL (must include scheme)
#   CLOUDFLARE_TUNNEL_TOKEN  Cloudflare Tunnel token
#   MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_PASSWORD, MAIL_FROM   (optional)
#   NONINTERACTIVE=1         Fail rather than prompt for missing values

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "${SCRIPT_DIR}"

# Prefer reading from the controlling terminal so this works under `curl | bash`.
TTY_IN=/dev/stdin
if [[ -r /dev/tty ]]; then TTY_IN=/dev/tty; fi

prompt() {
  # prompt VAR "Question" [default]
  local var="$1" q="$2" def="${3:-}" val=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    echo "❌ ${var} not set and NONINTERACTIVE=1" >&2; exit 1
  fi
  if [[ -n "${def}" ]]; then
    read -r -p "${q} [${def}]: " val <"${TTY_IN}"
    val="${val:-${def}}"
  else
    read -r -p "${q}: " val <"${TTY_IN}"
  fi
  printf -v "${var}" '%s' "${val}"
  export "${var?}"
}

prompt_secret() {
  local var="$1" q="$2" val=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    echo "❌ ${var} not set and NONINTERACTIVE=1" >&2; exit 1
  fi
  read -r -s -p "${q}: " val <"${TTY_IN}"; echo
  printf -v "${var}" '%s' "${val}"
  export "${var?}"
}

genpass() { openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-40; }

# --- Domain ---------------------------------------------------------------
prompt GHOST_URL "Public Ghost URL (e.g. https://blog.example.com)"
if [[ ! "${GHOST_URL}" =~ ^https?:// ]]; then
  GHOST_URL="https://${GHOST_URL}"
fi
# Strip trailing slash.
GHOST_URL="${GHOST_URL%/}"

# --- Cloudflare token -----------------------------------------------------
prompt_secret CLOUDFLARE_TUNNEL_TOKEN "Cloudflare Tunnel token"
if [[ ${#CLOUDFLARE_TUNNEL_TOKEN} -lt 40 ]]; then
  echo "⚠️  Cloudflare token looks short (${#CLOUDFLARE_TUNNEL_TOKEN} chars). Double-check it." >&2
fi

# --- Optional mail --------------------------------------------------------
: "${MAIL_HOST:=}"
: "${MAIL_PORT:=587}"
: "${MAIL_USER:=}"
: "${MAIL_PASSWORD:=}"
: "${MAIL_FROM:=}"
: "${MAIL_SECURE:=false}"

# --- Generate or preserve secrets ----------------------------------------
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source ./.env; set +a
fi
GHOST_DB_PASSWORD="${GHOST_DB_PASSWORD:-$(genpass)}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(genpass)}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-$(genpass)}"

# Quote a value for .env so both bash (set -a; source) AND
# docker compose's dotenv parser interpret it identically.
# Strategy: wrap in double quotes, backslash-escape \  "  $  `.
shq() {
  local v=${1-}
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//\$/\\\$}
  v=${v//\`/\\\`}
  printf '"%s"' "${v}"
}

# --- Write .env atomically ------------------------------------------------
umask 077
TMP="$(mktemp .env.tmp.XXXXXX)"
{
  printf '# Ghostberry environment — generated %s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# DO NOT commit this file.\n\n'
  printf 'GHOST_URL=%s\n\n'                             "$(shq "${GHOST_URL}")"
  printf 'GHOST_DB_PASSWORD=%s\n'                       "$(shq "${GHOST_DB_PASSWORD}")"
  printf 'MYSQL_ROOT_PASSWORD=%s\n\n'                   "$(shq "${MYSQL_ROOT_PASSWORD}")"
  printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\n\n'               "$(shq "${CLOUDFLARE_TUNNEL_TOKEN}")"
  printf '# Mail (leave blank to disable email features)\n'
  printf 'MAIL_HOST=%s\n'     "$(shq "${MAIL_HOST}")"
  printf 'MAIL_PORT=%s\n'     "$(shq "${MAIL_PORT}")"
  printf 'MAIL_USER=%s\n'     "$(shq "${MAIL_USER}")"
  printf 'MAIL_PASSWORD=%s\n' "$(shq "${MAIL_PASSWORD}")"
  printf 'MAIL_FROM=%s\n'     "$(shq "${MAIL_FROM}")"
  printf 'MAIL_SECURE=%s\n\n' "$(shq "${MAIL_SECURE}")"
  printf '# Backup encryption (auto-generated). Store this somewhere safe.\n'
  printf 'BACKUP_ENCRYPTION_KEY=%s\n\n'                 "$(shq "${BACKUP_ENCRYPTION_KEY}")"
  printf '# Image pins — leave at defaults unless overriding.\n'
  printf 'GHOST_IMAGE=%s\n'        "$(shq "${GHOST_IMAGE:-ghost:5-alpine}")"
  printf 'MYSQL_IMAGE=%s\n'        "$(shq "${MYSQL_IMAGE:-mysql:8.0}")"
  printf 'CLOUDFLARED_IMAGE=%s\n\n' "$(shq "${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}")"
  printf '# Resource caps (override on low-memory Pis).\n'
  printf 'GHOST_MEM_LIMIT=%s\n'        "$(shq "${GHOST_MEM_LIMIT:-768m}")"
  printf 'DB_MEM_LIMIT=%s\n'           "$(shq "${DB_MEM_LIMIT:-512m}")"
  printf 'CLOUDFLARED_MEM_LIMIT=%s\n'  "$(shq "${CLOUDFLARED_MEM_LIMIT:-128m}")"
  printf 'MYSQL_BUFFER_POOL=%s\n'      "$(shq "${MYSQL_BUFFER_POOL:-128M}")"
} > "${TMP}"
mv "${TMP}" .env
chmod 600 .env

mkdir -p backups
chmod 700 backups
chmod +x scripts/*.sh 2>/dev/null || true

echo "✅ .env written ($(stat -c%a .env 2>/dev/null || stat -f%Lp .env) perms)"
echo "   GHOST_URL=${GHOST_URL}"
