#!/usr/bin/env bash
# Ghostberry mail helper.
#
#   ./scripts/mail.sh dns            DNS records to publish for the built-in
#                                    mail server, and whether they're live
#   ./scripts/mail.sh test <address> send a test email the same way Ghost does
#   ./scripts/mail.sh status         container health, queue and recent log
#   ./scripts/mail.sh send <to> <subject>   send stdin as a plain-text email

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

usage() { sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

need_builtin() {
  if [[ "${MAIL_MODE:-}" != "builtin" ]]; then
    echo "ℹ️  MAIL_MODE is '${MAIL_MODE:-none}', not 'builtin' — the built-in mail server isn't in use." >&2
    [[ "${MAIL_MODE:-}" == "smtp" ]] && echo "   DNS records for ${MAIL_HOST} come from your SMTP provider's dashboard." >&2
    exit 1
  fi
  if ! compose ps --status running --services 2>/dev/null | grep -qx mail; then
    echo "❌ The mail container isn't running. Start it with: docker compose up -d" >&2
    exit 1
  fi
}

# TXT lookup over DNS-over-HTTPS (works even without dig installed).
txt_lookup() {
  curl -fsS -m 10 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$1&type=TXT" 2>/dev/null \
    | jq -r '.Answer[]? | select(.type==16) | .data' 2>/dev/null \
    | sed -e 's/^"//' -e 's/"$//' -e 's/" "//g' || true
}

check() {
  # check <name> <needle>  → ✓ if a TXT record at <name> contains <needle>
  if txt_lookup "$1" | grep -qF -- "$2"; then echo "   ✓ published"; else echo "   ✗ not found yet (DNS can take a few minutes)"; fi
}

cmd_dns() {
  need_builtin
  local domain="${MAIL_DOMAIN}" sel="${MAIL_DKIM_SELECTOR:-ghost}" dkim pubkey ip spf
  dkim="$(compose exec -T mail cat "/data/dkim_keys/${domain}_${sel}.dns" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "${dkim}" ]]; then
    echo "❌ No DKIM key found yet. Check: docker compose logs mail" >&2; exit 1
  fi
  pubkey="${dkim##*p=}"

  echo "Add these TXT records in Cloudflare → DNS (or wherever ${domain} is hosted)."
  echo "They are plain TXT records — the proxy toggle doesn't apply."
  echo
  echo "1) DKIM — proves the mail really comes from you"
  echo "   Name:  ${sel}._domainkey.${domain}"
  echo "   Value: ${dkim}"
  check "${sel}._domainkey.${domain}" "${pubkey:0:40}"
  echo
  echo "2) SPF — which servers may send for ${domain}"
  if [[ -n "${MAIL_RELAY_HOST:-}" ]]; then
    echo "   Name:  ${domain}"
    echo "   Value: v=spf1 include:<your relay provider's SPF domain> ~all"
    echo "   (Your provider (${MAIL_RELAY_HOST}) documents the exact include.)"
    check "${domain}" "v=spf1"
  else
    ip="$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)"
    echo "   Name:  ${domain}"
    echo "   Value: v=spf1 ip4:${ip:-<your public IPv4>} ~all"
    echo "   (Home IPs usually change; if yours does, SPF will break. DKIM alone"
    echo "    still passes DMARC, but a relay is the more reliable option.)"
    spf="v=spf1"; [[ -n "${ip}" ]] && spf="${ip}"
    check "${domain}" "${spf}"
  fi
  echo "   Merge with any existing SPF record: a name may only have ONE v=spf1 record."
  echo
  echo "3) DMARC — tells receivers what to do with mail that fails the checks"
  echo "   Name:  _dmarc.${domain}"
  echo "   Value: v=DMARC1; p=none; adkim=r; aspf=r"
  echo "   (Tighten to p=quarantine once test mail arrives with dkim=pass.)"
  check "_dmarc.${domain}" "v=DMARC1"
  echo
  if [[ -z "${MAIL_RELAY_HOST:-}" ]]; then
    echo "Reverse DNS: big providers want your public IP's PTR record to resolve."
    echo "Most ISPs set one automatically; check with: dig -x ${ip:-<your IP>}"
  fi
}

# send <to[,to2,...]> <subject>  — body is read from stdin (plain text).
# Runs inside the Ghost container with Ghost's own nodemailer and the same
# mail__* settings Ghost uses, so it works for the built-in server and for
# an external SMTP provider alike, and a pass means Ghost can send too.
send_mail() {
  local to="$1" subject="$2"
  [[ -n "${MAIL_HOST:-}" ]] || { echo "❌ Mail is disabled (MAIL_HOST is empty). Re-run ./setup.sh." >&2; return 1; }
  compose exec -T -e MAIL_TO="${to}" -e MAIL_SUBJECT="${subject}" ghost node -e '
    const nodemailer = require("/var/lib/ghost/current/node_modules/nodemailer");
    const e = process.env;
    let text = "";
    process.stdin.on("data", d => text += d).on("end", () => {
      const opts = { host: e.mail__options__host, port: Number(e.mail__options__port),
                     secure: e.mail__options__secure === "true" };
      if (e.mail__options__auth__user) opts.auth = { user: e.mail__options__auth__user, pass: e.mail__options__auth__pass };
      const host = new URL(e.url).hostname.replace(/^www\./, "");
      const from = e.mail__from || `noreply@${host}`;
      nodemailer.createTransport(opts).sendMail({ from, to: e.MAIL_TO, subject: e.MAIL_SUBJECT, text })
        .then(i => console.log("✅ accepted:", i.response),
              err => { console.error("❌", err.message); process.exit(1); });
    });
  '
}

cmd_test() {
  local to="${1:-}"
  [[ -n "${to}" ]] || usage
  [[ -n "${MAIL_HOST:-}" ]] || { echo "❌ Mail is disabled (MAIL_HOST is empty). Re-run ./setup.sh." >&2; exit 1; }
  echo "▶ Sending a test email to ${to} through ${MAIL_HOST}:${MAIL_PORT} (Ghost's settings)"
  printf 'This is a test from your Ghost site %s.\nIf you can read this, Ghost email works.\n' "${GHOST_URL}" \
    | send_mail "${to}" "Ghostberry test email"
  if [[ "${MAIL_MODE:-}" == "builtin" ]]; then
    echo "   The built-in server queued it. Delivery result: ./scripts/mail.sh status"
  fi
}

cmd_send() {
  [[ $# -eq 2 ]] || usage
  send_mail "$1" "$2"
}

cmd_status() {
  need_builtin
  compose ps mail
  echo
  echo "Queued messages (retrying):"
  compose exec -T mail sh -c 'ls /data/remote_queue 2>/dev/null | grep -c "\.meta$" || true'
  echo
  echo "Recent log:"
  compose logs --tail=25 --no-log-prefix mail
}

case "${1:-}" in
  dns)    cmd_dns ;;
  test)   shift; cmd_test "$@" ;;
  send)   shift; cmd_send "$@" ;;
  status) cmd_status ;;
  *)      usage ;;
esac
