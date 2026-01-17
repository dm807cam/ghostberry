# Ghost Backup & Restore Guide

Complete guide for backing up and restoring your Ghost installation.

## 🎯 What Gets Backed Up

Our comprehensive backup solution captures **everything** you need to fully restore your Ghost blog:

### 1. Content & Settings
- **content.json** - Ghost's official export format containing:
  - All posts and pages (published and drafts)
  - Tags and authors
  - Site settings and configuration
  - Navigation menus
  - Custom integrations
  - Email newsletter settings

### 2. Media Files
- **images.tar.gz** - All uploaded images:
  - Post and page images
  - Featured images
  - Author avatars
  - Site logo and icons
  - Gallery images
  - Content card images

### 3. Custom Themes
- **themes.tar.gz** - Your custom themes:
  - Active theme files
  - Inactive/backup themes
  - Theme modifications
  - Custom templates

### 4. Uploaded Files
- **files.tar.gz** - Any uploaded files:
  - PDFs, documents
  - Downloadable resources
  - Other media files

### 5. Configuration
- **routes.yaml** - Custom routing configuration
- **redirects.json** - URL redirects and mappings

### 6. Database
- **database.sql.gz** - Complete MySQL dump as safety net:
  - All tables and data
  - User accounts
  - Relationships
  - Full backup of everything in the database

## 📦 Creating Backups

### Manual Backup

```bash
# Run the backup script
docker compose run --rm ghost_backup /backup.sh
```

**What happens:**
1. Exports Ghost content using Ghost CLI
2. Creates MySQL database dump
3. Archives all images and media
4. Backs up themes and custom files
5. Saves routes and redirects
6. Compresses everything into a single .tar.gz file
7. Keeps the last 7 backups automatically

**Backup location:** `./backups/ghost_backup_YYYYMMDD_HHMMSS.tar.gz`

### Automated Backups

#### Option 1: Cron Job (Recommended)

```bash
# Edit your crontab
crontab -e

# Add one of these schedules:

# Daily at 2 AM
0 2 * * * cd /home/pi/ghost && /usr/bin/docker compose run --rm ghost_backup /backup.sh >> /var/log/ghost-backup.log 2>&1

# Every 12 hours
0 */12 * * * cd /home/pi/ghost && /usr/bin/docker compose run --rm ghost_backup /backup.sh >> /var/log/ghost-backup.log 2>&1

# Weekly on Sunday at 3 AM
0 3 * * 0 cd /home/pi/ghost && /usr/bin/docker compose run --rm ghost_backup /backup.sh >> /var/log/ghost-backup.log 2>&1
```

**Important:** Replace `/home/pi/ghost` with your actual Ghost installation path.

#### Option 2: Systemd Timer

Create `/etc/systemd/system/ghost-backup.service`:

```ini
[Unit]
Description=Ghost Backup Service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=/home/pi/ghost
ExecStart=/usr/bin/docker compose run --rm ghost_backup /backup.sh
StandardOutput=append:/var/log/ghost-backup.log
StandardError=append:/var/log/ghost-backup.log
```

Create `/etc/systemd/system/ghost-backup.timer`:

```ini
[Unit]
Description=Ghost Backup Timer
Requires=ghost-backup.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable ghost-backup.timer
sudo systemctl start ghost-backup.timer

# Check status
sudo systemctl status ghost-backup.timer
```

### Best Practices

1. **Backup Before Updates**
   ```bash
   # Always backup before updating Ghost
   docker compose run --rm ghost_backup /backup.sh
   docker compose pull
   docker compose up -d
   ```

2. **Test Backups Regularly**
   - Verify backup files exist and aren't corrupted
   - Periodically test restore process
   - Check backup file sizes are reasonable

3. **Keep Multiple Backup Locations**
   - Local backups on Raspberry Pi
   - Remote backups (see Off-Site Backup section below)
   - Cloud storage backup

