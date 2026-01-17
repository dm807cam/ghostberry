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
        read -p "Enter your domain (e.g., blog.yourdomain.com): " DOMAIN
        read -p "Enter Cloudflare Tunnel Token: " CF_TOKEN
        
        # Generate random passwords
        DB_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        ROOT_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        
        # Update .env file
        sed -i "s|GHOST_DB_PASSWORD=.*|GHOST_DB_PASSWORD=${DB_PASS}|" .env
        sed -i "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${ROOT_PASS}|" .env
        sed -i "s|CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=${CF_TOKEN}|" .env
        
        echo "✅ Environment variables configured"
        echo ""
        echo "Generated secure passwords for database"
        echo ""
    else
        echo "❌ .env.example file not found"
        exit 1
    fi
else
    echo "✅ .env file already exists"
fi

# Update Ghost URL in docker-compose.yml
if [ ! -z "$DOMAIN" ]; then
    echo "Updating Ghost URL in docker-compose.yml..."
    if [ -f "docker-compose.yml" ]; then
        sed -i "s|url: https://yourdomain.com|url: https://${DOMAIN}|" docker-compose.yml
        echo "✅ Ghost URL updated to https://${DOMAIN}"
        echo ""
    fi
fi

# Set proper permissions
chmod 600 .env
echo "✅ Set secure permissions on .env file"
echo ""

# Verify Cloudflare token
source .env
if [ "$CLOUDFLARE_TUNNEL_TOKEN" == "your_cloudflare_tunnel_token_here" ]; then
    echo "⚠️  WARNING: Cloudflare Tunnel token not set!"
    echo "Please edit .env and add your Cloudflare Tunnel token"
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
