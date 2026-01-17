#!/bin/bash

# Ghost CMS Setup Verification Script
# Run this to verify your Ghost installation is working correctly

echo "========================================="
echo "Ghost CMS Setup Verification"
echo "========================================="
echo ""

ERRORS=0
WARNINGS=0

# Check 1: .env file exists
echo "[ 1/10 ] Checking .env configuration..."
if [ -f .env ]; then
    source .env

    if [ ! -z "$GHOST_URL" ] && [ "$GHOST_URL" != "https://blog.yourdomain.com" ]; then
        echo "         ✅ GHOST_URL configured: $GHOST_URL"
    else
        echo "         ❌ GHOST_URL not configured"
        ERRORS=$((ERRORS+1))
    fi

    if [ ! -z "$CLOUDFLARE_TUNNEL_TOKEN" ] && [ "$CLOUDFLARE_TUNNEL_TOKEN" != "your_cloudflare_tunnel_token_here" ]; then
        echo "         ✅ CLOUDFLARE_TUNNEL_TOKEN configured"
    else
        echo "         ❌ CLOUDFLARE_TUNNEL_TOKEN not configured"
        ERRORS=$((ERRORS+1))
    fi

    if [ ! -z "$GHOST_DB_PASSWORD" ] && [ "$GHOST_DB_PASSWORD" != "change_this_to_strong_password_min_32_chars" ]; then
        echo "         ✅ Database passwords configured"
    else
        echo "         ❌ Database passwords not configured"
        ERRORS=$((ERRORS+1))
    fi
else
    echo "         ❌ .env file not found"
    ERRORS=$((ERRORS+1))
fi

# Check 2: Docker is running
echo "[ 2/10 ] Checking Docker..."
if command -v docker &> /dev/null; then
    echo "         ✅ Docker installed"
else
    echo "         ❌ Docker not found"
    ERRORS=$((ERRORS+1))
    exit 1
fi

# Check 3: Containers are running
echo "[ 3/10 ] Checking containers..."
GHOST_STATE=$(docker compose ps ghost --format "{{.State}}" 2>/dev/null)
DB_STATE=$(docker compose ps db --format "{{.State}}" 2>/dev/null)
CF_STATE=$(docker compose ps cloudflared --format "{{.State}}" 2>/dev/null)

if [ "$GHOST_STATE" == "running" ]; then
    echo "         ✅ Ghost container running"
else
    echo "         ❌ Ghost container not running (state: ${GHOST_STATE:-not found})"
    ERRORS=$((ERRORS+1))
fi

if [ "$DB_STATE" == "running" ]; then
    echo "         ✅ Database container running"
else
    echo "         ❌ Database container not running (state: ${DB_STATE:-not found})"
    ERRORS=$((ERRORS+1))
fi

if [ "$CF_STATE" == "running" ]; then
    echo "         ✅ Cloudflared container running"
else
    echo "         ❌ Cloudflared container not running (state: ${CF_STATE:-not found})"
    ERRORS=$((ERRORS+1))
fi

# Check 4: Health checks
echo "[ 4/10 ] Checking container health..."
GHOST_HEALTH=$(docker compose ps ghost --format "{{.Health}}" 2>/dev/null)
DB_HEALTH=$(docker compose ps db --format "{{.Health}}" 2>/dev/null)

if [ "$GHOST_HEALTH" == "healthy" ]; then
    echo "         ✅ Ghost is healthy"
elif [ -z "$GHOST_HEALTH" ]; then
    echo "         ⚠️  Ghost health check not available"
    WARNINGS=$((WARNINGS+1))
else
    echo "         ❌ Ghost is unhealthy"
    ERRORS=$((ERRORS+1))
fi

if [ "$DB_HEALTH" == "healthy" ]; then
    echo "         ✅ Database is healthy"
elif [ -z "$DB_HEALTH" ]; then
    echo "         ⚠️  Database health check not available"
    WARNINGS=$((WARNINGS+1))
else
    echo "         ❌ Database is unhealthy"
    ERRORS=$((ERRORS+1))
fi

# Check 5: Ghost responding internally
echo "[ 5/10 ] Testing Ghost internal response..."
if docker compose exec -T ghost wget --quiet --tries=1 --spider http://localhost:2368 2>/dev/null; then
    echo "         ✅ Ghost responding on port 2368"
else
    echo "         ❌ Ghost not responding"
    ERRORS=$((ERRORS+1))
fi

# Check 6: Cloudflare tunnel connection
echo "[ 6/10 ] Checking Cloudflare tunnel..."
if docker compose logs cloudflared 2>/dev/null | grep -q "registered"; then
    echo "         ✅ Cloudflare tunnel connected"
else
    echo "         ⚠️  Cloudflare tunnel may not be connected"
    echo "         Check logs: docker compose logs cloudflared"
    WARNINGS=$((WARNINGS+1))
fi

# Check 7: No ports exposed
echo "[ 7/10 ] Verifying security (no exposed ports)..."
if grep -q "ports:" docker-compose.yml | grep -A 1 "ghost:" | grep -q "2368"; then
    echo "         ⚠️  Port 2368 is exposed (should use Cloudflare Tunnel only)"
    WARNINGS=$((WARNINGS+1))
else
    echo "         ✅ No ports exposed (Cloudflare Tunnel only)"
fi

# Check 8: Security hardening
echo "[ 8/10 ] Checking security hardening..."
if grep -q "no-new-privileges" docker-compose.yml; then
    echo "         ✅ Container security enabled"
else
    echo "         ⚠️  Security hardening not configured"
    WARNINGS=$((WARNINGS+1))
fi

# Check 9: Backup directory
echo "[ 9/10 ] Checking backup configuration..."
if [ -d "backups" ]; then
    echo "         ✅ Backup directory exists"
else
    echo "         ⚠️  Backup directory not found (will be created on first backup)"
    WARNINGS=$((WARNINGS+1))
fi

if [ -f "scripts/backup.sh" ]; then
    echo "         ✅ Backup script found"
else
    echo "         ❌ Backup script not found at scripts/backup.sh"
    ERRORS=$((ERRORS+1))
fi

# Check 10: External access (if possible)
echo "[ 10/10 ] Testing external access..."
if [ ! -z "$GHOST_URL" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$GHOST_URL" 2>/dev/null)
    if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "301" ] || [ "$HTTP_CODE" == "302" ]; then
        echo "         ✅ Site accessible at $GHOST_URL (HTTP $HTTP_CODE)"
    else
        echo "         ⚠️  Site may not be accessible (HTTP ${HTTP_CODE:-timeout})"
        echo "         Check Cloudflare dashboard: https://one.dash.cloudflare.com/"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "         ⚠️  Cannot test - GHOST_URL not configured"
fi

# Summary
echo ""
echo "========================================="
echo "Verification Summary"
echo "========================================="

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ All checks passed! Your Ghost installation is working correctly."
    echo ""
    echo "Access your site:"
    echo "  - Public: $GHOST_URL"
    echo "  - Admin:  $GHOST_URL/ghost"
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  $WARNINGS warning(s) found. Your Ghost installation is mostly working."
    echo ""
    echo "Review the warnings above and fix if needed."
else
    echo "❌ $ERRORS error(s) and $WARNINGS warning(s) found."
    echo ""
    echo "Please fix the errors above before proceeding."
    echo ""
    echo "Common fixes:"
    echo "  - Configure .env: cp .env.example .env && nano .env"
    echo "  - Start containers: docker compose up -d"
    echo "  - View logs: docker compose logs -f"
fi

echo ""
