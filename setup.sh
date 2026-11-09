#!/usr/bin/env bash
# Ghostberry setup — idempotent .env writer.
#
# Can be run interactively or driven by env vars:
#   GHOST_URL                Full URL (must include scheme)
#   CLOUDFLARE_TUNNEL_TOKEN  Cloudflare Tunnel token
#   MAIL_MODE                builtin | smtp | none   (default: builtin on a
#                            fresh install)
#     builtin: MAIL_DOMAIN, MAIL_FROM, and optionally MAIL_RELAY_HOST,
#              MAIL_RELAY_PORT, MAIL_RELAY_USER, MAIL_RELAY_PASSWORD
#     smtp:    MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_PASSWORD, MAIL_FROM
#   NONINTERACTIVE=1         Fail rather than prompt for missing values
#
# Precedence on re-runs: a non-empty environment variable beats the value
# stored in .env, which beats the built-in default. Database passwords and
# the backup key are never taken from the environment over .env.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "${SCRIPT_DIR}"

# Prefer reading from the controlling terminal so this works under `curl | bash`.
TTY_IN=/dev/stdin
if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi

warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ $*" >&2; exit 1; }

prompt() {
  # prompt VAR "Question" [default]  — no-op if VAR is already non-empty.
  local var="$1" q="$2" def="${3:-}" val=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -n "${def}" ]]; then printf -v "${var}" '%s' "${def}"; return 0; fi
    die "${var} not set and NONINTERACTIVE=1"
  fi
  if [[ -n "${def}" ]]; then
    read -r -p "${q} [${def}]: " val <"${TTY_IN}"
    val="${val:-${def}}"
  else
    read -r -p "${q}: " val <"${TTY_IN}"
  fi
  printf -v "${var}" '%s' "${val}"
}

prompt_secret() {
  local var="$1" q="$2" val=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    die "${var} not set and NONINTERACTIVE=1"
  fi
  read -r -s -p "${q}: " val <"${TTY_IN}"; echo
  printf -v "${var}" '%s' "${val}"
}

ask_yn() {
  # ask_yn "Question" default(y|n) → answer in REPLY (y or n)
  local q="$1" def="${2:-n}" hint="[y/N]" ans=""
  [[ "${def}" == "y" ]] && hint="[Y/n]"
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then REPLY="${def}"; return; fi
  read -r -p "${q} ${hint} " ans <"${TTY_IN}"
  ans="${ans:-${def}}"
  case "${ans}" in y|Y|yes|YES) REPLY=y ;; *) REPLY=n ;; esac
}

genpass() { openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-40; }

# Domain part of an address like  noreply@x.com  or  "'Blog' <noreply@x.com>"
addr_domain() {
  local a="${1##*@}"
  a="${a%%>*}"; a="${a%%[[:space:]\"\']*}"
  printf '%s' "${a,,}"
}

# --- Load existing .env, letting explicit env vars win --------------------
OVERRIDABLE=(
  GHOST_URL CLOUDFLARE_TUNNEL_TOKEN
  MAIL_MODE MAIL_HOST MAIL_PORT MAIL_USER MAIL_PASSWORD MAIL_FROM MAIL_SECURE
  MAIL_DOMAIN MAIL_HOSTNAME MAIL_DKIM_SELECTOR
  MAIL_RELAY_HOST MAIL_RELAY_PORT MAIL_RELAY_USER MAIL_RELAY_PASSWORD
  GHOST_IMAGE MYSQL_IMAGE CLOUDFLARED_IMAGE MAIL_IMAGE
  GHOST_MEM_LIMIT DB_MEM_LIMIT CLOUDFLARED_MEM_LIMIT MAIL_MEM_LIMIT
  MYSQL_BUFFER_POOL BACKUP_KEEP
)
declare -A FROM_ENV=()
for v in "${OVERRIDABLE[@]}"; do
  if [[ -n "${!v:-}" ]]; then FROM_ENV[$v]="${!v}"; fi
done

ENV_EXISTED=0
if [[ -f .env ]]; then
  ENV_EXISTED=1
  # shellcheck disable=SC1091
  set -a; source ./.env; set +a
