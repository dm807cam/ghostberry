#!/bin/bash

# Ghost Restore Script
# Restores a complete Ghost backup
# Usage: ./restore.sh <backup_file.tar.gz>

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    echo ""
    echo "Available backups:"
    ls -lh backups/ghost_backup_*.tar.gz 2>/dev/null || echo "No backups found"
    exit 1
fi

BACKUP_FILE=$1
RESTORE_DIR="/tmp/ghost_restore_$$"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "❌ Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "============================================"
echo "Ghost Restore"
echo "============================================"
echo "Backup: $BACKUP_FILE"
echo "Started: $(date)"
echo ""

# Confirm restore
read -p "⚠️  This will replace ALL current Ghost data. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled"
    exit 0
fi

# Stop Ghost to prevent database corruption
echo ""
echo "[1/6] Stopping Ghost..."
docker compose stop ghost
echo "✅ Ghost stopped"

# Extract backup
echo "[2/6] Extracting backup..."
mkdir -p $RESTORE_DIR
tar xzf $BACKUP_FILE -C $RESTORE_DIR
BACKUP_NAME=$(basename $BACKUP_FILE .tar.gz)
BACKUP_PATH="$RESTORE_DIR/$BACKUP_NAME"

if [ ! -d "$BACKUP_PATH" ]; then
    echo "❌ Invalid backup structure"
    rm -rf $RESTORE_DIR
    exit 1
fi
echo "✅ Backup extracted"

# Restore database
echo "[3/6] Restoring database..."
if [ -f "$BACKUP_PATH/database.sql.gz" ]; then
    # Drop and recreate database
    docker compose exec -T db mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "DROP DATABASE IF EXISTS ghost; CREATE DATABASE ghost CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    docker compose exec -T db mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON ghost.* TO 'ghost'@'%'; FLUSH PRIVILEGES;"
    
    # Restore data
    gunzip < $BACKUP_PATH/database.sql.gz | docker compose exec -T db mysql -u ghost -p${GHOST_DB_PASSWORD} ghost
    echo "✅ Database restored"
else
    echo "⚠️  Database backup not found, skipping..."
fi

# Restore images
echo "[4/6] Restoring images..."
if [ -f "$BACKUP_PATH/images.tar.gz" ] && [ ! -f "$BACKUP_PATH/images.tar.gz.empty" ]; then
    docker compose run --rm -v $BACKUP_PATH:/restore ghost sh -c "cd /var/lib/ghost/content && tar xzf /restore/images.tar.gz"
    echo "✅ Images restored"
else
    echo "⚠️  No images to restore"
fi

# Restore themes
echo "[5/6] Restoring themes..."
if [ -f "$BACKUP_PATH/themes.tar.gz" ] && [ ! -f "$BACKUP_PATH/themes.tar.gz.empty" ]; then
    docker compose run --rm -v $BACKUP_PATH:/restore ghost sh -c "cd /var/lib/ghost/content && tar xzf /restore/themes.tar.gz"
    echo "✅ Themes restored"
else
    echo "⚠️  No themes to restore"
fi

# Restore files
if [ -f "$BACKUP_PATH/files.tar.gz" ] && [ ! -f "$BACKUP_PATH/files.tar.gz.empty" ]; then
    docker compose run --rm -v $BACKUP_PATH:/restore ghost sh -c "cd /var/lib/ghost/content && tar xzf /restore/files.tar.gz"
    echo "✅ Files restored"
fi

# Restore routes and redirects
if [ -f "$BACKUP_PATH/routes.yaml" ]; then
    docker compose cp $BACKUP_PATH/routes.yaml ghost:/var/lib/ghost/content/settings/routes.yaml
    echo "✅ Routes restored"
fi

if [ -f "$BACKUP_PATH/redirects.json" ]; then
    docker compose run --rm ghost sh -c "mkdir -p /var/lib/ghost/content/data"
    docker compose cp $BACKUP_PATH/redirects.json ghost:/var/lib/ghost/content/data/redirects.json
    echo "✅ Redirects restored"
fi

# Start Ghost
echo "[6/6] Starting Ghost..."
docker compose start ghost

# Wait for Ghost to be ready
echo "Waiting for Ghost to start..."
sleep 10

# Verify Ghost is running
if docker compose exec ghost wget --quiet --tries=1 --spider http://localhost:2368 2>/dev/null; then
    echo "✅ Ghost is running"
else
    echo "⚠️  Ghost may still be starting, check logs: docker compose logs -f ghost"
fi

# Cleanup
rm -rf $RESTORE_DIR

echo ""
echo "============================================"
echo "Restore Complete!"
echo "============================================"
echo "Finished: $(date)"
echo ""
echo "Next steps:"
echo "1. Check Ghost logs: docker compose logs -f ghost"
echo "2. Visit your site to verify: https://yourdomain.com"
echo "3. Login to admin: https://yourdomain.com/ghost"
echo ""
echo "Note: You may need to:"
echo "  - Re-upload the content.json via Ghost Admin > Settings > Labs > Import"
echo "  - Activate your theme via Ghost Admin > Settings > Design"
echo "  - Clear browser cache if you see old content"
echo ""
