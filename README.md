# Ghostberry

**Production-ready Ghost CMS on a Raspberry Pi, fronted by a Cloudflare Tunnel — installable in one command.**

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

That's it. The installer is idempotent — re-run it any time to update the source or re-sync configuration.

---

## What you get

- 🐳 **Ghost 5.x** (Alpine, ARM64-native) + **MySQL 8** + **cloudflared**, wired together with Docker Compose
- 🔒 **Zero exposed ports** — every request reaches Ghost only through your Cloudflare Tunnel (DDoS protection + WAF for free)
- 🛡️ **Hardened containers** — dropped capabilities, `no-new-privileges`, memory caps, log rotation
- 💾 **Daily encrypted backups** via cron, with a real `restore.sh`
- 🚀 **systemd unit** for clean boot/shutdown
- 🍓 **Pi-aware bootstrap** — enables memory cgroups, ensures swap, installs Docker

## Requirements

| | |
|---|---|
| Hardware | Raspberry Pi 4 (2 GB+) or 5, **64-bit OS** |
| OS | Raspberry Pi OS Bookworm (Debian) / Ubuntu Server |
| Network | A domain on Cloudflare (free plan is fine) |
| Time | ~5 minutes once you have a tunnel token |

## Prepare a Cloudflare Tunnel

1. Open [Cloudflare Zero Trust → Networks → Tunnels](https://one.dash.cloudflare.com/).
2. **Create a tunnel** → name it `ghostberry` → pick **Docker** → **copy the token** (the long `eyJ…` string).
3. Add a **Public hostname**:
   - **Subdomain / domain:** `blog.example.com`
   - **Service:** `http://ghost:2368`
4. Save.

You'll be asked for that token by the installer.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

The installer interactively asks for your domain, Cloudflare Tunnel token, and (optionally) SMTP credentials — skip SMTP if you don't have any yet, you can add it later by editing `.env`.

For a fully unattended run, pre-set everything:

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh \
  | sudo GHOST_URL=https://blog.example.com \
         CLOUDFLARE_TUNNEL_TOKEN=eyJh... \
         MAIL_HOST=smtp.postmarkapp.com \
         MAIL_USER=<token> MAIL_PASSWORD=<token> \
         MAIL_FROM=blog@example.com \
         NONINTERACTIVE=1 \
         bash
```

(Mail vars are optional — omit them all to install without email features.)

Optional flags:

| Flag / env | Effect |
|---|---|
| `--harden` | Enables `ufw` (deny-incoming + allow SSH) and `unattended-upgrades` |
| `INSTALL_DIR=/srv/ghost` | Install somewhere other than `/opt/ghostberry` |
| `GHOSTBERRY_REF=v1.2.3` | Pin to a specific git ref |
| `SKIP_DOCKER=1` | Skip the Docker install step |

After install, browse to `https://blog.example.com/ghost` to create the admin account.

## Daily life

```bash
cd /opt/ghostberry

# Status / logs
sudo systemctl status ghostberry
docker compose ps
docker compose logs -f

# Manual backup (cron already runs one nightly)
./scripts/backup.sh

# Restore from a backup
./scripts/restore.sh backups/ghost_backup_20260514T021700Z.tar.gz

# Update Ghost / MySQL / cloudflared images
./scripts/update.sh
```

## File layout

```
/opt/ghostberry/
├── docker-compose.yml      # services, healthchecks, hardening
├── .env                    # secrets — chmod 600, never commit
├── ghostberry.service      # systemd unit (installed to /etc/systemd/system/)
├── install.sh              # one-shot bootstrapper
├── setup.sh                # idempotent .env writer
├── scripts/
│   ├── backup.sh           # mysqldump + content tar, optional AES-256
│   ├── restore.sh          # inverse of backup
│   └── update.sh           # backup → pull → up -d → wait healthy
├── guides/
│   ├── SECURITY.md
│   ├── BACKUP.md
│   └── TROUBLESHOOTING.md
└── backups/                # local archives (chmod 700)
```

## Security model

- **No published ports.** Nothing on the Pi listens publicly. The only way in is the Cloudflare Tunnel.
- **Container hardening:** all services drop `ALL` capabilities and re-add only what's needed; `no-new-privileges` set; memory caps enforced.
- **Secrets** live only in `.env` (mode `600`) and are never baked into images.
- **Backups** are AES-256-encrypted via OpenSSL (`pbkdf2`, 200k iters) with an auto-generated 40-char passphrase stored in `.env`. Back that file up somewhere safe.
- **Optional `--harden`** flag turns on the host firewall and unattended security upgrades.

Full detail in [guides/SECURITY.md](guides/SECURITY.md).

## Troubleshooting

- Ghost not coming up? `sudo journalctl -u ghostberry -e` and `docker compose logs ghost`.
- Tunnel red in the Cloudflare dashboard? `docker compose logs cloudflared` — usually a bad token.
- Out-of-memory on a 2 GB Pi? Lower `GHOST_MEM_LIMIT`/`MYSQL_BUFFER_POOL` in `.env`, then `docker compose up -d`.

More in [guides/TROUBLESHOOTING.md](guides/TROUBLESHOOTING.md).

## Uninstall

```bash
sudo systemctl disable --now ghostberry
sudo rm /etc/systemd/system/ghostberry.service /etc/cron.d/ghostberry-backup
cd /opt/ghostberry && docker compose down -v
sudo rm -rf /opt/ghostberry
```

## License

MIT — see [LICENSE](LICENSE). Ghost is © Ghost Foundation, MIT-licensed.
