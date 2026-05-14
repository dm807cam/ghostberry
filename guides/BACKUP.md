# Backup & Restore

Ghostberry ships with two scripts that handle the full lifecycle: `scripts/backup.sh` and `scripts/restore.sh`. The installer wires up a daily cron job; everything else is a single command.

## What's captured

Each archive contains:

| File | Contents |
|---|---|
| `database.sql.gz` | `mysqldump` of the `ghost` database (single-transaction, utf8mb4) |
| `content.tar.gz` | The entire `/var/lib/ghost/content` directory — themes, images, files, settings, routes, redirects |
| `images.txt` | Pinned image versions at the time of backup (for reproducible restores) |
| `timestamp.txt` | UTC timestamp |

If `BACKUP_ENCRYPTION_KEY` is set in `.env` (the installer auto-generates one), the final archive is encrypted with `openssl enc -aes-256-cbc -pbkdf2 -iter 200000` and gets a `.enc` suffix.

## Creating a backup

```bash
cd /opt/ghostberry
./scripts/backup.sh
```

Output lands in `backups/ghost_backup_YYYYMMDDTHHMMSSZ.tar.gz[.enc]`, mode `600`, with retention controlled by `BACKUP_KEEP` (default 7).

## Automated backups

The installer drops a cron job at `/etc/cron.d/ghostberry-backup` that runs daily at 03:17 and logs to `/var/log/ghostberry-backup.log`. Tune by editing that file.

To switch to a systemd timer instead:

```ini
# /etc/systemd/system/ghostberry-backup.service
[Unit]
Description=Ghostberry backup
Requires=ghostberry.service

[Service]
Type=oneshot
WorkingDirectory=/opt/ghostberry
ExecStart=/opt/ghostberry/scripts/backup.sh
User=YOUR_USER

# /etc/systemd/system/ghostberry-backup.timer
[Unit]
Description=Daily Ghostberry backup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now ghostberry-backup.timer
sudo rm /etc/cron.d/ghostberry-backup   # remove the cron version
```

## Restoring

```bash
cd /opt/ghostberry
./scripts/restore.sh backups/ghost_backup_20260514T021700Z.tar.gz.enc
```

The script will:

1. Confirm interactively (it overwrites your live DB and content).
2. Decrypt the archive if it's `.enc`.
3. Bring the DB up, stop Ghost.
4. Reload the database via `mysql`.
5. Wipe and re-populate the `ghost_content` volume from `content.tar.gz`.
6. Start Ghost and tail its logs.

## Off-site copies

The local archive is encrypted, so you can safely push it anywhere:

```bash
# rclone — any of dozens of cloud backends
rclone copy /opt/ghostberry/backups remote:ghostberry/ --include 'ghost_backup_*.tar.gz.enc'

# rsync to another host
rsync -avz /opt/ghostberry/backups/ user@nas.local:/backups/ghostberry/
```

Schedule this **after** the nightly backup completes (e.g. cron at 04:00).

## Verifying a backup

```bash
# Encrypted archive — decrypt and stream into tar to check integrity
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in backups/ghost_backup_*.tar.gz.enc \
  -pass env:BACKUP_ENCRYPTION_KEY \
  | tar tzf - >/dev/null && echo "✅ archive intact"

# Plain archive
tar tzf backups/ghost_backup_*.tar.gz >/dev/null && echo "✅ archive intact"
```

## Disaster recovery

Lost the Pi entirely:

1. Flash 64-bit Raspberry Pi OS to a new SD card.
2. Copy your most recent backup archive **and** your old `.env` file to the new box.
3. Run the one-shot installer with `NONINTERACTIVE=1` and the same `GHOST_URL`/`CLOUDFLARE_TUNNEL_TOKEN`, plus paste in the **same** `BACKUP_ENCRYPTION_KEY` from the old `.env` (otherwise the encrypted archive can't be opened).
4. Drop the backup archive into `/opt/ghostberry/backups/`.
5. `./scripts/restore.sh backups/<archive>`.

> ⚠️  **The encryption key is the single most important thing to back up out-of-band.** Without it, an encrypted archive is just noise. Save it in a password manager.

## Checklist

- [ ] Cron is firing (`tail /var/log/ghostberry-backup.log`)
- [ ] Disk has headroom (`df -h /opt/ghostberry`)
- [ ] Off-site copy is running
- [ ] `BACKUP_ENCRYPTION_KEY` is stored outside the Pi
- [ ] You've done one practice restore (do this once a quarter)
