# Systemd Service Setup (Optional)

The `ghost.service` file allows Ghost CMS to automatically start when your Raspberry Pi boots up. This is **optional** but highly recommended for production deployments.

## Why Use the Systemd Service?

**Benefits**:
- ✅ Ghost starts automatically on system boot
- ✅ Ghost restarts automatically if the system reboots
- ✅ Easy management with `systemctl` commands
- ✅ Integrates with system logging
- ✅ Production-ready deployment pattern

**Without systemd service**:
- ❌ You must manually start Ghost after each reboot: `docker compose up -d`
- ❌ No automatic recovery after power failures
- ❌ Not suitable for headless/remote deployments

## Installation Steps

### 1. Edit the Service File

First, update the `WorkingDirectory` to match your installation path:

```bash
# Edit the service file
nano ghost.service

# Change this line to your actual path:
WorkingDirectory=/home/pi/ghostberry

# Examples:
# WorkingDirectory=/home/youruser/ghostberry
# WorkingDirectory=/opt/ghost
# WorkingDirectory=/srv/ghost
```

### 2. Install the Service

Copy the service file to the systemd directory:

```bash
# Copy service file
sudo cp ghost.service /etc/systemd/system/

# Reload systemd to recognize the new service
sudo systemctl daemon-reload

# Enable the service to start on boot
sudo systemctl enable ghost.service
```

### 3. Start the Service

```bash
# Start Ghost
sudo systemctl start ghost.service

# Check status
sudo systemctl status ghost.service
```

## Managing the Service

### Common Commands

```bash
# Start Ghost
sudo systemctl start ghost.service

# Stop Ghost
sudo systemctl stop ghost.service

# Restart Ghost
sudo systemctl restart ghost.service

# Check status
sudo systemctl status ghost.service

# View logs
sudo journalctl -u ghost.service -f

# Enable auto-start on boot
sudo systemctl enable ghost.service

# Disable auto-start on boot
sudo systemctl disable ghost.service
```

### Checking if Service is Running

```bash
# Check service status
systemctl is-active ghost.service
# Output: active or inactive

# Check if enabled for boot
systemctl is-enabled ghost.service
# Output: enabled or disabled

# View detailed status
sudo systemctl status ghost.service
```

## Service Behavior

### What Happens on Boot

1. System boots up
2. Docker service starts
3. Network becomes available
4. Ghost service executes `docker compose up -d`
5. All containers start (ghost, db, cloudflared)

### What Happens on Shutdown

1. System shutdown initiated
2. Ghost service executes `docker compose down`
3. Containers stop gracefully
4. System completes shutdown

## Troubleshooting

### Service Fails to Start

```bash
# Check detailed status
sudo systemctl status ghost.service -l

# View full logs
sudo journalctl -u ghost.service -n 50

# Common issues:
# 1. Wrong WorkingDirectory path
# 2. Docker not running
# 3. .env file missing or invalid
# 4. Permissions issues
```

### Verify Working Directory

```bash
# Check if path exists
ls -la /home/pi/ghostberry

# Check if docker-compose.yml exists
ls -la /home/pi/ghostberry/docker-compose.yml

# Test docker compose manually
cd /home/pi/ghostberry
docker compose config
```

### Test Service Manually

```bash
# Try starting manually to see errors
cd /home/pi/ghostberry
sudo /usr/bin/docker compose up -d

# If this works but service doesn't, check WorkingDirectory
```

## Alternative: Cron Job (Simpler Option)

If you don't want to use systemd, you can use a cron job to start Ghost on reboot:

```bash
# Edit crontab
crontab -e

# Add this line (replace path with your installation):
@reboot cd /home/pi/ghostberry && /usr/bin/docker compose up -d
```

**Pros of cron**:
- ✅ Simpler to set up
- ✅ No systemd knowledge needed
- ✅ Works the same way

**Cons of cron**:
- ❌ No service management commands
- ❌ No systemctl integration
- ❌ Less robust error handling

## Uninstalling the Service

If you want to remove the systemd service:

```bash
# Stop the service
sudo systemctl stop ghost.service

# Disable auto-start
sudo systemctl disable ghost.service

# Remove the service file
sudo rm /etc/systemd/system/ghost.service

# Reload systemd
sudo systemctl daemon-reload
```

## Best Practices

### For Production

✅ **DO use systemd service** - Automatic startup is critical

```bash
sudo systemctl enable ghost.service
```

### For Development/Testing

⚠️ **Systemd optional** - Manual start may be preferred

```bash
# Just use docker compose directly
docker compose up -d
docker compose down
```

### For Remote/Headless Raspberry Pi

✅ **MUST use systemd service** - Essential for reliability

```bash
sudo systemctl enable ghost.service
```

## Monitoring Service Status

### Create a Status Check Script

```bash
#!/bin/bash
# /usr/local/bin/ghost-status.sh

echo "=== Ghost Service Status ==="
systemctl is-active ghost.service && echo "✅ Service: Active" || echo "❌ Service: Inactive"

echo ""
echo "=== Container Status ==="
cd /home/pi/ghostberry
docker compose ps

echo ""
echo "=== Health Checks ==="
docker compose ps | grep -q "healthy" && echo "✅ Containers: Healthy" || echo "⚠️  Check container health"

echo ""
echo "=== Disk Usage ==="
df -h / | grep -v Filesystem
```

Make it executable:
```bash
chmod +x /usr/local/bin/ghost-status.sh
```

Run it:
```bash
ghost-status.sh
```

## Comparison: Docker Restart vs Systemd

### Docker's Built-in Restart Policy

The docker-compose.yml uses `restart: unless-stopped`:

```yaml
restart: unless-stopped
```

**What this does**:
- Containers restart if they crash
- Containers restart if Docker daemon restarts
- Containers DON'T start automatically on system boot (unless Docker starts them)

### Systemd Service

The systemd service ensures:
- Docker Compose is run on system boot
- All containers are started together
- Proper dependencies (Docker must be running first)

### Best Approach: Use Both

✅ **Recommended**: Keep `restart: unless-stopped` in docker-compose.yml AND use systemd service

This provides:
1. Container-level restart (if individual container crashes)
2. System-level startup (when Raspberry Pi boots)
3. Proper dependency management
4. Easy management with systemctl

## Summary

**Is the systemd service needed?**

| Scenario | Systemd Service | Alternative |
|----------|----------------|-------------|
| Production deployment | ✅ **Required** | None - must use |
| Remote/headless Pi | ✅ **Required** | Cron job (less robust) |
| Home server/always-on | ✅ **Highly recommended** | Manual start each boot |
| Development/testing | ⚠️ Optional | Manual `docker compose up -d` |
| Learning/experimenting | ⚠️ Optional | Manual start is fine |

**Recommendation**: Unless you're just testing, **install the systemd service**. It takes 2 minutes and makes your deployment production-ready.

## Quick Installation (TL;DR)

```bash
# 1. Edit WorkingDirectory in ghost.service
nano ghost.service

# 2. Install and enable
sudo cp ghost.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ghost.service
sudo systemctl start ghost.service

# 3. Verify
sudo systemctl status ghost.service
```

Done! Ghost will now start automatically on every boot.
