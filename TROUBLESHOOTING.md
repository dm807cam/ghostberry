# Ghost CMS Troubleshooting Guide

## Quick Diagnostics

Run this command to check overall system health:
```bash
docker compose ps && docker compose logs --tail=50
```

## Common Issues

### 1. Ghost Container Won't Start

**Symptoms:** Ghost container keeps restarting or exits immediately

**Solutions:**

a) Check if database is ready:
```bash
docker compose logs db | grep "ready for connections"
```

b) Verify environment variables:
```bash
docker compose config
```

c) Check Ghost logs:
```bash
docker compose logs ghost
```

d) Ensure database password matches:
```bash
grep GHOST_DB_PASSWORD .env
docker compose exec db mysql -u ghost -p${GHOST_DB_PASSWORD} -e "SELECT 1"
```

### 2. Cloudflare Tunnel Not Connecting

**Symptoms:** Cannot access site via domain, cloudflared container errors

**Solutions:**

a) Verify tunnel token:
```bash
grep CLOUDFLARE_TUNNEL_TOKEN .env
```

b) Check cloudflared logs:
```bash
docker compose logs cloudflared | tail -20
```

c) Test if Ghost is accessible locally:
```bash
curl -I http://localhost:2368
```

d) Restart cloudflared:
```bash
docker compose restart cloudflared
```

e) Check Cloudflare dashboard:
- Go to Zero Trust → Networks → Tunnels
- Verify tunnel shows as "HEALTHY"
- Check public hostname configuration points to `http://ghost:2368`

### 3. Database Connection Failed

**Symptoms:** "Error: ER_ACCESS_DENIED_ERROR" or "Can't connect to MySQL server"

**Solutions:**

a) Verify database is running:
```bash
docker compose ps db
```

b) Check database health:
```bash
docker compose exec db mysqladmin ping -h localhost -u root -p
```

c) Reset database password:
```bash
docker compose down
docker compose up -d db
# Wait 30 seconds
docker compose exec db mysql -u root -p -e "ALTER USER 'ghost'@'%' IDENTIFIED BY 'your_password';"
docker compose up -d
```

### 4. Out of Memory Errors

**Symptoms:** Containers crashing, system freezing, OOMKilled in logs

**Solutions:**

a) Check memory usage:
```bash
free -h
docker stats --no-stream
```

b) Reduce MySQL buffer pool (edit docker-compose.yml):
```yaml
command:
  - '--innodb-buffer-pool-size=64M'  # Reduce from 128M
```

c) Enable swap:
```bash
sudo dphys-swapfile swapoff
sudo nano /etc/dphys-swapfile
# Set CONF_SWAPSIZE=2048
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
```

d) Limit container memory:
Add to ghost service in docker-compose.yml:
```yaml
deploy:
  resources:
    limits:
      memory: 512M
```

### 5. Cannot Access Ghost Admin

**Symptoms:** 404 error on /ghost, unable to create admin account

**Solutions:**

a) Verify Ghost URL is correct:
```bash
docker compose exec ghost cat /var/lib/ghost/config.production.json | grep url
```

b) Check if you're using HTTPS in URL but accessing via HTTP:
- Ghost URL should match your Cloudflare tunnel domain
- Edit docker-compose.yml and set correct URL

c) Clear browser cache and cookies

d) Try accessing directly: `http://raspberry-pi-ip:2368/ghost`

### 6. Email Not Sending

**Symptoms:** Password resets fail, invitation emails not received

**Solutions:**

a) Verify mail configuration:
```bash
grep MAIL .env
```

b) Test SMTP credentials manually:
```bash
docker compose exec ghost npm install -g maildev
# Use a mail testing service like Mailtrap
```

c) Check Ghost logs for email errors:
```bash
docker compose logs ghost | grep -i mail
```

d) Common mail providers:
- **Gmail**: Enable "App Passwords" in Google Account settings
- **Mailgun**: Verify domain and use SMTP credentials
- **SendGrid**: Use API key as password

### 7. Performance Issues

**Symptoms:** Slow page loads, high CPU usage

**Solutions:**

