#!/usr/bin/env bash
# Ghostberry theme script — installs Almanac, the theme that ships with
# Ghostberry (themes/almanac), into Ghost.
#
#   ./scripts/theme.sh install      copy the theme into Ghost's content volume.
#                                   Prints "updated" or "unchanged"; Ghost picks
#                                   up an updated theme when it next starts.
#   ./scripts/theme.sh activate     make Almanac the active theme (restarts Ghost)
#   ./scripts/theme.sh activate --if-new
#                                   the same, but only on a blog nobody has set
#                                   up yet (install.sh does this on a new install)
#   ./scripts/theme.sh status       show the active and the bundled theme version
#
# The copy in Ghost is replaced on every install/update, so don't edit it in
# place: to customise, download it in Ghost Admin, change "name" in
# package.json and upload it as your own theme.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

THEME=almanac
ACCENT="#2f5d46"          # Almanac's green
GHOST_DEFAULT_ACCENT="#FF1A75"

[[ -f .env ]] || { echo "❌ .env not found in ${PROJECT_DIR}" >&2; exit 1; }
[[ -f "themes/${THEME}/package.json" ]] || { echo "❌ themes/${THEME} is missing; re-run the installer." >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a

compose() {
  if docker compose version &>/dev/null; then docker compose "$@"; else docker-compose "$@"; fi
}

sql() {
  compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db mysql -N -B -u ghost ghost -e "$1"
}

wait_healthy() {
  local status
  for _ in $(seq 1 60); do
    status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' ghost 2>/dev/null || true)"
    [[ "${status}" == "healthy" ]] && return 0
    sleep 5
  done
  return 1
}

install_theme() {
  # A throwaway container with the content volume mounted, like restore.sh:
  # works whether or not Ghost is running, and on a brand-new volume.
  # Staged next to the target and swapped in, so a failed copy leaves the
  # installed theme intact.
  compose run --rm --no-deps -T \
    -v "${PROJECT_DIR}/themes/${THEME}:/theme-src:ro" \
    --entrypoint sh ghost -c '
      set -e
      themes=/var/lib/ghost/content/themes
      mkdir -p "$themes"
      if [ -d "$themes/'"${THEME}"'" ] && diff -rq /theme-src "$themes/'"${THEME}"'" >/dev/null 2>&1; then
        echo unchanged; exit 0
      fi
      rm -rf "$themes/.'"${THEME}"'-new"
      cp -R /theme-src "$themes/.'"${THEME}"'-new"
      chown -R node:node "$themes/.'"${THEME}"'-new"
      rm -rf "$themes/'"${THEME}"'"
      mv "$themes/.'"${THEME}"'-new" "$themes/'"${THEME}"'"
      echo updated
    '
}

case "${1:-}" in
  install)
    install_theme
    ;;

  activate)
    if [[ "$(docker inspect -f '{{.State.Running}}' ghost_db 2>/dev/null || true)" != "true" ]]; then
      echo "❌ The database isn't running. Start Ghostberry first: sudo systemctl start ghostberry" >&2
      exit 1
    fi
    active="$(sql "SELECT value FROM settings WHERE \`key\`='active_theme'" 2>/dev/null || true)"
    if [[ -z "${active}" ]]; then
      echo "❌ Ghost hasn't created its settings yet; try again once it is healthy." >&2
      exit 1
    fi
    if [[ "${2:-}" == "--if-new" ]]; then
      # Never change the look of a blog somebody already runs: only act
      # while Ghost is still waiting for its first sign-up (no active
      # staff user) and still on the theme it came with.
      staff="$(sql "SELECT COUNT(*) FROM users WHERE status='active'" 2>/dev/null || echo 1)"
      if [[ "${staff}" != "0" || ! "${active}" =~ ^(source|casper)$ ]]; then
        exit 0
      fi
    fi
    if [[ "${active}" == "${THEME}" ]]; then
      echo "Almanac is already the active theme."; exit 0
    fi
    install_theme >/dev/null
    # Ghost reads the active theme from its settings when it starts. The
    # accent colour is only changed while it is still Ghost's default pink.
    sql "UPDATE settings SET value='${THEME}' WHERE \`key\`='active_theme';
         UPDATE settings SET value='${ACCENT}' WHERE \`key\`='accent_color' AND value='${GHOST_DEFAULT_ACCENT}';"
    echo "▶ Restarting Ghost with the Almanac theme"
    compose restart ghost >/dev/null
    if wait_healthy; then
      echo "✅ Almanac is the active theme."
    else
      echo "⚠️  Ghost isn't healthy yet. Check: docker compose logs --tail=50 ghost" >&2
      exit 1
    fi
    ;;

  status)
    bundled="$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "themes/${THEME}/package.json" | head -n 1)"
    echo "Bundled:   Almanac ${bundled}"
    active="$(sql "SELECT value FROM settings WHERE \`key\`='active_theme'" 2>/dev/null || true)"
    echo "Active:    ${active:-unknown (is Ghost running?)}"
    installed="$(docker exec ghost sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "/var/lib/ghost/content/themes/${THEME}/package.json" 2>/dev/null | head -n 1 || true)"
    if [[ -n "${installed}" ]]; then
      echo "Installed: Almanac ${installed}"
    else
      echo "Installed: no (run ./scripts/theme.sh install)"
    fi
    ;;

  *)
    echo "Usage: $0 install | activate [--if-new] | status" >&2
    exit 2
    ;;
esac