fi
# Mail settings as stored by the previous run (before env overrides).
PREV_MAIL_MODE="${MAIL_MODE:-}"
PREV_MAIL_HOST="${MAIL_HOST:-}"
for v in "${!FROM_ENV[@]}"; do printf -v "${v}" '%s' "${FROM_ENV[$v]}"; done

# --- Domain ---------------------------------------------------------------
prompt GHOST_URL "Public Ghost URL (e.g. https://blog.example.com)"
if [[ ! "${GHOST_URL}" =~ ^https?:// ]]; then
  GHOST_URL="https://${GHOST_URL}"
fi
GHOST_URL="${GHOST_URL%/}"
GHOST_HOST="${GHOST_URL#*://}"; GHOST_HOST="${GHOST_HOST%%[/:]*}"; GHOST_HOST="${GHOST_HOST,,}"

# --- Cloudflare token -----------------------------------------------------
prompt_secret CLOUDFLARE_TUNNEL_TOKEN "Cloudflare Tunnel token"
if [[ ! "${CLOUDFLARE_TUNNEL_TOKEN}" =~ ^eyJ[A-Za-z0-9_-]+ ]] || [[ ${#CLOUDFLARE_TUNNEL_TOKEN} -lt 40 ]]; then
  warn "Cloudflare token doesn't look like a tunnel JWT (expected to start with 'eyJ' and be ≥40 chars). Double-check it."
fi

# --- Mail -----------------------------------------------------------------
# Ghost needs email for staff invites, password resets and member sign-in
# links. Three ways to get it:
#   builtin  ghost_mail container (maddy), DKIM-signs and delivers itself or
#            through a smarthost. No account needed.
#   smtp     Ghost talks straight to an external SMTP provider.
#   none     no email.
: "${MAIL_MODE:=}"
: "${MAIL_HOST:=}" "${MAIL_PORT:=}" "${MAIL_USER:=}" "${MAIL_PASSWORD:=}"
: "${MAIL_FROM:=}" "${MAIL_SECURE:=}" "${MAIL_DOMAIN:=}" "${MAIL_HOSTNAME:=}"
: "${MAIL_RELAY_HOST:=}" "${MAIL_RELAY_PORT:=}" "${MAIL_RELAY_USER:=}" "${MAIL_RELAY_PASSWORD:=}"
: "${MAIL_DKIM_SELECTOR:=ghost}"

if [[ -z "${MAIL_MODE}" ]]; then
  if [[ "${MAIL_HOST}" == "mail" ]]; then
    MAIL_MODE=builtin
  elif [[ -n "${MAIL_HOST}" ]]; then
    MAIL_MODE=smtp                       # pre-existing external SMTP setup
  elif [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    # Fresh unattended install: turn mail on. Existing install that never
    # had mail: leave it off rather than change behaviour silently.
    if (( ENV_EXISTED )); then MAIL_MODE=none; else MAIL_MODE=builtin; fi
  else
    echo
    echo "📧 Email — Ghost uses it for staff invites, password resets and"
    echo "   member sign-in links. (Newsletters are separate and need Mailgun.)"
    echo "   1) Built-in mail server — maddy, ~20 MB RAM, DKIM-signed, no account"
    echo "   2) External SMTP provider — Brevo, Postmark, SES, Mailgun, Fastmail, …"
    echo "   3) No email for now"
    choice=""
    read -r -p "   Choose [1]: " choice <"${TTY_IN}"
    case "${choice:-1}" in
      2) MAIL_MODE=smtp ;;
      3) MAIL_MODE=none ;;
      *) MAIL_MODE=builtin ;;
    esac
  fi
fi

port25_open() {
  # Can we open a TCP connection to a big mail provider's MX on port 25?
  local mx
  for mx in gmail-smtp-in.l.google.com mx1.mail.icloud.com; do
    if timeout 6 bash -c "exec 3<>/dev/tcp/${mx}/25" 2>/dev/null; then return 0; fi
  done
  return 1
}

configure_relay() {
  prompt        MAIL_RELAY_HOST     "   Relay host (e.g. smtp-relay.brevo.com)"
  prompt        MAIL_RELAY_PORT     "   Relay port (STARTTLS)" "587"
  prompt        MAIL_RELAY_USER     "   Relay username"
  prompt_secret MAIL_RELAY_PASSWORD "   Relay password / API key"
}

case "${MAIL_MODE}" in
  builtin)
    [[ "${MAIL_HOST}" == "mail" ]] || MAIL_HOST=""
    DEFAULT_DOMAIN="${GHOST_HOST#www.}"
    # Ghost sends member emails from noreply@<site domain>, so that is the
    # domain the relay signs for.
    prompt MAIL_DOMAIN "   Send mail as domain" "${DEFAULT_DOMAIN}"
    MAIL_DOMAIN="${MAIL_DOMAIN,,}"
    [[ "${MAIL_DOMAIN}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || die "MAIL_DOMAIN '${MAIL_DOMAIN}' is not a valid domain name."
    if [[ "${MAIL_DOMAIN}" != "${DEFAULT_DOMAIN}" ]]; then
      warn "Ghost sends member emails from noreply@${DEFAULT_DOMAIN} unless you change the"
      warn "sender in Ghost Admin → Settings. The relay only accepts @${MAIL_DOMAIN} senders."
    fi
    prompt MAIL_FROM "   From address" "noreply@${MAIL_DOMAIN}"
    if [[ "$(addr_domain "${MAIL_FROM}")" != "${MAIL_DOMAIN}" ]]; then
      die "MAIL_FROM (${MAIL_FROM}) must be an @${MAIL_DOMAIN} address for the built-in server."
    fi

    # Probe port 25 only when first choosing direct delivery; an install that
    # was already builtin keeps its settings without re-asking.
    if [[ -z "${MAIL_RELAY_HOST}" && "${PREV_MAIL_MODE}" != "builtin" ]]; then
      echo "   Checking whether this network can send mail directly (outbound port 25)…"
      if port25_open; then
        echo "   ✓ Port 25 is open. Mail will be delivered directly."
        echo "     Home IPs often land in spam; a relay (smarthost) fixes that."
        ask_yn "   Use a relay/smarthost anyway?" n
      else
        warn "Outbound port 25 is blocked (common on home connections), so direct"
        warn "delivery will not work. Relay through a provider's SMTP instead —"
        warn "free tiers: Brevo, SMTP2GO, Resend, Mailjet, Amazon SES."
        warn "(Set MAIL_RELAY_HOST/_USER/_PASSWORD and re-run ./setup.sh later.)"
        ask_yn "   Configure a relay now?" y
        [[ "${NONINTERACTIVE:-0}" == "1" ]] && REPLY=n
      fi
      if [[ "${REPLY}" == "y" ]]; then configure_relay; fi
    fi
    MAIL_RELAY_PORT="${MAIL_RELAY_PORT:-587}"
    if [[ -n "${MAIL_RELAY_HOST}" ]]; then
      [[ -n "${MAIL_RELAY_USER}" && -n "${MAIL_RELAY_PASSWORD}" ]] \
        || die "MAIL_RELAY_HOST is set, so MAIL_RELAY_USER and MAIL_RELAY_PASSWORD are required."
      [[ "${MAIL_RELAY_USER}${MAIL_RELAY_PASSWORD}" =~ [[:space:]] ]] \
        && die "MAIL_RELAY_USER / MAIL_RELAY_PASSWORD must not contain whitespace."
      [[ "${MAIL_RELAY_PORT}" == "465" ]] \
        && die "The built-in relay uses STARTTLS; use port 587 (or 2525) instead of 465."
    fi
    # Ghost → ghost_mail container, plain SMTP on the private network.
    MAIL_HOST=mail; MAIL_PORT=2525; MAIL_SECURE=false; MAIL_USER=""; MAIL_PASSWORD=""
    ;;
  smtp)
    [[ "${MAIL_HOST}" == "mail" ]] && MAIL_HOST=""
    # Coming from builtin/none: the stored port (2525) and TLS flag belonged
    # to the internal relay, so ask again unless given explicitly.
    if [[ -z "${PREV_MAIL_HOST}" || "${PREV_MAIL_HOST}" == "mail" ]]; then
      [[ -z "${FROM_ENV[MAIL_PORT]:-}" ]] && MAIL_PORT=""
      [[ -z "${FROM_ENV[MAIL_SECURE]:-}" ]] && MAIL_SECURE=""
    fi
    prompt        MAIL_HOST     "   SMTP host (e.g. smtp.postmarkapp.com)"
    prompt        MAIL_PORT     "   SMTP port (587 = STARTTLS, 465 = implicit TLS)" "587"
    # Username, password and From are optional (some relays use IP auth;
    # Ghost has a default sender), so unattended runs don't insist on them.
    if [[ "${NONINTERACTIVE:-0}" != "1" && -z "${MAIL_USER}${MAIL_PASSWORD}" ]]; then
      prompt        MAIL_USER     "   SMTP username"
      prompt_secret MAIL_PASSWORD "   SMTP password / API key"
    fi
    if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
      prompt        MAIL_FROM     "   From address" "noreply@${GHOST_HOST#www.}"
    fi
    # Port 465 means implicit TLS; everything else upgrades with STARTTLS.
    if [[ -z "${FROM_ENV[MAIL_SECURE]:-}" ]]; then
      if [[ "${MAIL_PORT}" == "465" ]]; then MAIL_SECURE=true; else MAIL_SECURE=false; fi
    fi
    ;;
  none)
    MAIL_HOST=""; MAIL_USER=""; MAIL_PASSWORD=""
    ;;
  *)
    die "MAIL_MODE must be builtin, smtp or none (got '${MAIL_MODE}')."
    ;;
esac
: "${MAIL_PORT:=587}" "${MAIL_SECURE:=false}"

# COMPOSE_PROFILES decides whether the ghost_mail container runs. Keep any
# other profiles the user added by hand.
PROFILES=()
IFS=',' read -r -a _p <<< "${COMPOSE_PROFILES:-}"
for p in "${_p[@]}"; do
  p="${p//[[:space:]]/}"
  [[ -n "${p}" && "${p}" != "mail" ]] && PROFILES+=("${p}")
done
[[ "${MAIL_MODE}" == "builtin" ]] && PROFILES+=("mail")
COMPOSE_PROFILES="$(IFS=,; echo "${PROFILES[*]}")"

# --- Image pins -----------------------------------------------------------
# Ghost 5 no longer gets updates. Move installs that still use the old
# default tag to Ghost 6 (Ghost's own upgrade path; update.sh / install.sh
# take a backup first). An explicit pin such as ghost:5.130 is left alone.
if [[ "${GHOST_IMAGE:-}" == "ghost:5-alpine" ]]; then
  warn "Upgrading GHOST_IMAGE ghost:5-alpine → ghost:6-alpine (Ghost 5 is end-of-life)."
  warn "Check your theme with https://gscan.ghost.org — Ghost 6 removed AMP and '?limit=all'."
  GHOST_IMAGE=ghost:6-alpine
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
  printf '# DO NOT commit this file. Re-run ./setup.sh after editing mail settings.\n\n'
  printf 'GHOST_URL=%s\n\n'                             "$(shq "${GHOST_URL}")"
  printf 'GHOST_DB_PASSWORD=%s\n'                       "$(shq "${GHOST_DB_PASSWORD}")"
  printf 'MYSQL_ROOT_PASSWORD=%s\n\n'                   "$(shq "${MYSQL_ROOT_PASSWORD}")"
  printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\n\n'               "$(shq "${CLOUDFLARE_TUNNEL_TOKEN}")"
  printf '# Optional containers ("mail" = built-in mail server).\n'
  printf 'COMPOSE_PROFILES=%s\n\n'                      "$(shq "${COMPOSE_PROFILES}")"
  printf '# Mail mode: builtin | smtp | none\n'
  printf 'MAIL_MODE=%s\n'     "$(shq "${MAIL_MODE}")"
  printf '# What Ghost connects to (builtin: the ghost_mail container).\n'
  printf 'MAIL_HOST=%s\n'     "$(shq "${MAIL_HOST}")"
  printf 'MAIL_PORT=%s\n'     "$(shq "${MAIL_PORT}")"
  printf 'MAIL_USER=%s\n'     "$(shq "${MAIL_USER}")"
  printf 'MAIL_PASSWORD=%s\n' "$(shq "${MAIL_PASSWORD}")"
  printf 'MAIL_FROM=%s\n'     "$(shq "${MAIL_FROM}")"
  printf 'MAIL_SECURE=%s\n'   "$(shq "${MAIL_SECURE}")"
  printf '# Built-in server only: signing domain and optional smarthost.\n'
  printf 'MAIL_DOMAIN=%s\n'         "$(shq "${MAIL_DOMAIN}")"
  printf 'MAIL_HOSTNAME=%s\n'       "$(shq "${MAIL_HOSTNAME}")"
  printf 'MAIL_DKIM_SELECTOR=%s\n'  "$(shq "${MAIL_DKIM_SELECTOR}")"
  printf 'MAIL_RELAY_HOST=%s\n'     "$(shq "${MAIL_RELAY_HOST}")"
  printf 'MAIL_RELAY_PORT=%s\n'     "$(shq "${MAIL_RELAY_PORT:-587}")"
  printf 'MAIL_RELAY_USER=%s\n'     "$(shq "${MAIL_RELAY_USER}")"
  printf 'MAIL_RELAY_PASSWORD=%s\n\n' "$(shq "${MAIL_RELAY_PASSWORD}")"
  printf '# Backup encryption (auto-generated). Store this somewhere safe.\n'
  printf 'BACKUP_ENCRYPTION_KEY=%s\n'                   "$(shq "${BACKUP_ENCRYPTION_KEY}")"
  printf 'BACKUP_KEEP=%s\n\n'                           "$(shq "${BACKUP_KEEP:-7}")"
  printf '# Image pins — leave at defaults unless overriding.\n'
  printf 'GHOST_IMAGE=%s\n'        "$(shq "${GHOST_IMAGE:-ghost:6-alpine}")"
  printf 'MYSQL_IMAGE=%s\n'        "$(shq "${MYSQL_IMAGE:-mysql:8.0}")"
  printf 'CLOUDFLARED_IMAGE=%s\n'  "$(shq "${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}")"
  printf 'MAIL_IMAGE=%s\n\n'       "$(shq "${MAIL_IMAGE:-ghcr.io/foxcpp/maddy:0.9.7}")"
  printf '# Resource caps (override on low-memory Pis).\n'
  printf 'GHOST_MEM_LIMIT=%s\n'        "$(shq "${GHOST_MEM_LIMIT:-768m}")"
  printf 'DB_MEM_LIMIT=%s\n'           "$(shq "${DB_MEM_LIMIT:-512m}")"
  printf 'CLOUDFLARED_MEM_LIMIT=%s\n'  "$(shq "${CLOUDFLARED_MEM_LIMIT:-128m}")"
  printf 'MAIL_MEM_LIMIT=%s\n'         "$(shq "${MAIL_MEM_LIMIT:-64m}")"
  printf 'MYSQL_BUFFER_POOL=%s\n'      "$(shq "${MYSQL_BUFFER_POOL:-128M}")"
} > "${TMP}"
mv "${TMP}" .env
chmod 600 .env