4. **Monitor Backup Success**
   ```bash
   # Check recent backups
   ls -lht backups/ | head -10
   
   # Check backup log
   tail -f /var/log/ghost-backup.log
   ```

## 🔄 Restoring Backups

### Full Restore

Use the restore script for a complete restoration:

```bash
# List available backups
ls -lh backups/

# Restore a specific backup
./restore.sh backups/ghost_backup_20260117_020000.tar.gz
```

**What happens:**
1. Confirms you want to restore (THIS WILL REPLACE ALL DATA)
2. Stops Ghost to prevent corruption
3. Drops and recreates the database
4. Restores database from backup
5. Restores all images, themes, and files
6. Restores routes and redirects
7. Starts Ghost
8. Verifies Ghost is running

### Partial Restore

If you only need to restore specific parts:

#### Restore Only Images

```bash
# Extract backup
mkdir /tmp/restore
tar xzf backups/ghost_backup_20260117_020000.tar.gz -C /tmp/restore

# Stop Ghost
docker compose stop ghost

# Restore images
docker compose run --rm -v /tmp/restore:/restore ghost sh -c \
  "cd /var/lib/ghost/content && tar xzf /restore/ghost_backup_20260117_020000/images.tar.gz"

# Start Ghost
docker compose start ghost

# Cleanup
rm -rf /tmp/restore
```

#### Restore Only Content (Posts/Pages)

```bash
# Extract backup
mkdir /tmp/restore
tar xzf backups/ghost_backup_20260117_020000.tar.gz -C /tmp/restore

# Import via Ghost Admin
# 1. Login to Ghost Admin: https://yourdomain.com/ghost
# 2. Go to Settings > Labs > Import Content
# 3. Upload the content.json file from /tmp/restore/ghost_backup_YYYYMMDD_HHMMSS/

# Cleanup
rm -rf /tmp/restore
```

#### Restore Only Database

```bash
# Extract and restore database only
tar xzOf backups/ghost_backup_20260117_020000.tar.gz \
  ghost_backup_20260117_020000/database.sql.gz | \
  gunzip | \
  docker compose exec -T db mysql -u ghost -p${GHOST_DB_PASSWORD} ghost
```

## 💾 Off-Site Backup Solutions

### Option 1: Rclone to Cloud Storage

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure (interactive)
rclone config

# Sync backups to cloud (add to cron)
rclone sync /home/pi/ghost/backups/ remote:ghost-backups/
```

### Option 2: Rsync to Remote Server

```bash
# Sync to remote server
rsync -avz --delete \
  /home/pi/ghost/backups/ \
  user@remote-server:/path/to/backup/ghost/

# Add to cron after main backup
0 3 * * * rsync -avz /home/pi/ghost/backups/ user@remote:/backups/ghost/
```

### Option 3: USB Drive Backup

```bash
# Mount USB drive
sudo mount /dev/sda1 /mnt/usb

# Copy backups
cp -r backups/ /mnt/usb/ghost-backups/

# Unmount
sudo umount /mnt/usb
```

### Option 4: GitHub/GitLab Private Repo

```bash
# Create a private repository for backups
# Install git-lfs for large files
sudo apt-get install git-lfs

cd backups
git init
git lfs track "*.tar.gz"
git add .
git commit -m "Ghost backup"
git remote add origin git@github.com:yourusername/ghost-backups-private.git
git push -u origin main
```

## 🔍 Verifying Backups

### Check Backup Integrity

```bash
# Test archive integrity
tar tzf backups/ghost_backup_20260117_020000.tar.gz > /dev/null
echo $? # Should output 0 if successful

# List archive contents
tar tzf backups/ghost_backup_20260117_020000.tar.gz

# Check individual components
tar xzOf backups/ghost_backup_20260117_020000.tar.gz \
  ghost_backup_20260117_020000/content.json | jq . > /dev/null
```

### Test Restore (Safe Test)

```bash
# Create a test environment
mkdir ghost-test
cd ghost-test

# Copy configuration
cp ../docker-compose.yml .
cp ../.env .

