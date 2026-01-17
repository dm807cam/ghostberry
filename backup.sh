#!/bin/sh

# Ghost Database Backup Script
# Run with: docker compose run --rm db_backup /backup.sh

BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/ghost_backup_${DATE}.sql.gz"

echo "Starting Ghost database backup..."
echo "Backup file: ${BACKUP_FILE}"

# Create backup directory if it doesn't exist
mkdir -p ${BACKUP_DIR}

# Perform the backup
mysqldump -h ${MYSQL_HOST} \
          -u ${MYSQL_USER} \
          -p${MYSQL_PASSWORD} \
          ${MYSQL_DATABASE} \
          --single-transaction \
          --quick \
          --lock-tables=false \
          | gzip > ${BACKUP_FILE}

if [ $? -eq 0 ]; then
    echo "Backup completed successfully!"
    echo "File size: $(du -h ${BACKUP_FILE} | cut -f1)"
    
    # Keep only last 7 backups
    echo "Cleaning old backups (keeping last 7)..."
    ls -t ${BACKUP_DIR}/ghost_backup_*.sql.gz | tail -n +8 | xargs -r rm --
    
    echo "Remaining backups:"
    ls -lh ${BACKUP_DIR}/ghost_backup_*.sql.gz
else
    echo "Backup failed!"
    exit 1
fi
