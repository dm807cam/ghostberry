#!/usr/bin/env bash
# Ghostberry restore script — companion to backup.sh.
#
# Usage:
#   ./scripts/restore.sh backups/ghost_backup_YYYYMMDDTHHMMSSZ.tar.gz
#   ./scripts/restore.sh backups/ghost_backup_YYYYMMDDTHHMMSSZ.tar.gz.enc
#
# Decrypts (if .enc), stops Ghost, restores the MySQL ghost DB and the
# ghost_content volume, then restarts Ghost.

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
  if compose ps db | grep -q "(healthy)"; then break; fi
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
compose run --rm --no-deps -T \
  -v "${WORK}:/restore-src:ro" \
  --entrypoint sh ghost -c '
    set -e
    cd /var/lib/ghost/content
    find . -mindepth 1 -delete
    tar -xzf /restore-src/content.tar.gz -C /var/lib/ghost/content
  '

echo "▶ Starting Ghost"
compose up -d ghost

echo "✅ Restore complete. Tailing logs (Ctrl-C to detach):"
compose logs -f --tail=50 ghost
