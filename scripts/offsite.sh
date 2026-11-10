#!/usr/bin/env bash
# Ghostberry off-site backups — copies encrypted backups to Cloudflare R2.
#
#   ./scripts/offsite.sh test            check the R2 credentials (upload, read, delete)
#   ./scripts/offsite.sh push [file]     upload a backup (default: newest local one), then prune
#   ./scripts/offsite.sh list            list backups stored in R2
#   ./scripts/offsite.sh pull [name]     download a backup into backups/ (default: newest)
#   ./scripts/offsite.sh prune           delete all but the newest OFFSITE_KEEP backups in R2
#   ./scripts/offsite.sh status          settings, last successful upload, space used
#
# backup.sh calls `push` automatically after every backup when OFFSITE=r2.
# Archives are already AES-256 encrypted on the Pi, so R2 only stores
# ciphertext. rclone runs in a throwaway, locked-down container: nothing
# stays running between backups.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PROJECT_DIR}"

[[ -f .env ]] || { echo "❌ .env not found in ${PROJECT_DIR}" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a

BACKUP_DIR="${PROJECT_DIR}/backups"
MARKER="${BACKUP_DIR}/.offsite-last-ok"
OFFSITE_KEEP="${OFFSITE_KEEP:-7}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.76.0}"
PREFIX="${R2_PREFIX:-ghostberry}"
PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"

usage() { sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

require_config() {
  if [[ "${OFFSITE:-none}" != "r2" ]]; then
    echo "ℹ️  Off-site backups are off (OFFSITE=${OFFSITE:-none})." >&2
    echo "   Turn them on with: OFFSITE=r2 ./setup.sh   (see guides/BACKUP.md)" >&2
    exit 1
  fi
  local v missing=()
  for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [[ -n "${!v:-}" ]] || missing+=("${v}")
  done
  if (( ${#missing[@]} )); then
    echo "❌ OFFSITE=r2 but ${missing[*]} not set in .env. Re-run ./setup.sh." >&2
    exit 1
  fi
}

endpoint() {
  if [[ -n "${R2_ENDPOINT:-}" ]]; then printf '%s' "${R2_ENDPOINT}"; return; fi
  case "${R2_JURISDICTION:-default}" in
    eu)      printf 'https://%s.eu.r2.cloudflarestorage.com' "${R2_ACCOUNT_ID}" ;;
    fedramp) printf 'https://%s.fedramp.r2.cloudflarestorage.com' "${R2_ACCOUNT_ID}" ;;
    *)       printf 'https://%s.r2.cloudflarestorage.com' "${R2_ACCOUNT_ID}" ;;
  esac
}

# rclone in a throwaway container, configured only through environment
# variables (passed by name, so secrets never appear in `ps`). Timeouts
# and retries are bounded so an unreachable R2 fails in minutes, not the
# ~30 minutes rclone's defaults allow.
rclone() {
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_REGION=auto
  export RCLONE_CONFIG_R2_ACL=private
  export RCLONE_CONFIG_R2_ENDPOINT; RCLONE_CONFIG_R2_ENDPOINT="$(endpoint)"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
  # Bucket-scoped "Object Read & Write" tokens can't check/create buckets.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
  mkdir -p "${BACKUP_DIR}"
  docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --memory 256m \
    -e HOME=/tmp \
    -e RCLONE_CONFIG_R2_TYPE -e RCLONE_CONFIG_R2_PROVIDER -e RCLONE_CONFIG_R2_REGION \
    -e RCLONE_CONFIG_R2_ACL -e RCLONE_CONFIG_R2_ENDPOINT -e RCLONE_CONFIG_R2_ACCESS_KEY_ID \
    -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET \
    -v "${BACKUP_DIR}:/backups" \
    "${RCLONE_IMAGE}" --config "" \
      --contimeout 20s --timeout 2m --retries 3 --low-level-retries 3 \
      "$@"
}

REMOTE() { printf 'r2:%s/%s' "${R2_BUCKET}" "${PREFIX}"; }

remote_backups() {
  # Names only, oldest first (the UTC timestamp in the name sorts correctly).
  rclone lsf "$(REMOTE)" --files-only --include 'ghost_backup_*' | sort
}

newest_local() {
  find "${BACKUP_DIR}" -maxdepth 1 -type f \
       \( -name 'ghost_backup_*.tar.gz' -o -name 'ghost_backup_*.tar.gz.enc' \) \
       -printf '%f\n' | sort | tail -n 1
}

cmd_test() {
  require_config
  local obj probe
  obj=".ghostberry-test-$(date -u +%Y%m%dT%H%M%SZ)"
  probe="${BACKUP_DIR}/${obj}"
  echo "▶ Testing R2 bucket '${R2_BUCKET}' at $(endpoint)"
  echo "ghostberry offsite test" > "${probe}"
  local up=0
  rclone copyto "/backups/${obj}" "$(REMOTE)/${obj}" 2>&1 || up=$?
  rm -f "${probe}"
  if (( up != 0 )); then
    echo "❌ Upload failed. Check R2_ACCOUNT_ID, R2_BUCKET, the jurisdiction and the token" >&2
    echo "   (it needs 'Object Read & Write' on this bucket)." >&2
    return 1
  fi
  echo "   ✓ upload"
  if [[ "$(rclone cat "$(REMOTE)/${obj}")" != "ghostberry offsite test" ]]; then
    echo "❌ Read-back failed (token needs read access too)." >&2; return 1
  fi
  echo "   ✓ download"
  if ! rclone deletefile "$(REMOTE)/${obj}" 2>&1; then
    echo "❌ Delete failed: old backups could not be pruned. Give the token" >&2
    echo "   'Object Read & Write', or check for a bucket lock on '${PREFIX}/'." >&2
    return 1
  fi
  echo "   ✓ delete"
  echo "✅ R2 off-site backups are ready."
}

cmd_prune() {
  require_config
  local all n
  mapfile -t all < <(remote_backups)
  n=$(( ${#all[@]} - OFFSITE_KEEP ))
  if (( n <= 0 )); then echo "  • R2 holds ${#all[@]} backup(s); nothing to prune (keeping ${OFFSITE_KEEP})"; return 0; fi
  echo "  • pruning R2 to the newest ${OFFSITE_KEEP} (removing ${n})"
  # One rclone call for the whole list (names are read from stdin).
  if ! printf '%s\n' "${all[@]:0:n}" | rclone delete "$(REMOTE)" --files-from-raw - ; then
    echo "    ⚠️  some old backups could not be deleted (bucket lock?); will retry next time" >&2
    return 1
  fi
}

cmd_push() {
  require_config
  local file="${1:-}" name
  if [[ -z "${file}" ]]; then
    name="$(newest_local)"
    [[ -n "${name}" ]] || { echo "❌ No local backups in ${BACKUP_DIR}. Run ./scripts/backup.sh first." >&2; exit 1; }
  else
    [[ -f "${file}" ]] || { echo "❌ No such file: ${file}" >&2; exit 1; }
    [[ "$(cd "$(dirname "${file}")" && pwd)" == "${BACKUP_DIR}" ]] \
      || { echo "❌ Only files inside ${BACKUP_DIR} can be uploaded." >&2; exit 1; }
    name="$(basename "${file}")"
  fi
  if [[ "${name}" != *.enc ]]; then
    echo "⚠️  ${name} is not encrypted (BACKUP_ENCRYPTION_KEY is empty); uploading it anyway." >&2
  fi
  echo "  • uploading ${name} to R2 (${R2_BUCKET}/${PREFIX})"
  # copyto verifies size and checksum after the transfer.
  rclone copyto "/backups/${name}" "$(REMOTE)/${name}"
  date -u +"%Y-%m-%dT%H:%M:%SZ ${name}" > "${MARKER}"
  # The upload succeeded; a prune problem (e.g. a still-locked object) is
  # only a warning, so backup.sh doesn't report a failed off-site copy.
  cmd_prune || true
}

cmd_list() {
  require_config
  rclone lsl "$(REMOTE)" --max-depth 1 --include 'ghost_backup_*' | sort -k4
}

cmd_pull() {
  require_config
  local name="${1:-latest}"
  if [[ "${name}" == "latest" ]]; then
    name="$(remote_backups | tail -n 1)"
    [[ -n "${name}" ]] || { echo "❌ No backups found in R2 (${R2_BUCKET}/${PREFIX})." >&2; exit 1; }
  fi
  [[ "${name}" == ghost_backup_* && "${name}" != */* ]] || { echo "❌ Not a backup name: ${name}" >&2; exit 1; }
  echo "▶ Downloading ${name} from R2"
  rclone copyto "$(REMOTE)/${name}" "/backups/${name}"
  chmod 600 "${BACKUP_DIR}/${name}"
  echo "✅ Saved to backups/${name}"
  echo "   Restore with: ./scripts/restore.sh backups/${name}"
}

cmd_status() {
  require_config
  echo "Bucket:    ${R2_BUCKET}/${PREFIX}"
  echo "Endpoint:  $(endpoint)"
  echo "Keeping:   newest ${OFFSITE_KEEP} backups in R2"
  if [[ -f "${MARKER}" ]]; then
    local when age
    when="$(cut -d' ' -f1 "${MARKER}")"
    age=$(( ( $(date -u +%s) - $(date -u -d "${when}" +%s) ) / 3600 ))
    echo "Last upload: $(cat "${MARKER}") (${age} h ago)"
    (( age > 36 )) && echo "⚠️  No successful upload in over a day. Check /var/log/ghostberry-backup.log." >&2
  else
    echo "Last upload: never (from this Pi)"
  fi
  echo
  rclone size "$(REMOTE)" --include 'ghost_backup_*'
}

case "${1:-}" in
  test)   cmd_test ;;
  push)   shift; cmd_push "$@" ;;
  list)   cmd_list ;;
  pull)   shift; cmd_pull "$@" ;;
  prune)  cmd_prune ;;
  status) cmd_status ;;
  *)      usage ;;
esac
