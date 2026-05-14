#!/usr/bin/env bash
# Ghostberry backup script — runs on the host, not inside a container.
#
# Backs up:
#   - MySQL ghost database (mysqldump piped through docker compose exec)
#   - Ghost content volume (themes, images, files, settings)
#
# Optional encryption: set BACKUP_ENCRYPTION_KEY in .env to AES-256 encrypt
# the resulting archive with openssl.
#
# Retention: keeps the most recent $BACKUP_KEEP archives (default 7).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

if [[ ! -f .env ]]; then
  echo "❌ .env not found in ${PROJECT_DIR}" >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source ./.env; set +a

BACKUP_DIR="${PROJECT_DIR}/backups"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="ghost_backup_${STAMP}"
WORK="${BACKUP_DIR}/.work-${STAMP}"
ARCHIVE="${BACKUP_DIR}/${NAME}.tar.gz"

mkdir -p "${BACKUP_DIR}" "${WORK}"
chmod 700 "${BACKUP_DIR}"

cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

compose() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

echo "▶ Ghost backup — ${NAME}"

echo "  • dumping database"
compose exec -T -e MYSQL_PWD="${GHOST_DB_PASSWORD}" db \
  mysqldump -u ghost --single-transaction --quick --lock-tables=false \
  --default-character-set=utf8mb4 ghost \
  | gzip -9 > "${WORK}/database.sql.gz"

echo "  • archiving content volume"
compose exec -T ghost tar -C /var/lib/ghost/content -czf - . > "${WORK}/content.tar.gz"

echo "  • capturing image versions"
compose config --images > "${WORK}/images.txt" 2>/dev/null || true
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${WORK}/timestamp.txt"

echo "  • building archive"
tar -C "${BACKUP_DIR}/.work-${STAMP}" -czf "${ARCHIVE}.tmp" .
mv "${ARCHIVE}.tmp" "${ARCHIVE}"

if [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
  echo "  • encrypting (AES-256)"
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -in  "${ARCHIVE}" \
    -out "${ARCHIVE}.enc" \
    -pass env:BACKUP_ENCRYPTION_KEY
  rm -f "${ARCHIVE}"
  ARCHIVE="${ARCHIVE}.enc"
fi

chmod 600 "${ARCHIVE}"

echo "  • pruning (keeping last ${BACKUP_KEEP})"
ls -1t "${BACKUP_DIR}"/ghost_backup_*.tar.gz "${BACKUP_DIR}"/ghost_backup_*.tar.gz.enc 2>/dev/null \
  | tail -n +"$((BACKUP_KEEP + 1))" \
  | xargs -r rm -f

SIZE="$(du -h "${ARCHIVE}" | cut -f1)"
echo "✅ Backup complete: ${ARCHIVE} (${SIZE})"
