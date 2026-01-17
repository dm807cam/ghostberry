#!/bin/bash

# Ghost CMS Setup Script for Raspberry Pi
# This script helps you set up Ghost CMS with Cloudflare Tunnel

set -e

echo "========================================="
echo "Ghost CMS + Cloudflare Tunnel Setup"
echo "========================================="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo "❌ Please do not run as root"
    exit 1
fi

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed"
    echo "Install with: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Check for Docker Compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not installed"
    echo "Install with: sudo apt-get install -y docker-compose"
    exit 1
fi

echo "✅ Docker is installed"
echo ""

# Create directories
echo "Creating required directories..."
mkdir -p backups scripts
echo "✅ Directories created"
echo ""

# Move backup script
if [ -f "backup.sh" ] && [ ! -f "scripts/backup.sh" ]; then
    mv backup.sh scripts/
    chmod +x scripts/backup.sh
    echo "✅ Backup script configured"
fi

# Check for .env file
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        echo "Creating .env file..."
        cp .env.example .env
        echo "✅ .env file created from template"
        echo ""
        echo "⚠️  IMPORTANT: You must edit .env file with your actual values!"
        echo ""
        read -p "Enter your domain (e.g., https://blog.yourdomain.com): " DOMAIN
        read -p "Enter Cloudflare Tunnel Token: " CF_TOKEN

        # Ensure domain has https:// prefix
        if [[ ! "$DOMAIN" =~ ^https?:// ]]; then
            DOMAIN="https://${DOMAIN}"
        fi

        # Generate random passwords
        DB_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        ROOT_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

        # Update .env file
        sed -i "s|GHOST_URL=.*|GHOST_URL=${DOMAIN}|" .env
        sed -i "s|GHOST_DB_PASSWORD=.*|GHOST_DB_PASSWORD=${DB_PASS}|" .env
        sed -i "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${ROOT_PASS}|" .env
        sed -i "s|CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=${CF_TOKEN}|" .env

        echo "✅ Environment variables configured"
        echo ""
        echo "Ghost URL set to: ${DOMAIN}"
        echo "Generated secure passwords for database"
        echo ""
    else
        echo "❌ .env.example file not found"
        exit 1
    fi
else
    echo "✅ .env file already exists"
fi

# Set proper permissions
chmod 600 .env
echo "✅ Set secure permissions on .env file"
echo ""

# Verify configuration
source .env
WARNINGS=0

if [ "$CLOUDFLARE_TUNNEL_TOKEN" == "your_cloudflare_tunnel_token_here" ]; then
    echo "⚠️  WARNING: Cloudflare Tunnel token not set!"
    WARNINGS=$((WARNINGS+1))
fi

if [ "$GHOST_URL" == "https://blog.yourdomain.com" ]; then
    echo "⚠️  WARNING: Ghost URL not configured!"
    WARNINGS=$((WARNINGS+1))
fi

if [ $WARNINGS -gt 0 ]; then
    echo ""
    echo "Please edit .env and configure the required values"
    echo ""
fi

echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Verify .env file has correct values: nano .env"
echo "2. Start Ghost: docker compose up -d"
echo "3. Check logs: docker compose logs -f"
echo "4. Access Ghost admin: https://${DOMAIN:-yourdomain.com}/ghost"
echo ""
echo "Useful commands:"
echo "  docker compose ps          - View running services"
echo "  docker compose logs -f     - Follow logs"
echo "  docker compose restart     - Restart services"
echo "  docker compose down        - Stop services"
echo ""
echo "For backups, run:"
echo "  docker compose run --rm db_backup /backup.sh"
echo ""
