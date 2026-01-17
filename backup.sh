#!/bin/bash

# Ghost Complete Backup Script
# Backs up: Database, Images, Themes, Routes, Redirects, Settings
# Run with: docker compose run --rm ghost_backup

BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghost_backup_${DATE}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

echo "============================================"
echo "Ghost Complete Backup"
echo "============================================"
echo "Started: $(date)"
echo "Backup: ${BACKUP_NAME}"
echo ""

# Create backup directory
mkdir -p ${BACKUP_PATH}

# 1. Export Ghost content (posts, pages, tags, settings)
echo "[1/4] Exporting Ghost content..."
docker compose exec -T ghost ghost export --output /tmp/ghost-export.json
if [ $? -eq 0 ]; then
    docker compose cp ghost:/tmp/ghost-export.json ${BACKUP_PATH}/content.json
    echo "✅ Content exported"
else
    echo "❌ Content export failed"
fi

# 2. Backup database (full MySQL dump as safety net)
echo "[2/4] Backing up MySQL database..."
docker compose exec -T db mysqldump \
    -u ghost \
    -p${GHOST_DB_PASSWORD} \
    ghost \
    --single-transaction \
    --quick \
    --lock-tables=false \
    | gzip > ${BACKUP_PATH}/database.sql.gz

if [ $? -eq 0 ]; then
    echo "✅ Database backed up ($(du -h ${BACKUP_PATH}/database.sql.gz | cut -f1))"
else
    echo "❌ Database backup failed"
fi

# 3. Backup content files (images, media, themes)
echo "[3/4] Backing up content files..."

# Images
docker compose exec -T ghost tar czf /tmp/images.tar.gz -C /var/lib/ghost/content images 2>/dev/null
docker compose cp ghost:/tmp/images.tar.gz ${BACKUP_PATH}/images.tar.gz 2>/dev/null
if [ -f "${BACKUP_PATH}/images.tar.gz" ]; then
    echo "✅ Images backed up ($(du -h ${BACKUP_PATH}/images.tar.gz | cut -f1))"
else
    echo "⚠️  No images to backup"
    touch ${BACKUP_PATH}/images.tar.gz.empty
fi

# Themes
docker compose exec -T ghost tar czf /tmp/themes.tar.gz -C /var/lib/ghost/content themes 2>/dev/null
docker compose cp ghost:/tmp/themes.tar.gz ${BACKUP_PATH}/themes.tar.gz 2>/dev/null
if [ -f "${BACKUP_PATH}/themes.tar.gz" ]; then
    echo "✅ Themes backed up ($(du -h ${BACKUP_PATH}/themes.tar.gz | cut -f1))"
else
    echo "⚠️  No custom themes to backup"
    touch ${BACKUP_PATH}/themes.tar.gz.empty
fi

# Files
docker compose exec -T ghost tar czf /tmp/files.tar.gz -C /var/lib/ghost/content files 2>/dev/null
docker compose cp ghost:/tmp/files.tar.gz ${BACKUP_PATH}/files.tar.gz 2>/dev/null
if [ -f "${BACKUP_PATH}/files.tar.gz" ]; then
    echo "✅ Files backed up ($(du -h ${BACKUP_PATH}/files.tar.gz | cut -f1))"
else
    echo "⚠️  No files to backup"
    touch ${BACKUP_PATH}/files.tar.gz.empty
fi

# Settings (routes, redirects)
docker compose exec -T ghost sh -c "if [ -f /var/lib/ghost/content/settings/routes.yaml ]; then cat /var/lib/ghost/content/settings/routes.yaml; fi" > ${BACKUP_PATH}/routes.yaml 2>/dev/null
docker compose exec -T ghost sh -c "if [ -f /var/lib/ghost/content/data/redirects.json ]; then cat /var/lib/ghost/content/data/redirects.json; fi" > ${BACKUP_PATH}/redirects.json 2>/dev/null

if [ -s "${BACKUP_PATH}/routes.yaml" ]; then
    echo "✅ Routes backed up"
else
    rm -f ${BACKUP_PATH}/routes.yaml
fi

if [ -s "${BACKUP_PATH}/redirects.json" ]; then
    echo "✅ Redirects backed up"
else
    rm -f ${BACKUP_PATH}/redirects.json
fi

# 4. Create compressed archive
echo "[4/4] Creating compressed archive..."
cd ${BACKUP_DIR}
tar czf ${BACKUP_NAME}.tar.gz ${BACKUP_NAME}/
ARCHIVE_SIZE=$(du -h ${BACKUP_NAME}.tar.gz | cut -f1)

if [ $? -eq 0 ]; then
    echo "✅ Archive created (${ARCHIVE_SIZE})"
    rm -rf ${BACKUP_PATH}
else
    echo "❌ Archive creation failed"
    exit 1
fi

# Cleanup old backups (keep last 7)
echo ""
echo "Cleaning old backups (keeping last 7)..."
ls -t ${BACKUP_DIR}/ghost_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
BACKUP_COUNT=$(ls -1 ${BACKUP_DIR}/ghost_backup_*.tar.gz 2>/dev/null | wc -l)

echo ""
echo "============================================"
echo "Backup Complete!"
echo "============================================"
echo "Location: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
echo "Size: ${ARCHIVE_SIZE}"
echo "Total backups: ${BACKUP_COUNT}"
echo "Finished: $(date)"
echo ""
echo "Backup contents:"
echo "  - content.json (Ghost export with posts, pages, settings)"
echo "  - database.sql.gz (Full MySQL dump)"
echo "  - images.tar.gz (All uploaded images)"
echo "  - themes.tar.gz (Custom themes)"
echo "  - files.tar.gz (Uploaded files)"
echo "  - routes.yaml (Custom routes, if configured)"
echo "  - redirects.json (Custom redirects, if configured)"
echo ""