mkdir -p backups
chmod 700 backups
chmod +x scripts/*.sh 2>/dev/null || true

# Mail server switched off? Compose doesn't treat a disabled-profile service
# as an orphan, so remove its container explicitly. The mail_data volume
# (DKIM key) is kept in case you switch back.
if [[ "${MAIL_MODE}" != "builtin" ]] && command -v docker >/dev/null 2>&1 \
   && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx ghost_mail; then
  echo "▶ Removing the built-in mail container (MAIL_MODE=${MAIL_MODE})"
  docker compose --profile mail rm --stop --force mail >/dev/null 2>&1 \
    || docker rm -f ghost_mail >/dev/null 2>&1 || true
fi

echo "✅ .env written ($(stat -c%a .env 2>/dev/null || stat -f%Lp .env) perms)"
echo "   GHOST_URL=${GHOST_URL}"
case "${MAIL_MODE}" in
  builtin)
    if [[ -n "${MAIL_RELAY_HOST}" ]]; then
      echo "   Mail: built-in server, relaying via ${MAIL_RELAY_HOST}:${MAIL_RELAY_PORT}"
    else
      echo "   Mail: built-in server, direct delivery"
    fi
    echo "         After start-up, publish the DNS records from: ./scripts/mail.sh dns"
    ;;
  smtp) echo "   Mail: external SMTP via ${MAIL_HOST}:${MAIL_PORT}" ;;
  none) echo "   Mail: disabled (re-run with MAIL_MODE=builtin to enable)" ;;
esac
