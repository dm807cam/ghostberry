# Troubleshooting

All commands run from the install directory (`cd /opt/ghostberry`).

## Quick diagnostics

```bash
docker compose ps                      # every service should be "healthy" / "running"
docker compose logs --tail=50          # all services
sudo journalctl -u ghostberry -e       # systemd start/stop
```

`.env` isn't loaded into your shell automatically. Commands below that use
`$GHOST_DB_PASSWORD` etc. need it first:

```bash
set -a; source ./.env; set +a
```

## Ghost won't start / keeps restarting

```bash
docker compose logs --tail=100 ghost
```

| Log says | Fix |
|---|---|
| `ER_ACCESS_DENIED_ERROR` | `.env` DB password doesn't match the database. See [Database](#database) |
| `connect ECONNREFUSED db:3306` | MySQL still starting (first boot takes 1–2 min on a Pi) or crashed: `docker compose logs db` |
| `Database state requires migration` / `Running migrations` | Normal after an upgrade; wait. Ghost 5 → 6 can take a few minutes on a Pi |
| `Killed` / exit code 137 | Out of memory. See [Memory](#out-of-memory) |

Ghost has no published port. To reach it from the Pi itself:

```bash
docker compose exec ghost wget -qO- --header='X-Forwarded-Proto: https' \
  http://localhost:2368/ghost/api/admin/site/
```

## Cloudflare Tunnel not connecting

```bash
docker compose logs --tail=30 cloudflared
```

- `Unauthorized` / `invalid token`: re-copy the token from Zero Trust →
  Networking → Tunnels (Docker command, after `--token`), then `CLOUDFLARE_TUNNEL_TOKEN=eyJ… ./setup.sh && docker compose up -d`.
- Tunnel is healthy but the site shows **502**: the published application
  route's service URL must be exactly `http://ghost:2368`.
- **Redirect loop / "too many redirects"**: `GHOST_URL` must be `https://…`
  and match the route's hostname.
- cloudflared only starts once Ghost is healthy, so fix Ghost first.

## Database

```bash
docker compose logs --tail=50 db
set -a; source ./.env; set +a
docker compose exec -e MYSQL_PWD="$GHOST_DB_PASSWORD" db mysql -u ghost -e 'SELECT 1' ghost
```

If the password in `.env` was lost or changed, set it in MySQL to match:

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
  mysql -u root -e "ALTER USER 'ghost'@'%' IDENTIFIED BY '$GHOST_DB_PASSWORD';"
docker compose restart ghost
```

MySQL only reads `MYSQL_*` passwords when it first creates the volume.
Changing them in `.env` later does **not** change the database.

## Email

```bash
./scripts/mail.sh status                # built-in server: health, queue, log
./scripts/mail.sh test you@example.com  # send exactly like Ghost does
docker compose logs ghost | grep -i mail
```

| Problem | Fix |
|---|---|
| `connect: connection refused` to port 25, "will retry" | Your ISP blocks outbound port 25. Configure a relay: `MAIL_RELAY_HOST=… MAIL_RELAY_USER=… MAIL_RELAY_PASSWORD=… ./setup.sh && docker compose up -d` |
| `553 5.7.1 Sender domain not allowed` | Sender isn't `@MAIL_DOMAIN`. Check `MAIL_FROM` and the sender addresses in Ghost Admin → Settings |
| Mail lands in spam | Publish the records from `./scripts/mail.sh dns`; use a relay |
| `optional dependency "mail" failed to start` during `docker compose up` | Ghost still starts, but can't send mail. Check `docker compose logs mail` (usually a typo in `MAIL_DOMAIN` or the relay settings in `.env`) |
| `ECONNREFUSED mail:2525` in Ghost logs | Mail container isn't running. `.env` needs `COMPOSE_PROFILES="mail"`; re-run `./setup.sh` |
| External SMTP: `Invalid login` / `535` | Wrong credentials; Gmail needs an app password |
| External SMTP: `wrong version number` / TLS errors | Port and TLS mode don't match: 465 ⇒ `MAIL_SECURE=true`, 587 ⇒ `false`. `setup.sh` sets this from the port |
| Newsletters don't send | Expected: Ghost sends newsletters only through Mailgun. See [MAIL.md](MAIL.md#what-about-newsletters) |

Full details: [MAIL.md](MAIL.md).

## Off-site backups (Cloudflare R2)

```bash
./scripts/offsite.sh test     # upload, read back, delete a test file
./scripts/offsite.sh status   # last successful upload
```

| Error | Fix |
|---|---|
| `backup.sh` exits with code 3 | The local backup worked; only the upload failed. Run `./scripts/offsite.sh test` |
| `403` / `AccessDenied` / `SignatureDoesNotMatch` | Wrong key or secret, or the token isn't allowed on this bucket. Create a token with **Object Read & Write** on the bucket and re-run `./setup.sh` with the new `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` |
| `NoSuchBucket` | `R2_BUCKET` is misspelled, or the bucket is in the EU jurisdiction: set `R2_JURISDICTION=eu` |
| `test` fails at delete, or pruning warns it couldn't delete | A bucket lock rule protects the object. Occasional prune warnings after extra backups are expected and harmless; if they happen every night, shorten the lock period |
| `dial tcp … i/o timeout` | The Pi can't reach `*.r2.cloudflarestorage.com` (network or DNS). The next nightly run retries |

## Out of memory

```bash
free -h
docker stats --no-stream
```

1. Make sure memory cgroups are on (the installer does this; reboot once
   after install). `docker info` must not warn about missing memory limit support.
2. Lower the caps in `.env`, then `docker compose up -d`:
   ```bash
   GHOST_MEM_LIMIT=640m
   DB_MEM_LIMIT=384m
   MYSQL_BUFFER_POOL=64M
   ```
3. Check swap: `swapon --show`. Raspberry Pi OS Trixie uses zram via `rpi-swap`;
   Bookworm uses `dphys-swapfile` (`CONF_SWAPSIZE` in `/etc/dphys-swapfile`).

## Can't open /ghost admin

- The URL must match `GHOST_URL` exactly (scheme and `www.` included).
- Check what Ghost thinks its URL is: `docker compose exec ghost printenv url`
- If you use Cloudflare Access on `/ghost`, make sure you are allowed through.

## Updating

```bash
./scripts/update.sh      # backup → pull → recreate → wait for healthy
```

If the update fails, the pre-update backup is the newest file in `backups/`:
`./scripts/restore.sh backups/<file>`.

## Backups

```bash
tail -50 /var/log/ghostberry-backup.log   # nightly cron output
./scripts/backup.sh                        # run by hand
df -h .                                    # space left?
```

## Permission errors

```bash
groups $USER             # must include "docker"
sudo usermod -aG docker $USER && newgrp docker
```

Ghost's entrypoint fixes ownership inside the `ghost_content` volume on
every start, so you shouldn't need to `chown` volume data.

## Debug logging

Add to the `ghost` service's `environment:` in `docker-compose.yml`:

```yaml
      logging__level: debug
```

Then `docker compose up -d && docker compose logs -f ghost`.

## Shells and inspection

```bash
docker compose exec ghost sh
docker compose exec db bash
docker compose exec mail sh
docker compose exec ghost printenv | grep -E '^(url|mail__|database__client)'
docker network ls | grep -E 'frontend|backend|mail'
```

## Complete reset (deletes ALL data)

```bash
./scripts/backup.sh                         # just in case
docker compose --profile mail down -v       # removes containers AND volumes
rm .env && ./setup.sh                       # new passwords
docker compose up -d
```

## Getting help

- Ghost Forum: https://forum.ghost.org/
- Cloudflare Community: https://community.cloudflare.com/
- maddy docs: https://maddy.email/
- System info to include in a report:
  ```bash
  cat /proc/device-tree/model; . /etc/os-release; echo "$PRETTY_NAME"
  docker --version; docker compose version; docker compose ps
  ```
