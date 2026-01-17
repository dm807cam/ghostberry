# Ghost CMS on Raspberry Pi with Cloudflare Tunnel

Production-ready Docker Compose setup for running Ghost CMS on a Raspberry Pi, secured behind a Cloudflare Tunnel.

> **🔒 Security Notice**: This deployment follows security best practices including no direct port exposure, container hardening, and encrypted backups. Review [SECURITY.md](SECURITY.md) before production deployment.

## Features

- 🚀 Ghost CMS 5.x (Alpine-based for ARM compatibility)
- 🔒 Cloudflare Tunnel (zero-trust networking, no ports exposed, DDoS protection)
- 💾 MySQL 8.0 database with optimized settings for Raspberry Pi
- 📧 Email support (SMTP configuration)
- 💪 Health checks and automatic restarts
- 📦 Automated backup solution with optional encryption
- 🔐 Environment-based secure configuration
- 🛡️ Container security hardening (capability dropping, resource limits)
- 📊 Log rotation to prevent disk exhaustion

## Prerequisites

- Raspberry Pi (3B+ or newer recommended)
- Raspberry Pi OS (64-bit recommended)
- Docker and Docker Compose installed
- Cloudflare account with a domain
- At least 2GB RAM recommended

## Quick Start

### 1. Install Docker (if not already installed)

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker

# Install Docker Compose
sudo apt-get install -y docker-compose
```

### 2. Setup Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
2. Navigate to **Networks** → **Tunnels**
3. Click **Create a tunnel**
4. Choose **Cloudflared** and give it a name (e.g., "ghost-pi")
5. Copy the tunnel token (you'll need this)
6. Configure the tunnel:
   - **Public hostname**: Your domain (e.g., blog.yourdomain.com)
   - **Service**: `http://ghost:2368`
7. Save the tunnel

### 3. Configure Environment Variables

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your actual values
nano .env
```

Update these critical values in `.env`:
- `GHOST_DB_PASSWORD`: Strong database password
- `MYSQL_ROOT_PASSWORD`: Strong root password
- `CLOUDFLARE_TUNNEL_TOKEN`: Token from Cloudflare dashboard
- Mail settings (if you want email notifications)

### 4. Update Ghost URL

Edit `docker-compose.yml` and change:
```yaml
url: https://yourdomain.com
```
to your actual domain (e.g., `https://blog.yourdomain.com`)

### 5. Create Required Directories

```bash
mkdir -p backups scripts
mv backup.sh scripts/
chmod +x scripts/backup.sh
```

### 6. Start the Services

```bash
# Start all services
docker compose up -d

# Check logs
docker compose logs -f

# Verify services are running
docker compose ps
```

### 7. Access Ghost Admin

1. Wait about 30-60 seconds for all services to start
2. Navigate to `https://yourdomain.com/ghost`
3. Create your admin account
4. Start blogging!

## Management Commands

### View Logs
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f ghost
docker compose logs -f cloudflared
```

### Restart Services
```bash
# Restart all
docker compose restart

# Restart specific service
docker compose restart ghost
```

### Stop Services
```bash
docker compose down
```

### Update Ghost
```bash
# Pull latest images
docker compose pull

# Recreate containers
docker compose up -d
```

## Backup & Restore

### Create Backup
```bash
# Manual backup
docker compose run --rm db_backup /backup.sh

# Check backups
ls -lh backups/
```

### Automated Backups (Cron)
```bash
# Edit crontab
crontab -e

# Add this line for daily backups at 2 AM
0 2 * * * cd /path/to/ghost && /usr/bin/docker compose run --rm db_backup /backup.sh >> /var/log/ghost-backup.log 2>&1
```

### Restore from Backup
```bash
# Stop Ghost to prevent database changes
docker compose stop ghost

# Restore the backup
gunzip < backups/ghost_backup_YYYYMMDD_HHMMSS.sql.gz | \
docker compose exec -T db mysql -u ghost -p${GHOST_DB_PASSWORD} ghost

# Restart Ghost
docker compose start ghost
```

## Troubleshooting

### Ghost won't start
```bash
# Check logs
docker compose logs ghost

# Verify database is ready
docker compose exec db mysqladmin ping -h localhost -u ghost -p
```

### Cloudflare Tunnel not connecting
```bash
# Check cloudflared logs
docker compose logs cloudflared

