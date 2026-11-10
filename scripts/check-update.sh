#!/usr/bin/env bash
# Ghostberry update check — runs daily from cron (installed by install.sh).
#
#   ./scripts/check-update.sh           report status; email the blog's Owner and
#                                       Administrators once per new release
#   ./scripts/check-update.sh --quiet   only print when there's something to say
#   ./scripts/check-update.sh --clear-notices
#                                       remove Ghostberry's banners from Ghost Admin
#                                       (install.sh does this after an update)
#
# Ghost Admin shows a banner for the same release by itself (Ghost's daily
# update check reads the feed: see UPDATE_CHECK_URL in .env). This script
# adds the one-off email. Turn both off with UPDATE_NOTICES=off ./setup.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

[[ -f .env ]] || { echo "❌ .env not found in ${PROJECT_DIR}" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a

QUIET=0; [[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { (( QUIET )) || echo "$@"; }
STATE="${PROJECT_DIR}/.update-notified"

compose() {
  if docker compose version &>/dev/null; then docker compose "$@"; else docker-compose "$@"; fi
}

if [[ "${1:-}" == "--clear-notices" ]]; then
  # Ghost keeps its notifications as a JSON array in settings.notifications.
  # Drop Ghostberry's ("ghostberry-<version>") so an announcement for the
  # release just installed disappears; a newer one is re-added by Ghost's
  # next update check. Ghost reads the setting at start-up, so this takes
  # effect when the container is recreated (the installer does that).
  compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db mysql -u ghost ghost -e "
    UPDATE settings SET value = COALESCE((
        SELECT JSON_ARRAYAGG(j.n)
        FROM JSON_TABLE(settings.value, '\$[*]' COLUMNS (n JSON PATH '\$')) AS j
        WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(j.n, '\$.id')), '') NOT LIKE 'ghostberry-%'
      ), JSON_ARRAY())
    WHERE \`key\` = 'notifications' AND JSON_VALID(value);" \
    && say "Cleared Ghostberry notices in Ghost Admin."
  exit $?
fi

if [[ "${UPDATE_NOTICES:-on}" == "off" ]]; then
  say "Update notices are off (UPDATE_NOTICES=off)."; exit 0
fi

installed="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[[ -n "${installed}" ]] || { echo "❌ VERSION file missing; re-run the installer." >&2; exit 1; }
# The banner uses the version setup.sh recorded in .env; if the code was
# changed without the installer (e.g. a manual `git pull`), they disagree.
if [[ -n "${GHOSTBERRY_VERSION:-}" && "${GHOSTBERRY_VERSION}" != "${installed}" ]]; then
  echo "⚠️  The code here is ${installed} but the settings are from ${GHOSTBERRY_VERSION}." >&2
  echo "   Re-run the install command to finish updating (it also fixes Ghost Admin's banner)." >&2
fi
feed="${UPDATE_FEED:-https://dm807cam.github.io/ghostberry/update-check}"

if ! latest_json="$(curl -fsS -m 20 "${feed}/latest.json")"; then
  echo "⚠️  Couldn't reach the update feed (${feed}/latest.json); will try again tomorrow." >&2
  exit 1
fi
latest="$(jq -r '.version // empty' <<< "${latest_json}")"
changelog="$(jq -r '.changelog // empty' <<< "${latest_json}")"
install_cmd="$(jq -r '.install // empty' <<< "${latest_json}")"
[[ "${latest}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ Unexpected feed content." >&2; exit 1; }

# Up to date (or ahead, e.g. running an unreleased checkout)?
if [[ "$(printf '%s\n%s\n' "${installed}" "${latest}" | sort -V | tail -n 1)" == "${installed}" ]]; then
  say "✅ Ghostberry ${installed} is up to date."
  exit 0
fi

if [[ "$(cat "${STATE}" 2>/dev/null || true)" == "${latest}" ]]; then
  # Already announced; cron (--quiet) stays silent instead of logging daily.
  say "⬆️  Ghostberry ${latest} is available (this Pi runs ${installed})."
  say "   Update: ${install_cmd}"
  say "   Admins were already emailed about ${latest}."
  exit 0
fi
echo "⬆️  Ghostberry ${latest} is available (this Pi runs ${installed})."
echo "   Update: ${install_cmd}"
if [[ -z "${MAIL_HOST:-}" ]]; then
  say "   Email is off (MAIL_MODE=${MAIL_MODE:-none}); Ghost Admin still shows a banner."
  exit 0
fi

# Owner + Administrators, the same people Ghost alerts. "Locked" and
# "inactive" accounts are skipped.
recipients="$(compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db \
  mysql -N -B -u ghost ghost -e "
    SELECT DISTINCT u.email FROM users u
    JOIN roles_users ru ON ru.user_id = u.id
    JOIN roles r ON r.id = ru.role_id
    WHERE r.name IN ('Owner','Administrator')
      AND u.status NOT IN ('inactive','locked')" 2>/dev/null | paste -sd, -)"
if [[ -z "${recipients}" ]]; then
  echo "⚠️  No Owner/Administrator email found (is Ghost set up yet?)." >&2
  exit 1
fi

{
  echo "Ghostberry ${latest} is available for ${GHOST_URL}. This blog runs ${installed}."
  echo
  echo "What's new: ${changelog}"
  echo
  echo "To update, log in to the Raspberry Pi and run the install command again:"
  echo
  echo "  ${install_cmd}"
  echo
  echo "It takes a backup first, then updates Ghostberry and its containers."
  echo
  echo "--"
  echo "Sent once per release by Ghostberry on this Pi. Turn these off with:"
  echo "  cd ${PROJECT_DIR} && UPDATE_NOTICES=off ./setup.sh && docker compose up -d"
} | "${SCRIPT_DIR}/mail.sh" send "${recipients}" "Ghostberry ${latest} is available for ${GHOST_URL#*://}"

echo "${latest}" > "${STATE}"
echo "   📧 Emailed: ${recipients}"
