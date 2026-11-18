#!/usr/bin/env bash
# Ghostberry restore script — companion to backup.sh.
#
# Usage:
#   ./scripts/restore.sh backups/ghost_backup_YYYYMMDDTHHMMSSZ.tar.gz
#   ./scripts/restore.sh backups/ghost_backup_YYYYMMDDTHHMMSSZ.tar.gz.enc
#
# Decrypts (if .enc), stops Ghost, restores the MySQL ghost DB, the
# ghost_content volume and (if present) the mail DKIM keys and the Umami
# analytics database, then restarts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup-archive>" >&2
  exit 2
fi

INPUT="$1"
if [[ ! -f "${INPUT}" ]]; then
  echo "❌ Archive not found: ${INPUT}" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "❌ .env not found in ${PROJECT_DIR}" >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source ./.env; set +a

compose() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

read -r -p "⚠️  This will REPLACE the current Ghost database and content. Continue? [y/N] " ans </dev/tty
case "${ans:-}" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ARCHIVE="${INPUT}"
if [[ "${ARCHIVE}" == *.enc ]]; then
  if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    echo "❌ Archive is encrypted but BACKUP_ENCRYPTION_KEY is not set in .env" >&2
    exit 1
  fi
  echo "▶ Decrypting archive"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "${ARCHIVE}" \
    -out "${WORK}/backup.tar.gz" \
    -pass env:BACKUP_ENCRYPTION_KEY
  ARCHIVE="${WORK}/backup.tar.gz"
fi

echo "▶ Extracting archive"
tar -C "${WORK}" -xzf "${ARCHIVE}"

if [[ ! -f "${WORK}/database.sql.gz" || ! -f "${WORK}/content.tar.gz" ]]; then
  echo "❌ Archive missing database.sql.gz or content.tar.gz" >&2
  exit 1
fi

echo "▶ Ensuring database is up"
compose up -d db
# Wait for db healthcheck
for _ in $(seq 1 60); do
  status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' ghost_db 2>/dev/null || true)"
  if [[ "${status}" == "healthy" ]]; then break; fi
  sleep 2
done

echo "▶ Stopping Ghost"
compose stop ghost || true

echo "▶ Restoring database"
gunzip -c "${WORK}/database.sql.gz" \
  | compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db \
      mysql -u ghost --default-character-set=utf8mb4 ghost

echo "▶ Restoring content volume"
# Use a transient container with the same ghost_content volume mount, no deps.
# Stage into a sibling directory first so a torn tar leaves the live content
# intact; only swap after extraction succeeds.
# FOWNER: the Ghost image makes the content dir sticky (mode 1777), so even
# root needs it to delete the node-owned entries in there.
compose run --rm --no-deps -T \
  --cap-add FOWNER \
  -v "${WORK}:/restore-src:ro" \
  --entrypoint sh ghost -c '
    set -e
    STAGE=/var/lib/ghost/content/.restore-stage
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    tar -xzf /restore-src/content.tar.gz -C "$STAGE"
    # Swap: remove old entries (except the stage), then move staged contents up.
    find /var/lib/ghost/content -mindepth 1 -maxdepth 1 ! -name .restore-stage -exec rm -rf {} +
    # Move both regular and dotfiles (busybox sh has no shopt; use find).
    find "$STAGE" -mindepth 1 -maxdepth 1 -exec mv {} /var/lib/ghost/content/ \;
    rmdir "$STAGE"
  '

if [[ -f "${WORK}/mail.tar.gz" ]]; then
  echo "▶ Restoring mail DKIM keys"
  compose stop mail 2>/dev/null || true
  compose run --rm --no-deps -T \
    -v "${WORK}:/restore-src:ro" \
    --entrypoint sh mail -c '
      set -e
      rm -rf /data/dkim_keys
      tar -xzf /restore-src/mail.tar.gz -C /data
    '
fi

if [[ -f "${WORK}/analytics.sql.gz" ]]; then
  if [[ "${ANALYTICS:-none}" == "umami" ]]; then
    echo "▶ Restoring analytics database"
    compose stop umami 2>/dev/null || true
    compose up -d umami_db
    for _ in $(seq 1 60); do
      [[ "$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' umami_db 2>/dev/null || true)" == "healthy" ]] && break
      sleep 2
    done
    gunzip -c "${WORK}/analytics.sql.gz" \
      | compose exec -T umami_db psql -q -v ON_ERROR_STOP=1 -U umami -d umami >/dev/null
    compose up -d umami
  else
    echo "ℹ️  This backup has analytics data, but analytics is off here. To bring it back:" >&2
    echo "   ANALYTICS=umami ./setup.sh && docker compose up -d, then restore again." >&2
  fi
fi

# A backup from before Ghostberry 1.1 has no Almanac theme in it.
"${SCRIPT_DIR}/theme.sh" install >/dev/null 2>&1 \
  || echo "⚠️  Couldn't re-install the Almanac theme; run ./scripts/theme.sh install" >&2

# The restored Ghost database may predate analytics, or point at another
# Umami website: put the matching tracking script back before Ghost starts.
if [[ "${ANALYTICS:-none}" == "umami" ]]; then
  "${SCRIPT_DIR}/analytics.sh" connect \
    || echo "⚠️  Couldn't reconnect analytics; run ./scripts/analytics.sh connect" >&2
fi

echo "▶ Starting Ghost"
compose up -d ghost

echo "✅ Restore complete. Tailing logs (Ctrl-C to detach):"
compose logs -f --tail=50 ghost
