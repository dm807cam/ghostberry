# Ghostberry

**Production-ready Ghost CMS on a Raspberry Pi, fronted by a Cloudflare Tunnel — installable in one command.**

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

That's it. The installer is idempotent — re-run it any time to update the source or re-sync configuration.

---

## What you get

- 🐳 **Ghost 6** (Alpine, ARM64-native) + **MySQL 8** + **cloudflared**, wired together with Docker Compose
- 📧 **Email that works from the first boot**: a built-in send-only mail server ([maddy](https://maddy.email), ~6 MB RAM) that DKIM-signs and queues Ghost's emails. Or plug in any SMTP provider. See [guides/MAIL.md](guides/MAIL.md)
- 🔒 **Zero exposed ports** — every request reaches Ghost only through your Cloudflare Tunnel (DDoS protection + WAF for free)
- 🛡️ **Hardened containers** — dropped capabilities, `no-new-privileges`, memory caps, log rotation
- 💾 **Daily encrypted backups** via cron, with a real `restore.sh`, and optional off-site copies in **Cloudflare R2** (free up to 10 GB), so a dead SD card doesn't take your blog with it
- 🚀 **systemd unit** for clean boot/shutdown
- 🔔 **Update notices:** a banner in Ghost Admin and one email to the admins when a new Ghostberry release is out. Updating is re-running the install command, which moves to the exact image versions that release pins
- 🍓 **Pi-aware bootstrap** — enables memory cgroups, ensures swap, installs Docker

## Requirements

| | |
|---|---|
| Hardware | Raspberry Pi 4 (2 GB+) or 5, **64-bit OS** |
| OS | Raspberry Pi OS Trixie or Bookworm (Debian) / Ubuntu Server |
| Network | A domain on Cloudflare (free plan is fine) |
| Time | ~5 minutes once you have a tunnel token |

## Prepare a Cloudflare Tunnel

1. In the [Cloudflare dashboard](https://dash.cloudflare.com/?to=/:account/tunnels), go to **Networking → Tunnels → Create a tunnel** and name it `ghostberry`.
2. Pick **Docker** and **copy the token**: the long `eyJ…` string after `--token` in the command shown. You don't need to run that command; Ghostberry runs cloudflared for you.
3. On the tunnel's **Routes** tab: **Add route → Published application**.
   - **Subdomain / Domain:** e.g. `blog` + `example.com`
   - **Service URL:** `http://ghost:2368`
4. Select **Add route**.

You'll be asked for that token by the installer. ([Cloudflare's guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/))

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

The installer asks for your domain, your Cloudflare Tunnel token, and how Ghost should send email:

1. **Built-in mail server** (default). No account needed. The installer checks whether your network allows outbound port 25. If not (common on home connections), it offers to relay through a provider such as Brevo or SMTP2GO, still signed with your own DKIM key.
2. **External SMTP provider**: host, port, username, password.
3. **No email for now.**

With the built-in server, the installer ends by printing the DNS records (DKIM, SPF, DMARC) to add in Cloudflare. Print them again any time with `./scripts/mail.sh dns`.

Finally it offers **off-site backups to Cloudflare R2**. Recommended if the Pi runs from an SD card: every nightly backup is copied to R2 (free up to 10 GB), already encrypted. You need an R2 bucket and a bucket-scoped API token; [guides/BACKUP.md](guides/BACKUP.md#off-site-copies-cloudflare-r2) walks through it. Skip it now and turn it on later with `OFFSITE=r2 ./setup.sh`.

For a fully unattended run, pre-set everything:

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh \
  | sudo GHOST_URL=https://blog.example.com \
         CLOUDFLARE_TUNNEL_TOKEN=eyJh... \
         NONINTERACTIVE=1 \
         bash
```

An unattended install uses the built-in mail server in direct-delivery mode. Add a relay, use your own SMTP provider, or turn mail off:

```bash
# built-in server, relaying through a provider
MAIL_RELAY_HOST=smtp-relay.brevo.com MAIL_RELAY_USER=you@example.com MAIL_RELAY_PASSWORD=<key>
# external SMTP instead of the built-in server
MAIL_MODE=smtp MAIL_HOST=smtp.postmarkapp.com MAIL_USER=<token> MAIL_PASSWORD=<token> MAIL_FROM=blog@example.com
# no email
MAIL_MODE=none
```

Optional flags:

| Flag / env | Effect |
|---|---|
| `--harden` | Enables `ufw` (deny-incoming + allow SSH) and `unattended-upgrades` |
| `INSTALL_DIR=/srv/ghost` | Install somewhere other than `/opt/ghostberry` |
| `GHOSTBERRY_REF=v1.2.3` | Pin to a specific git ref |
| `SKIP_DOCKER=1` | Skip the Docker install step |

After install, browse to `https://blog.example.com/ghost` to create the admin account.

## Updating

Run the install command again. That's the whole update:

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

It takes a backup, moves the code to the newest release, pulls the exact
container versions that release pins (Ghost, MySQL, cloudflared, maddy, rclone),
and restarts. Your `.env` settings are kept.

**You don't have to watch for releases.** When a new Ghostberry version is out:

- **Ghost Admin shows a banner** at the top: "Ghostberry x.y.z is available". Ghost's
  daily update check reads Ghostberry's feed instead of Ghost's own.
- **The blog's Owner and Administrators get one email**, sent through the blog's
  own mail setup (built-in server or SMTP provider).

The version on your Pi is in `/opt/ghostberry/VERSION`; what changed is in
[CHANGELOG.md](CHANGELOG.md). Turn notices off with
`UPDATE_NOTICES=off ./setup.sh && docker compose up -d`. That also restores
Ghost's own update feed.

**Pinning one image yourself:** set e.g. `GHOST_IMAGE=ghost:6.80.0-alpine` in `.env`.
A pinned image is never changed by updates until you remove the line again.

### Releasing (maintainers)

In the PR that makes the change: bump `VERSION`, add a `## [x.y.z] - YYYY-MM-DD`
entry at the top of `CHANGELOG.md`, run `tools/build-update-feed.sh` and commit
the regenerated `docs/update-check/`. Merging to `main` publishes it: GitHub Pages
serves the feed, and every install shows the banner within a day.

## Daily life

```bash
cd /opt/ghostberry

# Status / logs
sudo systemctl status ghostberry
docker compose ps
docker compose logs -f

# Off-site copies in Cloudflare R2 (if enabled)
./scripts/offsite.sh status
./scripts/offsite.sh pull latest     # e.g. on a new Pi, before restore.sh

# Manual backup (cron already runs one nightly)
./scripts/backup.sh

# Restore from a backup
./scripts/restore.sh backups/ghost_backup_20260514T021700Z.tar.gz

# Is a newer Ghostberry release out? (a daily cron job also checks)
./scripts/check-update.sh

# Email: DNS records to publish, send a test, check the queue
./scripts/mail.sh dns
./scripts/mail.sh test you@example.com
./scripts/mail.sh status

# Change mail settings (or switch MAIL_MODE), then apply
MAIL_MODE=smtp ./setup.sh && docker compose up -d --remove-orphans
```

## File layout

```
/opt/ghostberry/
├── docker-compose.yml      # services, healthchecks, hardening
├── .env                    # secrets — chmod 600, never commit
├── ghostberry.service      # systemd unit (installed to /etc/systemd/system/)
├── install.sh              # one-shot bootstrapper
├── setup.sh                # idempotent .env writer
├── mail/                   # built-in mail server (maddy) config
│   ├── common.conf         # listener, DKIM signing, queue
│   ├── maddy.conf          # direct delivery
│   └── maddy-relay.conf    # delivery via MAIL_RELAY_HOST
├── scripts/
│   ├── backup.sh           # mysqldump + content tar + DKIM key, AES-256, → R2
│   ├── offsite.sh          # Cloudflare R2: test | push | list | pull | status
│   ├── restore.sh          # inverse of backup
│   ├── check-update.sh     # daily: new release? email the admins once
│   └── mail.sh             # dns | test <addr> | status
├── guides/
│   ├── MAIL.md
│   ├── SECURITY.md
│   ├── BACKUP.md
│   └── TROUBLESHOOTING.md
└── backups/                # local archives (chmod 700)
```

## Security model

- **No published ports.** Nothing on the Pi listens publicly. The only way in is the Cloudflare Tunnel.
- **Container hardening:** all services drop `ALL` capabilities and re-add only what's needed; `no-new-privileges` set; memory caps enforced.
- **Secrets** live only in `.env` (mode `600`) and are never baked into images.
- **Backups** are AES-256-encrypted via OpenSSL (`pbkdf2`, 200k iters) with an auto-generated 40-char passphrase stored in `.env`. Back that file up somewhere safe. Off-site copies in R2 are uploaded already encrypted, with a token limited to one bucket.
- **Mail server is send-only and private.** It joins a dedicated Docker network shared only with Ghost, publishes no ports, only accepts senders from your own domain, and runs read-only with every capability dropped.
- **Optional `--harden`** flag turns on the host firewall and unattended security upgrades.

Full detail in [guides/SECURITY.md](guides/SECURITY.md).

## Troubleshooting

- Ghost not coming up? `sudo journalctl -u ghostberry -e` and `docker compose logs ghost`.
- Tunnel red in the Cloudflare dashboard? `docker compose logs cloudflared` — usually a bad token.
- Out-of-memory on a 2 GB Pi? Lower `GHOST_MEM_LIMIT`/`MYSQL_BUFFER_POOL` in `.env`, then `docker compose up -d`.
- Emails not arriving? `./scripts/mail.sh status`. The usual cause is a blocked port 25 (fix: use a relay). See [guides/MAIL.md](guides/MAIL.md#troubleshooting).

More in [guides/TROUBLESHOOTING.md](guides/TROUBLESHOOTING.md).

## Upgrading from Ghost 5

Ghost 5 no longer gets updates. Re-running the installer moves an install on the old `ghost:5-alpine` default to the Ghost 6 version the current release pins; it takes a backup first. (`./setup.sh` on its own makes the same change but does **not** back up, so run `./scripts/backup.sh` before `docker compose up -d`.) Ghost migrates the database on first start. Before you upgrade:

- Check your theme at [gscan.ghost.org](https://gscan.ghost.org): Ghost 6 removed AMP.
- Custom integrations must stop using `?limit=all` and paginate instead.
- Ghost 6's **ActivityPub ("Network")** and **web analytics** features need extra services (Ghost's ActivityPub service and Tinybird) that Ghostberry doesn't set up yet. Everything else works. You may see a harmless `Could not get webhook secret for ActivityPub` line in the logs.

To stay on Ghost 5 for now, pin it explicitly, e.g. `GHOST_IMAGE=ghost:5.130-alpine`.

## Uninstall

```bash
sudo systemctl disable --now ghostberry
sudo rm /etc/systemd/system/ghostberry.service /etc/cron.d/ghostberry-backup
cd /opt/ghostberry && docker compose --profile mail down -v
sudo rm -rf /opt/ghostberry
```

## License

MIT — see [LICENSE](LICENSE). Ghost is © Ghost Foundation, MIT-licensed.