# Verify token is correct in .env file
grep CLOUDFLARE_TUNNEL_TOKEN .env

# Restart cloudflared
docker compose restart cloudflared
```

### Out of Memory (Raspberry Pi)
```bash
# Check memory usage
docker stats

# Reduce MySQL buffer pool (in docker-compose.yml)
# Change: --innodb-buffer-pool-size=128M to 64M
```

### Database connection errors
```bash
# Check database health
docker compose exec db mysqladmin ping -h localhost -u ghost -p

# Restart database
docker compose restart db

# Wait for health check, then restart Ghost
docker compose restart ghost
```

## Performance Optimization for Raspberry Pi

The Docker Compose file includes optimizations for Raspberry Pi:
- MySQL performance schema disabled
- Reduced InnoDB buffer pool (128MB)
- Alpine-based Ghost image (smaller footprint)
- Health checks to ensure services are ready

### Additional Tweaks
If you experience performance issues:

1. **Reduce MySQL memory**:
   - Change `--innodb-buffer-pool-size=128M` to `64M`

2. **Enable swap** (if not already enabled):
```bash
sudo dphys-swapfile swapoff
sudo nano /etc/dphys-swapfile
# Set CONF_SWAPSIZE=2048
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
```

3. **Monitor resources**:
```bash
docker stats
```

## Security Best Practices

For comprehensive security documentation, see [SECURITY.md](SECURITY.md).

**Critical Security Requirements**:

1. ✅ **Use strong passwords** (32+ characters) in `.env`
2. ✅ **Protect .env file**: `chmod 600 .env` and verify it's in `.gitignore`
3. ✅ **Never commit secrets** to version control
4. ✅ **No direct port exposure**: Ghost is ONLY accessible via Cloudflare Tunnel
   - For local troubleshooting: `docker compose exec ghost wget http://localhost:2368`
5. ✅ **Enable backup encryption**: Set `BACKUP_ENCRYPTION_KEY` in `.env`
6. ✅ **Regularly update images**: `docker compose pull && docker compose up -d`
7. ✅ **Enable automatic backups** with cron (see Backup section)
8. ✅ **Monitor logs** for suspicious activity
9. ✅ **Keep Raspberry Pi OS updated**: `sudo apt update && sudo apt upgrade`
10. ✅ **Configure Cloudflare WAF rules** and rate limiting

**Resource Limits**: Containers have memory and CPU limits configured for Raspberry Pi. Adjust in `docker-compose.yml` if needed.

**Container Hardening**: All containers run with:
- Dropped capabilities (principle of least privilege)
- `no-new-privileges` flag
- Log rotation (prevents disk exhaustion)
- Specific version pinning (no :latest tags)

## Email Configuration

Ghost needs email to send notifications, password resets, etc. Configure one of these providers:

### Mailgun (Recommended)
```env
MAIL_HOST=smtp.mailgun.org
MAIL_PORT=587
MAIL_USER=postmaster@mg.yourdomain.com
MAIL_PASSWORD=your_mailgun_password
```

### Gmail
```env
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_USER=your.email@gmail.com
MAIL_PASSWORD=your_app_specific_password
```

### SendGrid
```env
MAIL_HOST=smtp.sendgrid.net
MAIL_PORT=587
MAIL_USER=apikey
MAIL_PASSWORD=your_sendgrid_api_key
```

## Monitoring

### Check Service Health
```bash
# Service status
docker compose ps

# Health checks
docker inspect ghost | grep -A 10 Health
docker inspect ghost_db | grep -A 10 Health
```

### Resource Usage
```bash
# Real-time stats
docker stats

# Disk usage
docker system df
```

## Updating

```bash
# Backup first!
docker compose run --rm db_backup /backup.sh

# Pull new images
docker compose pull

# Recreate containers
docker compose up -d

# Check logs
docker compose logs -f
```

## File Structure

```
.
├── docker-compose.yml      # Main Docker Compose configuration
├── .env                    # Environment variables (create from .env.example)
├── .env.example           # Template for environment variables
├── backups/               # Database backup directory
│   └── ghost_backup_*.sql.gz
└── scripts/
    └── backup.sh          # Backup script
```

## Support

- Ghost Documentation: https://ghost.org/docs/
- Cloudflare Tunnel Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/
- Docker Compose: https://docs.docker.com/compose/

## License

This configuration is provided as-is for your use. Ghost CMS is licensed under the MIT License.