# Modify ports in docker-compose.yml to avoid conflicts
# Change "2368:2368" to "3368:2368"

# Start test instance
docker compose up -d

# Restore to test instance
cd ..
./restore.sh backups/ghost_backup_20260117_020000.tar.gz

# Test at http://localhost:3368

# Cleanup test
cd ghost-test
docker compose down -v
cd ..
rm -rf ghost-test
```

## 📊 Backup Storage Management

### Monitor Backup Size

```bash
# Total backup size
du -sh backups/

# Individual backup sizes
du -h backups/*.tar.gz | sort -h

# Backup growth over time
ls -lht backups/ | awk '{print $5, $9}'
```

### Cleanup Old Backups

Backups are automatically cleaned (keeps last 7), but you can manually manage:

```bash
# Keep only last 5 backups
ls -t backups/ghost_backup_*.tar.gz | tail -n +6 | xargs rm -f

# Remove backups older than 30 days
find backups/ -name "ghost_backup_*.tar.gz" -mtime +30 -delete

# Keep only backups from 1st of each month
# (Run this monthly to create archive backups)
ls backups/ghost_backup_*_01_*.tar.gz
```

## 🚨 Disaster Recovery

### Complete System Failure

If your Raspberry Pi fails completely:

1. **Get a new Raspberry Pi**
2. **Install Raspberry Pi OS**
3. **Install Docker**
   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo apt-get install -y docker-compose
   ```
4. **Clone repository**
   ```bash
   git clone https://github.com/yourusername/ghost-raspberrypi-cloudflare.git
   cd ghost-raspberrypi-cloudflare
   ```
5. **Restore your .env file** (hopefully you backed this up separately!)
6. **Copy your latest backup** to `./backups/`
7. **Run first-time setup**
   ```bash
   docker compose up -d
   # Wait for initial setup
   docker compose down
   ```
8. **Restore from backup**
   ```bash
   ./restore.sh backups/ghost_backup_YYYYMMDD_HHMMSS.tar.gz
   ```

### Database Corruption

```bash
# Stop Ghost
docker compose stop ghost

# Try to repair database
docker compose exec db mysqlcheck -u root -p${MYSQL_ROOT_PASSWORD} --auto-repair --all-databases

# If repair fails, restore from backup
./restore.sh backups/ghost_backup_YYYYMMDD_HHMMSS.tar.gz
```

## 📝 Backup Checklist

- [ ] Automated backups configured (cron/systemd)
- [ ] Backups running successfully (check logs)
- [ ] Backup retention policy set (default: 7 backups)
- [ ] Off-site backup configured
- [ ] Backup integrity verified monthly
- [ ] Restore process tested quarterly
- [ ] .env file backed up separately
- [ ] Recovery documentation accessible
- [ ] Cloudflare Tunnel token saved securely
- [ ] Backup monitoring/alerting configured

## 🔐 Security Notes

1. **Backup Security**
   - Backups contain your entire Ghost installation
   - Store backups securely with appropriate permissions
   - Encrypt backups if storing on untrusted storage
   - Never commit backups to public repositories

2. **Backup Permissions**
   ```bash
   # Secure backup directory
   chmod 700 backups/
   chmod 600 backups/*.tar.gz
   ```

3. **Encryption** (Optional)
   ```bash
   # Encrypt backup
   gpg --symmetric --cipher-algo AES256 backups/ghost_backup_20260117_020000.tar.gz
   
   # Decrypt when needed
   gpg --decrypt backups/ghost_backup_20260117_020000.tar.gz.gpg > backup.tar.gz
   ```

## 📞 Support

If you encounter issues with backups:

1. Check backup logs: `cat /var/log/ghost-backup.log`
2. Verify disk space: `df -h`
3. Test Docker connectivity: `docker compose ps`
4. Review this guide's troubleshooting section
5. Open an issue on GitHub with logs

---

**Remember:** The best backup is the one you never need, but the worst disaster is the one you weren't prepared for. Test your backups regularly!
