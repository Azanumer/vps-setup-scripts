#!/usr/bin/env bash
#
# lemp-ubuntu.sh — Install a LEMP stack on a fresh Ubuntu 22.04/24.04 VPS.
# Installs: Nginx, PHP-FPM (8.3), MySQL, Redis, Certbot. Configures UFW.
#
# Usage: sudo ./lemp-ubuntu.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "==> Updating packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

echo "==> Installing Nginx, PHP 8.3, MySQL, Redis, Certbot..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  nginx \
  php8.3-fpm php8.3-mysql php8.3-curl php8.3-mbstring \
  php8.3-xml php8.3-zip php8.3-gd php8.3-redis \
  mysql-server redis-server \
  certbot python3-certbot-nginx \
  ufw fail2ban unzip curl

echo "==> Enabling services..."
systemctl enable --now nginx php8.3-fpm mysql redis-server

echo "==> Configuring UFW (allow SSH, HTTP, HTTPS)..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "==> PHP-FPM: raising upload limits for WordPress..."
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' /etc/php/8.3/fpm/php.ini
sed -i 's/^post_max_size.*/post_max_size = 64M/' /etc/php/8.3/fpm/php.ini
systemctl reload php8.3-fpm

echo "==> Securing Redis (bind to localhost only)..."
sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
systemctl restart redis-server

echo ""
echo "LEMP stack installed. Next steps:"
echo "  1. Run: sudo mysql_secure_installation"
echo "  2. Point your domain's DNS to this server"
echo "  3. Run: sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com"
