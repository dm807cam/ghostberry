# Backup & Restore

Ghostberry ships with two scripts that handle the full lifecycle: `scripts/backup.sh` and `scripts/restore.sh`. The installer wires up a daily cron job; everything else is a single command.

## What's captured

Each archive contains:

| File | Contents |
|---|---|
| `database.sql.gz` | `mysqldump` of the `ghost` database (single-transaction, utf8mb4) |
| `content.tar.gz` | The entire `/var/lib/ghost/content` directory — themes, images, files, settings, routes, redirects |
| `mail.tar.gz` | DKIM private key of the built-in mail server (only when it's enabled), so DNS records stay valid after a restore |
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
6. Restore the mail DKIM key (if the archive has one).
7. Start Ghost and tail its logs.

Re-running the installer (which is how you update) takes a backup first on a live install.

## Off-site copies (Cloudflare R2)

Local backups live on the same SD card as everything else. If the card
dies, they die with it. Ghostberry can copy every backup to
[Cloudflare R2](https://developers.cloudflare.com/r2/) as soon as it's made.

- **Free up to 10 GB** of storage per month, with no download fees, so restoring costs nothing.
  See [R2 pricing](https://developers.cloudflare.com/r2/pricing/).
- **Only encrypted data leaves the Pi.** Archives are AES-256 encrypted before upload;
  Cloudflare never sees your key.
- **Nothing extra keeps running.** rclone runs in a throwaway, locked-down container for
  the few seconds the upload takes.

### Set it up

1. **Enable R2.** In the [Cloudflare dashboard](https://dash.cloudflare.com/?to=/:account/r2/overview),
   open **R2 object storage** and complete the checkout to add the R2 subscription.
   Cloudflare asks for a payment method here even though the first 10 GB/month is free.
   Usage beyond the free tier is billed.
2. **Create a bucket**, e.g. `ghostberry-backups`. Default location is fine.
   If you choose the EU jurisdiction, answer `eu` when asked later.
3. **Create an API token:** on the R2 overview page, under **Account Details**, select
   **Manage** next to **API Tokens** → **Create Account API token**. Permission
   **Object Read & Write**, applied to **that bucket only**. Copy the **Access Key ID**
   and **Secret Access Key** (the secret is shown only once). Your **Account ID** is in
   the same **Account Details** section.
4. **Tell Ghostberry:**
   ```bash
   cd /opt/ghostberry
   OFFSITE=r2 ./setup.sh        # asks for account ID, bucket, keys
   ./scripts/offsite.sh test    # uploads, reads and deletes a test file
   ```
   The installer offers the same prompts, or takes `OFFSITE=r2 R2_ACCOUNT_ID=… R2_BUCKET=…
   R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=…` for an unattended install.

From then on, every backup (the nightly one and the one the installer takes before an update) is uploaded
and R2 is pruned to the newest `OFFSITE_KEEP` (default 7). If the upload fails, the local
backup is still kept, `backup.sh` exits with code 3, and the error is in
`/var/log/ghostberry-backup.log`.

### Everyday commands

```bash
./scripts/offsite.sh status         # last successful upload, space used
./scripts/offsite.sh list           # backups stored in R2
./scripts/offsite.sh push           # upload the newest local backup now
./scripts/offsite.sh pull latest    # download the newest into backups/
```

### Will 10 GB be enough?

Each backup is roughly the size of your uploaded images plus a small database dump,
and R2 keeps `OFFSITE_KEEP` of them. Check yours with `ls -lh backups/`.

| Backup size | × 7 copies | Fits the free tier? |
|---|---|---|
| 100 MB | 0.7 GB | ✅ |
| 500 MB | 3.5 GB | ✅ |
| 1.5 GB | 10.5 GB | ⚠️ set `OFFSITE_KEEP=5`, or pay a few cents a month |

Change it with `OFFSITE_KEEP=5 ./setup.sh`.

### Protect against a hacked Pi (optional)

The token can delete objects (pruning needs that), so someone who takes over the Pi
could delete your off-site copies too. To prevent it, add a **bucket lock rule** in the
R2 dashboard (bucket → **Settings** → **Bucket lock rules** → **Add rule**) with prefix `ghostberry/` and a
retention period **comfortably shorter than `OFFSITE_KEEP` days**, e.g. 3 days with the default of 7.
Locked objects can't be deleted or overwritten until the period ends.

Pruning keeps the newest `OFFSITE_KEEP` backups by count, not by age. On a day with extra
backups (an update, a manual run) it may try to delete a copy that is still locked. That
only logs a warning (the upload itself still counts as successful), and the copy is
removed on a later night once its lock has expired.

### Other destinations

Archives are encrypted, so you can also copy `backups/` anywhere yourself, e.g.
`rsync -avz /opt/ghostberry/backups/ user@nas.local:/backups/ghostberry/` from cron
after 03:17.

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

Lost the Pi or its SD card:

1. Flash 64-bit Raspberry Pi OS to a new card and set up the Cloudflare Tunnel token as before.
2. Run the installer with the **same** `BACKUP_ENCRYPTION_KEY` (otherwise the encrypted
   archives can't be opened) and, if you used R2, the same R2 settings:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh \
     | sudo GHOST_URL=… CLOUDFLARE_TUNNEL_TOKEN=… BACKUP_ENCRYPTION_KEY='<old key>' \
            OFFSITE=r2 R2_ACCOUNT_ID=… R2_BUCKET=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… \
            NONINTERACTIVE=1 bash
   ```
   (Already installed without them? Set the values in `.env` instead.)
3. Get the archive back:
   - from R2: `cd /opt/ghostberry && ./scripts/offsite.sh pull latest`
   - from your own copy: put it in `/opt/ghostberry/backups/`
4. `./scripts/restore.sh backups/<archive>`

> ⚠️  **The encryption key is the single most important thing to back up out-of-band.** Without it, an encrypted archive is just noise. Save it in a password manager, together with your R2 Access Key ID and Secret.

## Checklist

- [ ] Cron is firing (`tail /var/log/ghostberry-backup.log`)
- [ ] Disk has headroom (`df -h /opt/ghostberry`)
- [ ] Off-site copy is running (`./scripts/offsite.sh status`)
- [ ] `BACKUP_ENCRYPTION_KEY` is stored outside the Pi
- [ ] You've done one practice restore (do this once a quarter)