a) Monitor resources:
```bash
docker stats
htop  # Install with: sudo apt-get install htop
```

b) Check disk space:
```bash
df -h
docker system df
```

c) Clean up Docker:
```bash
docker system prune -a --volumes
```

d) Optimize images:
```bash
# Enable Ghost image optimization in admin panel
# Settings → Labs → Image optimization
```

e) Use Cloudflare caching:
- Enable Cloudflare caching rules for static assets
- Set cache TTL for images, CSS, JS

### 8. Port 2368 Already in Use

**Symptoms:** "port is already allocated" error

**Solutions:**

a) Check what's using the port:
```bash
sudo lsof -i :2368
sudo netstat -tulpn | grep 2368
```

b) Change port in docker-compose.yml:
```yaml
ports:
  - "3000:2368"  # Use port 3000 instead
```

c) Stop conflicting service:
```bash
sudo systemctl stop <service-name>
```

### 9. Permission Denied Errors

**Symptoms:** Cannot write to volumes, permission errors in logs

**Solutions:**

a) Fix volume permissions:
```bash
docker compose down
sudo chown -R 1000:1000 ./ghost_content 2>/dev/null || true
docker compose up -d
```

b) Check Docker group membership:
```bash
groups $USER
# Should include "docker"
# If not: sudo usermod -aG docker $USER && newgrp docker
```

### 10. Backup Fails

**Symptoms:** Backup script errors, empty backup files

**Solutions:**

a) Check backup script permissions:
```bash
ls -l scripts/backup.sh
chmod +x scripts/backup.sh
```

b) Verify database connectivity:
```bash
docker compose exec db mysql -u ghost -p${GHOST_DB_PASSWORD} -e "SHOW DATABASES;"
```

c) Check disk space:
```bash
df -h
```

d) Run backup manually:
```bash
docker compose run --rm db_backup /backup.sh
```

## Advanced Debugging

### Enable Debug Logging

Edit docker-compose.yml and add to Ghost environment:
```yaml
environment:
  logging__level: debug
```

Then restart:
```bash
docker compose up -d
docker compose logs -f ghost
```

### Access Container Shell

```bash
# Ghost container
docker compose exec ghost sh

# Database container
docker compose exec db bash

# Check Ghost config
docker compose exec ghost cat /var/lib/ghost/config.production.json
```

### Network Connectivity Tests

```bash
# Test from Ghost to database
docker compose exec ghost ping db

# Test from Ghost to internet
docker compose exec ghost ping 1.1.1.1

# Test DNS resolution
docker compose exec ghost nslookup google.com
```

### Database Inspection

```bash
# Connect to MySQL
docker compose exec db mysql -u ghost -p${GHOST_DB_PASSWORD} ghost

# Useful queries:
SHOW TABLES;
SELECT * FROM users;
SELECT * FROM posts LIMIT 5;
SHOW VARIABLES LIKE 'max_connections';
```

### Complete Reset (Nuclear Option)

⚠️ **WARNING: This deletes all data!**

```bash
# Backup first!
docker compose run --rm db_backup /backup.sh

# Complete cleanup
docker compose down -v
sudo rm -rf ghost_content ghost_db
docker compose up -d
```

## Monitoring Setup

### Install Monitoring Tools

```bash
# Install htop for system monitoring
sudo apt-get install -y htop

# Monitor in real-time
watch -n 2 'docker stats --no-stream'
```

### Log Rotation

Add to /etc/docker/daemon.json:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Then restart Docker:
```bash
sudo systemctl restart docker
docker compose up -d
```

## Getting Help

1. Check Ghost logs: `docker compose logs ghost`
2. Check all logs: `docker compose logs`
3. View this file: `cat TROUBLESHOOTING.md`
4. Ghost Forum: https://forum.ghost.org/
5. Cloudflare Community: https://community.cloudflare.com/

## System Information Commands

```bash
# Raspberry Pi model
cat /proc/device-tree/model

# OS version
cat /etc/os-release

# Memory info
free -h

# Disk space
df -h

# Docker version
docker --version
docker compose version

# Container status
docker compose ps

# Network info
docker network ls
docker network inspect ghost_ghost_network
```
