#!/usr/bin/env bash
# Ghostberry update — backup, pull, recreate, verify.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

compose() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

echo "▶ Pre-update backup"
"${SCRIPT_DIR}/backup.sh"

echo "▶ Pulling latest images"
compose pull

echo "▶ Recreating services"
compose up -d

echo "▶ Waiting for Ghost to become healthy"
for _ in $(seq 1 60); do
  if compose ps ghost | grep -q "(healthy)"; then
    echo "✅ Ghost is healthy"
    exit 0
  fi
  sleep 5
done

echo "⚠️  Ghost did not report healthy within 5 minutes. Recent logs:" >&2
compose logs --tail=80 ghost >&2
exit 1
