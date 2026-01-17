# Security Guide for Ghost CMS on Raspberry Pi

This document outlines the security measures implemented in this deployment and provides recommendations for maintaining a secure Ghost CMS installation.

## Table of Contents

1. [Security Architecture](#security-architecture)
2. [Critical Security Measures](#critical-security-measures)
3. [Environment Variables](#environment-variables)
4. [Network Security](#network-security)
5. [Container Security](#container-security)
6. [Backup Security](#backup-security)
7. [Monitoring & Maintenance](#monitoring--maintenance)
8. [Incident Response](#incident-response)
9. [Security Checklist](#security-checklist)

---

## Security Architecture

### Zero-Trust Network Access

This deployment uses **Cloudflare Tunnel** for zero-trust network access:
- ✅ No ports exposed to the internet
- ✅ DDoS protection built-in
- ✅ Web Application Firewall (WAF) available
- ✅ Encrypted tunnel to Cloudflare's edge network
- ✅ Access policies can be configured in Cloudflare Zero Trust

### Defense in Depth

Multiple security layers protect your Ghost installation:
1. **Network Layer**: Cloudflare Tunnel (no direct port exposure)
2. **Container Layer**: Hardened containers with minimal capabilities
3. **Application Layer**: Ghost with secure configuration
4. **Data Layer**: Encrypted backups, secure database credentials

---

## Critical Security Measures

### 1. Strong Passwords

**CRITICAL**: Use strong, unique passwords for all credentials.

Generate secure passwords:
```bash
# Generate a 32-character password
openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
```

Required passwords in `.env`:
- `GHOST_DB_PASSWORD` - Minimum 32 characters
- `MYSQL_ROOT_PASSWORD` - Minimum 32 characters, different from above
- `CLOUDFLARE_TUNNEL_TOKEN` - From Cloudflare dashboard
- `MAIL_PASSWORD` - From your email provider
- `BACKUP_ENCRYPTION_KEY` - For encrypting backups (optional but recommended)

### 2. Environment File Protection

**CRITICAL**: Never commit `.env` to version control.

```bash
# Set secure permissions on .env file
chmod 600 .env

# Verify .gitignore includes .env
grep -q "^\.env$" .gitignore || echo ".env" >> .gitignore

# Verify .env is not tracked by git
git ls-files | grep -q "^\.env$" && echo "WARNING: .env is tracked!" || echo "✓ .env is not tracked"
```

### 3. No Direct Port Exposure

**IMPORTANT**: Port 2368 is NOT exposed to the host machine.

Ghost is **only** accessible via Cloudflare Tunnel. This prevents:
- Direct attacks on Ghost application
- Bypass of Cloudflare's DDoS protection
- Bypass of Web Application Firewall
- Unauthorized access from local network

For local troubleshooting:
```bash
# Access Ghost from within the container
docker compose exec ghost wget -O- http://localhost:2368

# View logs
docker compose logs -f ghost
```

### 4. Container Hardening

All containers implement security best practices:

**Capability Dropping**:
- All unnecessary Linux capabilities are dropped
- Only essential capabilities retained
- Prevents privilege escalation attacks

**No New Privileges**:
- `no-new-privileges:true` flag set
- Prevents processes from gaining additional privileges
- Mitigates SUID binary exploits

**Resource Limits**:
- Memory limits prevent OOM exhaustion
- CPU limits ensure fair resource sharing
- Critical for Raspberry Pi's limited resources

---

## Environment Variables

### Required Variables

Create `.env` from `.env.example`:
```bash
cp .env.example .env
chmod 600 .env
nano .env
```

### Variable Security

1. **Never use default values** in production
2. **Never commit** `.env` to version control
3. **Rotate passwords** quarterly or after suspected compromise
4. **Use different passwords** for each service
5. **Backup `.env`** securely (encrypted, offline)

### Testing Configuration

Verify environment variables are loaded:
```bash
# Check that variables are set (without revealing values)
docker compose config | grep -c "GHOST_DB_PASSWORD" && echo "✓ Variables loaded"
```

---

## Network Security

### Cloudflare Tunnel Configuration

1. **Access Policies**: Configure in Cloudflare Zero Trust dashboard
   - Restrict admin panel (`/ghost/*`) by IP or email
   - Require authentication for sensitive endpoints
   - Enable rate limiting

2. **WAF Rules**: Enable Web Application Firewall
   ```
   - Block SQL injection attempts
   - Block XSS attempts
   - Rate limit login endpoints
   - Block malicious bots
   ```

3. **DDoS Protection**: Automatically enabled with Cloudflare

### Firewall Rules (Raspberry Pi)

Even though no ports are exposed, enable UFW firewall:
```bash
# Enable firewall
sudo ufw enable

# Allow SSH (if using SSH)
sudo ufw allow ssh

# Deny all other incoming by default
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Check status
sudo ufw status verbose
```

### Internal Network Isolation

Containers communicate over private `ghost_network`:
- Database only accessible by Ghost container
- Cloudflared only communicates with Ghost, not database
- No external bridge to host network

---

## Container Security

### Image Security

**Version Pinning**: All images pinned to specific versions
```yaml
ghost:5.96.0-alpine      # Specific Ghost version
mysql:8.0.36             # Specific MySQL version
cloudflared:2024.12.2    # Specific Cloudflare version
```

**Benefits**:
- Predictable deployments
- No surprise breaking changes
- Control over updates
- Ability to test before upgrading

**Update Process**:
```bash
# 1. Backup first
docker compose run --rm ghost_backup /backup.sh

# 2. Update image versions in docker-compose.yml

# 3. Pull new images
docker compose pull

# 4. Test in development first (if possible)

# 5. Deploy
docker compose up -d

# 6. Verify health
docker compose ps
docker compose logs -f
```

### Security Scanning

Scan images for vulnerabilities:
```bash
# Using Docker Scout (if available)
docker scout cves ghost:5.96.0-alpine

# Using Trivy
docker run --rm aquasec/trivy image ghost:5.96.0-alpine
```

### Read-Only Root Filesystem

Consider making root filesystem read-only:
```yaml
security_opt:
  - no-new-privileges:true
read_only: true
tmpfs:
  - /tmp
  - /var/run
```

⚠️ **Note**: Some containers may require writable filesystem. Test before enabling.

---

## Backup Security

### Backup Encryption

**HIGHLY RECOMMENDED**: Encrypt all backups.

1. **Enable encryption** in `.env`:
   ```bash
   BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
   ```

2. **Verify encryption** is working:
   ```bash
   # Create backup
   docker compose run --rm ghost_backup /backup.sh

   # Check if encrypted (.gpg extension)
   ls -lh backups/*.gpg
   ```

3. **Store encryption key securely**:
   - Use a password manager
   - Store offline backup of key
   - Never commit to git

### Backup Storage

**Security recommendations**:

1. **Off-site backups**: Don't store only on Raspberry Pi
   ```bash
   # Automated offsite backup example (use with cron)
   rsync -avz --delete backups/ user@backup-server:/backups/ghost/
   ```

2. **Cloud backup with encryption**:
   ```bash
   # Example: Encrypted backup to AWS S3
   aws s3 cp backups/ s3://your-bucket/ghost-backups/ \
     --recursive \
     --storage-class GLACIER
   ```

3. **Backup verification**: Test restores quarterly
   ```bash
   # Test restore on development system
   ./restore.sh backups/ghost_backup_YYYYMMDD_HHMMSS.tar.gz
   ```

### Backup Access Control

Protect backup directory:
```bash
# Set restrictive permissions
chmod 700 backups/
chown $(whoami):$(whoami) backups/

# Verify
ls -ld backups/
```

### Backup Retention

Default: 7 backups retained

For production, implement tiered retention:
- 7 daily backups
- 4 weekly backups
- 12 monthly backups
- Offsite backups retained for 1 year

---

## Monitoring & Maintenance

### Health Monitoring

Create monitoring script `/usr/local/bin/ghost-monitor.sh`:
```bash
#!/bin/bash
# Ghost CMS Health Monitor

LOG_FILE="/var/log/ghost-monitor.log"
ALERT_EMAIL="admin@yourdomain.com"

# Check container health
UNHEALTHY=$(docker compose ps | grep -c "unhealthy")
if [ $UNHEALTHY -gt 0 ]; then
  echo "[$(date)] WARNING: Unhealthy containers detected" | tee -a $LOG_FILE
  docker compose ps >> $LOG_FILE
fi

# Check disk space
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 85 ]; then
  echo "[$(date)] WARNING: Disk usage at ${DISK_USAGE}%" | tee -a $LOG_FILE
fi

# Check backup age
LAST_BACKUP=$(ls -t backups/ghost_backup_*.tar.gz 2>/dev/null | head -1)
if [ ! -z "$LAST_BACKUP" ]; then
  BACKUP_AGE=$(( ($(date +%s) - $(stat -c %Y "$LAST_BACKUP")) / 86400 ))
  if [ $BACKUP_AGE -gt 2 ]; then
    echo "[$(date)] WARNING: Last backup is ${BACKUP_AGE} days old" | tee -a $LOG_FILE
  fi
fi

# Check memory usage
MEM_USAGE=$(free | grep Mem | awk '{printf "%.0f", ($3/$2) * 100}')
if [ $MEM_USAGE -gt 90 ]; then
  echo "[$(date)] WARNING: Memory usage at ${MEM_USAGE}%" | tee -a $LOG_FILE
fi
```

Make it executable and add to cron:
```bash
chmod +x /usr/local/bin/ghost-monitor.sh

# Add to crontab (run every hour)
crontab -e
# Add: 0 * * * * /usr/local/bin/ghost-monitor.sh
```

### Security Updates

**Monthly security maintenance**:
```bash
#!/bin/bash
# Monthly security update routine

# 1. Update Raspberry Pi OS
sudo apt update && sudo apt upgrade -y

# 2. Backup before updates
docker compose run --rm ghost_backup /backup.sh

# 3. Update Docker images
docker compose pull

# 4. Restart with new images
docker compose up -d

# 5. Verify health
sleep 30
docker compose ps
docker compose logs --tail=50

# 6. Check for vulnerabilities
docker scout cves ghost:5.96.0-alpine
```

### Log Monitoring

Monitor logs for suspicious activity:
```bash
# Search for failed login attempts
docker compose logs ghost | grep -i "failed\|unauthorized\|forbidden"

# Monitor real-time
docker compose logs -f ghost | grep -i "error\|warn"

# Check database errors
docker compose logs db | grep -i "error"
```

---

## Incident Response

### Suspected Compromise

If you suspect a security breach:

1. **Immediate Actions**:
   ```bash
   # Isolate the system
   docker compose down

   # Backup current state for forensics
   docker compose run --rm ghost_backup /backup.sh
   tar czf incident-$(date +%Y%m%d).tar.gz backups/ .env docker-compose.yml
   ```

2. **Investigate**:
   ```bash
   # Review logs for suspicious activity
   docker compose logs ghost > ghost-logs.txt
   docker compose logs db > db-logs.txt

   # Check file modifications
   find /var/lib/docker/volumes -type f -mtime -1
   ```

3. **Rotate Credentials**:
   ```bash
   # Generate new passwords
   NEW_DB_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
   NEW_ROOT_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

   # Update .env file
   # Update in docker-compose.yml
   # Restart services
   ```

4. **Restore from Known-Good Backup**:
   ```bash
   # Restore from before suspected compromise
   ./restore.sh backups/ghost_backup_YYYYMMDD_HHMMSS.tar.gz
   ```

5. **Contact Support**:
   - Ghost: https://ghost.org/help/
   - Cloudflare: https://support.cloudflare.com/

### Failed Login Monitoring

Enable Cloudflare Access Policies to:
- Require email verification for admin panel
- Enable rate limiting on `/ghost/api/admin/session`
- Configure IP allowlist for admin access
- Enable 2FA for Ghost admin accounts

---

## Security Checklist

### Initial Setup
- [ ] Create `.env` from `.env.example`
- [ ] Generate strong passwords (32+ characters)
- [ ] Set `.env` permissions to 600
- [ ] Verify `.env` not tracked by git
- [ ] Configure Cloudflare Tunnel with access policies
- [ ] Update Ghost URL in `docker-compose.yml`
- [ ] Enable UFW firewall on Raspberry Pi
- [ ] Configure backup encryption key

### Before Production
- [ ] Enable Cloudflare WAF rules
- [ ] Configure rate limiting in Cloudflare
- [ ] Set up offsite backup storage
- [ ] Test backup and restore process
- [ ] Enable monitoring script (cron)
- [ ] Configure email alerts
- [ ] Enable 2FA on Ghost admin accounts
- [ ] Review Cloudflare security settings
- [ ] Pin all image versions
- [ ] Document recovery procedures

### Monthly Maintenance
- [ ] Update Raspberry Pi OS packages
- [ ] Update Docker images (after testing)
- [ ] Review container logs for errors
- [ ] Verify backups are running
- [ ] Test restore from backup
- [ ] Check disk space usage
- [ ] Review Cloudflare access logs
- [ ] Scan images for vulnerabilities
- [ ] Verify monitoring alerts working
- [ ] Review and rotate access logs

### Quarterly
- [ ] Rotate database passwords
- [ ] Review Cloudflare access policies
- [ ] Test incident response plan
- [ ] Review security documentation
- [ ] Audit user accounts in Ghost
- [ ] Update security contact information
- [ ] Test disaster recovery plan
- [ ] Review backup retention policy

### Annually
- [ ] Comprehensive security audit
- [ ] Review all access credentials
- [ ] Update Ghost to latest LTS version
- [ ] Review and update security policies
- [ ] Disaster recovery drill
- [ ] Review cloud provider security settings

---

## Additional Resources

### Security Tools
- **Docker Scout**: Image vulnerability scanning
- **Trivy**: Container security scanner
- **OWASP ZAP**: Web application security testing
- **Fail2ban**: Intrusion prevention

### Documentation
- Ghost Security: https://ghost.org/docs/security/
- Cloudflare Zero Trust: https://developers.cloudflare.com/cloudflare-one/
- Docker Security: https://docs.docker.com/engine/security/
- CIS Docker Benchmark: https://www.cisecurity.org/benchmark/docker

### Security Contacts
- Report Ghost vulnerabilities: security@ghost.org
- Report Cloudflare issues: https://www.cloudflare.com/disclosure/
- Docker security: security@docker.com

---

## Reporting Security Issues

If you discover a security vulnerability in this configuration:

1. **Do NOT** open a public GitHub issue
2. Email the repository maintainer directly
3. Include detailed information about the vulnerability
4. Allow 90 days for remediation before public disclosure

---

## License

This security documentation is provided as-is. Use at your own risk.

Last Updated: 2026-01-17
