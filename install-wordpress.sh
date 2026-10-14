#!/usr/bin/env bash
#
# install-wordpress.sh — one-shot WordPress install on a fresh Ubuntu VPS.
#
# Installs: Nginx, PHP-FPM, MariaDB, wp-cli, Certbot (Nginx plugin),
# then creates the database, downloads WordPress, writes wp-config.php
# with fresh salts, installs the site, and issues a Let's Encrypt cert.
#
# Usage:
#   sudo ./install-wordpress.sh --domain example.com --email you@example.com \
#        --admin-user admin --admin-email you@example.com
#
# Flags:
#   --domain       Site domain (required)
#   --email        Email for Let's Encrypt registration (required unless --no-ssl)
#   --admin-user   WP admin username (default: admin)
#   --admin-email  WP admin email (default: --email)
#   --admin-pass   WP admin password (generated if omitted, shown at the end)
#   --db-name      Database name (default: wp_<domain with dots as underscores>)
#   --db-user      Database user (default: wp_<domain with dots as underscores>)
#   --db-pass      Database password (generated if omitted, shown at the end)
#   --php          PHP version, e.g. 8.3 (default: 8.3)
#   --webroot      Web root (default: /var/www/<domain>)
#   --no-ssl       Skip Certbot SSL issuance (plain HTTP only)
#   --force        Reinstall into an existing webroot (deletes existing files)
#   --yes          Skip the confirmation prompt
#
# Run as root. Review before running on anything that isn't a fresh VPS.
#
set -euo pipefail

# ---------- defaults ----------
DOMAIN=""
EMAIL=""
ADMIN_USER="admin"
ADMIN_EMAIL=""
ADMIN_PASS=""
DB_NAME=""
DB_USER=""
DB_PASS=""
PHP_VER="8.3"
WEBROOT=""
NO_SSL=0
FORCE=0
ASSUME_YES=0

usage() {
    sed -n '2,26p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --email)       EMAIL="$2"; shift 2 ;;
        --admin-user)  ADMIN_USER="$2"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
        --db-name)     DB_NAME="$2"; shift 2 ;;
        --db-user)     DB_USER="$2"; shift 2 ;;
        --db-pass)     DB_PASS="$2"; shift 2 ;;
        --php)         PHP_VER="$2"; shift 2 ;;
        --webroot)     WEBROOT="$2"; shift 2 ;;
        --no-ssl)      NO_SSL=1; shift ;;
        --force)       FORCE=1; shift ;;
        --yes)         ASSUME_YES=1; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required" >&2; usage 1; }
[[ -z "$EMAIL" && $NO_SSL -eq 0 ]] && { echo "ERROR: --email is required (or use --no-ssl)" >&2; usage 1; }
[[ $EUID -ne 0 ]] && { echo "ERROR: run as root (sudo)" >&2; exit 1; }

# ---------- derived defaults ----------
SLUG="${DOMAIN//./_}"
SLUG="${SLUG//-/_}"
[[ -z "$DB_NAME"  ]] && DB_NAME="wp_${SLUG}"
[[ -z "$DB_USER"  ]] && DB_USER="wp_${SLUG}"
[[ -z "$WEBROOT"  ]] && WEBROOT="/var/www/${DOMAIN}"
[[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="$EMAIL"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

gen_secret() { openssl rand -base64 21 | tr -d '/+=' | head -c 20; echo; }
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(gen_secret)"
[[ -z "$DB_PASS"    ]] && DB_PASS="$(gen_secret)"

SITE_URL="http://$DOMAIN"
[[ $NO_SSL -eq 0 ]] && SITE_URL="https://$DOMAIN"

# ---------- confirm ----------
if [[ $ASSUME_YES -eq 0 ]]; then
    cat <<EOF
This will install WordPress for ${DOMAIN}:
  webroot   ${WEBROOT}
  database  ${DB_NAME} (user ${DB_USER})
  admin     ${ADMIN_USER} <${ADMIN_EMAIL}>
  php       ${PHP_VER}   ssl: $([[ $NO_SSL -eq 0 ]] && echo yes || echo no)
Continue? [y/N]
EOF
    read -r reply
    [[ "${reply,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

log() { echo "==> $*"; }

# ---------- 1. packages ----------
log "Installing packages (nginx, php${PHP_VER}, mariadb, certbot)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx mariadb-server \
    "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" "php${PHP_VER}-curl" \
    "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
    "php${PHP_VER}-gd" "php${PHP_VER}-imagick" "php${PHP_VER}-intl" \
    curl unzip certbot python3-certbot-nginx openssl >/dev/null

systemctl enable --now nginx mariadb "php${PHP_VER}-fpm" >/dev/null

# ---------- 2. wp-cli ----------
if ! command -v wp >/dev/null 2>&1; then
    log "Installing wp-cli..."
    curl -sS -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
fi

# ---------- 3. database (least-privilege user, this DB only) ----------
log "Creating database ${DB_NAME}..."
mysql --defaults-extra-file=<(printf '[client]\nuser=root\n') -e "
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;"

# ---------- 4. wordpress files ----------
if [[ -f "${WEBROOT}/wp-config.php" && $FORCE -eq 0 ]]; then
    echo "ERROR: ${WEBROOT}/wp-config.php already exists. Use --force to reinstall." >&2
    exit 1
fi
if [[ $FORCE -eq 1 && -d "$WEBROOT" ]]; then
    log "Clearing existing webroot (--force)..."
    rm -rf "${WEBROOT:?}/"
fi

log "Downloading WordPress to ${WEBROOT}..."
mkdir -p "$WEBROOT"
sudo -u www-data wp core download --path="$WEBROOT" --quiet

log "Creating wp-config.php..."
sudo -u www-data wp config create \
    --path="$WEBROOT" \
    --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
    --dbhost=localhost --dbprefix=wp_ --skip-check --quiet
sudo -u www-data wp config shuffle-salts --path="$WEBROOT" --quiet

log "Running wp core install..."
sudo -u www-data wp core install \
    --path="$WEBROOT" \
    --url="$SITE_URL" --title="$DOMAIN" \
    --admin_user="$ADMIN_USER" --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" --skip-email --quiet
sudo -u www-data wp rewrite structure '/%postname%/' --path="$WEBROOT" --quiet || true

chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;

# ---------- 5. nginx vhost ----------
log "Writing Nginx vhost..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WEBROOT};
    index index.php index.html;

    # Security: deny dotfiles and sensitive files.
    location ~ /\. { deny all; }
    location = /wp-config.php { deny all; }
    location = /xmlrpc.php { deny all; }

    # Static assets: cache aggressively.
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
nginx -t
systemctl reload nginx

# ---------- 6. ssl ----------
if [[ $NO_SSL -eq 0 ]]; then
    log "Issuing Let's Encrypt certificate..."
    certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" \
        --non-interactive --agree-tos -m "$EMAIL" --redirect --quiet
else
    log "Skipping SSL (--no-ssl)."
fi

# ---------- 7. firewall hint ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    log "UFW: allowed 80/443."
fi

# ---------- summary ----------
cat <<EOF

========================================
 WordPress installed: ${SITE_URL}
 Admin:               ${SITE_URL}/wp-admin/
   user:  ${ADMIN_USER}
   pass:  ${ADMIN_PASS}
 Database: ${DB_NAME} / ${DB_USER}
   pass:  ${DB_PASS}
 Webroot: ${WEBROOT}
 Vhost:   /etc/nginx/sites-available/${DOMAIN}
========================================
Save these credentials somewhere safe.
EOF
