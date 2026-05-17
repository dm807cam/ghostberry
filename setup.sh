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

# --- Load existing .env FIRST so re-runs preserve prior values -----------
# Prompts below honor existing env vars via ${!var:-}, so loading .env up
# front means a stored value short-circuits the prompt. Critically, we must
# NOT source .env after prompting — that would clobber freshly entered
# values with the stale on-disk ones.
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source ./.env; set +a
fi

# --- Domain ---------------------------------------------------------------
prompt GHOST_URL "Public Ghost URL (e.g. https://blog.example.com)"
if [[ ! "${GHOST_URL}" =~ ^https?:// ]]; then
  GHOST_URL="https://${GHOST_URL}"
fi
# Strip trailing slash.
GHOST_URL="${GHOST_URL%/}"

# --- Cloudflare token -----------------------------------------------------
prompt_secret CLOUDFLARE_TUNNEL_TOKEN "Cloudflare Tunnel token"
if [[ ! "${CLOUDFLARE_TUNNEL_TOKEN}" =~ ^eyJ[A-Za-z0-9_-]+ ]] || [[ ${#CLOUDFLARE_TUNNEL_TOKEN} -lt 40 ]]; then
  echo "⚠️  Cloudflare token doesn't look like a tunnel JWT (expected to start with 'eyJ' and be ≥40 chars). Double-check it." >&2
fi

# --- Optional mail --------------------------------------------------------
# SMTP is fully optional — Ghost runs without it, but password resets and
# member email confirmations won't work until it's configured.
: "${MAIL_HOST:=}"
: "${MAIL_PORT:=587}"
: "${MAIL_USER:=}"
: "${MAIL_PASSWORD:=}"
: "${MAIL_FROM:=}"
: "${MAIL_SECURE:=false}"

ask_yn() {
  # ask_yn "Question" default(y|n) → answer in REPLY (y or n)
  local q="$1" def="${2:-n}" hint="[y/N]" ans=""
  [[ "${def}" == "y" ]] && hint="[Y/n]"
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then REPLY="${def}"; return; fi
  read -r -p "${q} ${hint} " ans <"${TTY_IN}"
  ans="${ans:-${def}}"
  case "${ans}" in y|Y|yes|YES) REPLY=y ;; *) REPLY=n ;; esac
}

# Skip the prompt if SMTP was pre-supplied via env vars or already in .env.
if [[ -z "${MAIL_HOST}" && "${NONINTERACTIVE:-0}" != "1" ]]; then
  echo
  echo "📧 SMTP (optional) — needed for password resets, member invitations,"
  echo "   and magic-link sign-in. You can skip this and add it later in .env."
  echo "   Works with any SMTP provider: Postmark, Brevo, Mailgun, SendGrid,"
  echo "   Fastmail, Gmail (app password), iCloud, your own MTA, etc."
  ask_yn "   Configure SMTP now?" n
  if [[ "${REPLY}" == "y" ]]; then
    prompt        MAIL_HOST     "   SMTP host (e.g. smtp.postmarkapp.com)"
    prompt        MAIL_PORT     "   SMTP port" "587"
    prompt        MAIL_USER     "   SMTP username"
    prompt_secret MAIL_PASSWORD "   SMTP password / API key"
    prompt        MAIL_FROM     "   From address (e.g. blog@example.com)"
    ask_yn        "   Use implicit TLS (port 465)?" n
    if [[ "${REPLY}" == "y" ]]; then MAIL_SECURE=true; else MAIL_SECURE=false; fi
  fi
fi

# --- Generate any still-missing secrets ----------------------------------
# Guard: if the ghost_db volume already exists but we have no stored
# password, regenerating would lock us out of the live database. MySQL
# only honors MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD on first init of the
# data volume, so a new password here would not be applied to the running
# server. Abort with a clear message instead of silently breaking things.
ghost_db_volume_exists() {
  command -v docker >/dev/null 2>&1 || return 1
  docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qE '(^|_)ghost_db$'
}

if [[ -z "${GHOST_DB_PASSWORD:-}" || -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  if ghost_db_volume_exists; then
    echo "❌ A ghost_db Docker volume already exists but DB passwords are missing from .env." >&2
    echo "   Refusing to generate new passwords — they would NOT be applied to the existing" >&2
    echo "   database, and you would be locked out. Recover the original .env from backup," >&2
    echo "   or destroy the volume to start fresh:" >&2
    echo "     docker volume ls | awk '/ghost_db/ {print \$2}' | xargs -r docker volume rm" >&2
    exit 1
  fi
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
trap 'rm -f "${TMP}"' EXIT
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
