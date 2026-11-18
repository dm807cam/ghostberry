#!/usr/bin/env bash
# Ghostberry analytics helper: Umami web analytics for the blog.
#
#   ./scripts/analytics.sh connect     set up Umami (admin password, a website
#                                      for the blog) and add its tracking script
#                                      to Ghost's site header. Restarts a running
#                                      Ghost only if the script had to change.
#   ./scripts/analytics.sh secure      only replace Umami's default admin password
#                                      (install.sh runs this as soon as Umami starts)
#   ./scripts/analytics.sh disconnect  remove the tracking script from Ghost
#   ./scripts/analytics.sh status      containers, Ghost, and the public address
#   ./scripts/analytics.sh login       the dashboard address, user and password
#
# install.sh runs connect (or disconnect, with ANALYTICS=none) on every run.
# The script lives in Ghost Admin → Settings → Code injection → Site header,
# between "ghostberry:analytics" markers; everything else there is left alone.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

[[ -f .env ]] || { echo "❌ .env not found in ${PROJECT_DIR}" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a

compose() {
  if docker compose version &>/dev/null; then docker compose "$@"; else docker-compose "$@"; fi
}

usage() { sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }
health()  { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || true; }

sql() {
  compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db mysql -N -B -u ghost ghost -e "$1"
}

GHOST_HOST="${GHOST_URL#*://}"; GHOST_HOST="${GHOST_HOST%%[/:]*}"; GHOST_HOST="${GHOST_HOST,,}"
BEGIN_MARK='<!-- ghostberry:analytics -->'
END_MARK='<!-- /ghostberry:analytics -->'

# Ghost's site header with our block taken out (SQL expression). ICU regex;
# match type "n" lets . match newlines, and .*? stops at the first end mark.
STRIPPED="TRIM(TRAILING '\\n' FROM REGEXP_REPLACE(COALESCE(value, ''), '\\n*${BEGIN_MARK}.*?${END_MARK}', '', 1, 0, 'n'))"

need_db() {
  if ! running ghost_db; then
    echo "❌ The database isn't running. Start Ghostberry first: sudo systemctl start ghostberry" >&2
    exit 1
  fi
  if [[ "$(sql "SELECT COUNT(*) FROM settings WHERE \`key\`='codeinjection_head'" 2>/dev/null || true)" != "1" ]]; then
    echo "❌ Ghost hasn't created its settings yet; try again once it is healthy." >&2
    exit 1
  fi
}

# Set Ghost's site header to <stripped> + <block>. Prints "changed" or
# "unchanged". Ghost reads settings when it starts, so a running Ghost is
# restarted after a change.
write_header() {
  local block="$1" new changed
  if [[ -n "${block}" ]]; then
    new="CONCAT(${STRIPPED}, IF(${STRIPPED} = '', '', '\\n'), '${block}')"
  else
    new="${STRIPPED}"
  fi
  changed="$(sql "SELECT COUNT(*) FROM settings WHERE \`key\`='codeinjection_head' AND NOT (BINARY COALESCE(value, '') = BINARY ${new})")"
  if [[ "${changed}" == "0" ]]; then echo unchanged; return 0; fi
  sql "UPDATE settings SET value = ${new}, updated_at = UTC_TIMESTAMP() WHERE \`key\`='codeinjection_head';"
  if running ghost; then
    echo "▶ Restarting Ghost to load the new site header" >&2
    compose restart ghost >/dev/null
  fi
  echo changed
}

# Talks to Umami's API from inside its container (no port is published).
# Logs in as "admin" with UMAMI_ADMIN_PASSWORD; on a fresh install, first
# replaces Umami's default password ("umami") with it. Then (unless the
# argument is "secure") finds or creates the website for the blog's
# hostname and prints its ID.
umami_api() {
  compose exec -T -e UM_PASS="${UMAMI_ADMIN_PASSWORD}" -e UM_DOMAIN="${GHOST_HOST}" -e UM_MODE="${1:-website}" umami node -e '
    const base = "http://127.0.0.1:3000";
    const { UM_PASS, UM_DOMAIN, UM_MODE } = process.env;
    const api = async (method, path, body, token) => {
      const res = await fetch(base + path, {
        method,
        headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
      let data = {};
      try { data = await res.json(); } catch {}
      if (!res.ok && res.status !== 401) throw new Error(method + " " + path + ": HTTP " + res.status);
      return { ok: res.ok, data };
    };
    const login = async (password) => {
      const r = await api("POST", "/api/auth/login", { username: "admin", password });
      return r.ok ? r.data.token : null;
    };
    (async () => {
      let token = await login(UM_PASS);
      if (!token) {
        const first = await login("umami");
        if (!first) {
          console.error("Cannot log in to Umami as admin with UMAMI_ADMIN_PASSWORD from .env.");
          console.error("If you changed the password in Umami, put the new one in .env.");
          process.exit(4);
        }
        await api("POST", "/api/me/password", { currentPassword: "umami", newPassword: UM_PASS }, first);
        token = await login(UM_PASS);
        if (!token) throw new Error("the new admin password was not accepted");
        console.error("Replaced Umami'"'"'s default admin password.");
      }
      if (UM_MODE === "secure") return;
      const list = await api("GET", "/api/websites?pageSize=200&search=" + encodeURIComponent(UM_DOMAIN), null, token);
      let site = (list.data.data || []).find((w) => (w.domain || "").toLowerCase() === UM_DOMAIN);
      if (!site) {
        site = (await api("POST", "/api/websites", { name: UM_DOMAIN, domain: UM_DOMAIN }, token)).data;
        console.error("Created the website " + UM_DOMAIN + " in Umami.");
      }
      if (!/^[0-9a-f-]{36}$/.test(site.id || "")) throw new Error("unexpected website ID from Umami");
      console.log(site.id);
    })().catch((e) => { console.error("Umami API error: " + e.message); process.exit(1); });
  '
}

# Poll Umami itself rather than Docker's health status, which only turns
# healthy after the first 30 s check interval.
wait_umami() {
  for _ in $(seq 1 90); do
    compose exec -T umami curl -fsS -o /dev/null http://127.0.0.1:3000/api/heartbeat >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

need_umami() {
  if [[ "${ANALYTICS:-none}" != "umami" ]]; then
    echo "ℹ️  ANALYTICS is '${ANALYTICS:-none}'. Turn it on with: ANALYTICS=umami ./setup.sh && docker compose up -d" >&2
    exit 1
  fi
  [[ -n "${UMAMI_ADMIN_PASSWORD:-}" ]] || { echo "❌ UMAMI_ADMIN_PASSWORD is missing from .env; re-run ./setup.sh" >&2; exit 1; }
  if ! running umami; then
    echo "▶ Starting Umami"
    compose up -d umami >/dev/null
  fi
  if ! wait_umami; then
    echo "❌ Umami isn't responding. Check: docker compose logs --tail=50 umami umami_db" >&2
    exit 1
  fi
}

public_check() {
  # Does the tunnel route exist? Readers' browsers need it.
  curl -fsS -m 10 -o /dev/null "${ANALYTICS_URL}/api/heartbeat" 2>/dev/null
}

route_help() {
  local host="${ANALYTICS_URL#https://}"
  echo "   Add a route on your Cloudflare Tunnel (Networking → Tunnels → ghostberry"
  echo "   → Routes → Add route → Published application):"
  echo "     Subdomain / Domain: ${host%%.*} + ${host#*.}"
  echo "     Service URL:        http://umami:3000"
}

case "${1:-}" in
  secure)
    need_umami
    umami_api secure
    ;;

  connect)
    [[ "${ANALYTICS_URL:-}" =~ ^https://[a-z0-9.-]+$ || "${ANALYTICS:-none}" != "umami" ]] \
      || { echo "❌ ANALYTICS_URL in .env is not https://<hostname>; re-run ./setup.sh" >&2; exit 1; }
    need_db
    need_umami
    website_id="$(umami_api website)"
    # Every value here is validated, so it is safe inside the SQL string.
    [[ "${website_id}" =~ ^[0-9a-f-]{36}$ && "${GHOST_HOST}" =~ ^[a-z0-9.-]+$ ]] || { echo "❌ Unexpected website ID or host" >&2; exit 1; }
    block="${BEGIN_MARK}\\n<script defer src=\"${ANALYTICS_URL}/script.js\" data-website-id=\"${website_id}\" data-domains=\"${GHOST_HOST}\"></script>\\n${END_MARK}"
    result="$(write_header "${block}")"
    if [[ "${result}" == "changed" ]]; then
      echo "✅ Ghost now loads Umami's tracking script (website ${website_id})."
    else
      echo "✅ Ghost already loads Umami's tracking script (website ${website_id})."
    fi
    if public_check; then
      echo "   Dashboard: ${ANALYTICS_URL}  (user admin; password: ./scripts/analytics.sh login)"
    else
      echo "⚠️  ${ANALYTICS_URL} isn't reachable from the internet yet, so no visits are counted." >&2
      route_help >&2
    fi
    ;;

  disconnect)
    need_db
    result="$(write_header "")"
    if [[ "${result}" == "changed" ]]; then
      echo "✅ Removed Umami's tracking script from Ghost."
    else
      echo "Ghost doesn't load Umami's tracking script; nothing to remove."
    fi
    ;;

  status)
    echo "Analytics: ${ANALYTICS:-none}${ANALYTICS_URL:+ (${ANALYTICS_URL})}"
    for c in umami umami_db; do
      if running "${c}"; then
        echo "  ${c}: running, $(health "${c}")"
      else
        echo "  ${c}: not running"
      fi
    done
    if running ghost_db; then
      snippet="$(sql "SELECT REGEXP_SUBSTR(COALESCE(value, ''), 'data-website-id=\"[0-9a-f-]+\"') FROM settings WHERE \`key\`='codeinjection_head'" 2>/dev/null || true)"
      if [[ -n "${snippet}" && "${snippet}" != "NULL" ]]; then
        echo "  Ghost:  loads the tracking script (${snippet})"
      else
        echo "  Ghost:  no tracking script (./scripts/analytics.sh connect)"
      fi
    fi
    if [[ "${ANALYTICS:-none}" == "umami" ]]; then
      if public_check; then
        echo "  Public: ${ANALYTICS_URL} is reachable"
      else
        echo "  Public: ${ANALYTICS_URL} is NOT reachable"
        route_help
      fi
    fi
    ;;

  login)
    [[ "${ANALYTICS:-none}" == "umami" ]] || { echo "ℹ️  Analytics is off (ANALYTICS=${ANALYTICS:-none})." >&2; exit 1; }
    echo "Dashboard: ${ANALYTICS_URL}"
    echo "Username:  admin"
    echo "Password:  ${UMAMI_ADMIN_PASSWORD:-?}"
    echo "(Changed it in Umami? Put the new one in .env as UMAMI_ADMIN_PASSWORD.)"
    ;;

  *) usage ;;
esac
