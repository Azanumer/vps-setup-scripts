#!/usr/bin/env bash
#
# clone-wordpress-staging.sh — clone a live WordPress site to a staging copy.
#
# Usage:
#   sudo ./clone-wordpress-staging.sh /var/www/live  /var/www/staging  staging.example.com
#
# What it does:
#   1. rsyncs files (skipping cache dirs, backups, debug logs)
#   2. reads DB credentials from the live wp-config.php
#   3. dumps the live DB, creates <db>_staging, imports into it
#   4. writes a staging wp-config.php (new DB name + fresh salts)
#   5. rewrites siteurl/home to the staging domain and sets blog_public=0
#      (so search engines never index the staging copy)
#   6. uses wp-cli for search-replace when available, SQL fallback otherwise
#
# Requires: rsync, mysqldump, mysql client, php (for salt generation via WP API fallback).
# Run as root. The staging docroot is wiped before the copy — be sure it is the right dir.

set -euo pipefail

LIVE_DIR="${1:-}"
STAGE_DIR="${2:-}"
STAGE_DOMAIN="${3:-}"

if [[ -z "$LIVE_DIR" || -z "$STAGE_DIR" || -z "$STAGE_DOMAIN" ]]; then
    echo "Usage: $0 <live-docroot> <staging-docroot> <staging-domain>" >&2
    exit 1
fi
if [[ ! -f "$LIVE_DIR/wp-config.php" ]]; then
    echo "ERROR: no wp-config.php in $LIVE_DIR" >&2
    exit 1
fi
if [[ "$STAGE_DIR" == "/" || "$STAGE_DIR" == "$LIVE_DIR" ]]; then
    echo "ERROR: refusing to wipe $STAGE_DIR" >&2
    exit 1
fi

log() { echo "[staging-clone] $*"; }

# --- 1. DB credentials from live wp-config.php -----------------------
DB_NAME=$(grep -oP "define\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1)
DB_USER=$(grep -oP "define\(\s*'DB_USER'\s*,\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1)
DB_PASS=$(grep -oP "define\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1)
DB_HOST=$(grep -oP "define\(\s*'DB_HOST'\s*,\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1)
PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1)
LIVE_URL=$(grep -oP "define\(\s*'WP_HOME'\s*,\s*'\K[^']+" "$LIVE_DIR/wp-config.php" | head -1 || true)
: "${DB_HOST:=localhost}"
: "${PREFIX:=wp_}"

STAGE_DB="${DB_NAME}_staging"

# --- 2. files ---------------------------------------------------------
log "rsyncing files to $STAGE_DIR"
mkdir -p "$STAGE_DIR"
rsync -a --delete \
    --exclude 'wp-content/cache/' \
    --exclude 'wp-content/advanced-cache.php' \
    --exclude 'wp-content/object-cache.php' \
    --exclude 'wp-content/debug.log' \
    --exclude 'wp-content/updraft/' \
    --exclude '*.sql' --exclude '*.zip' --exclude '*.tar.gz' \
    "$LIVE_DIR"/ "$STAGE_DIR"/

# --- 3. database ------------------------------------------------------
log "dumping live database $DB_NAME"
DUMP=$(mktemp /tmp/staging-dump-XXXXXX.sql)
MYSQL="mysql -h$DB_HOST -u$DB_USER -p$DB_PASS"
mysqldump -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --single-transaction --quick "$DB_NAME" > "$DUMP"

log "creating staging database $STAGE_DB"
$MYSQL -e "CREATE DATABASE IF NOT EXISTS \`$STAGE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$STAGE_DB\`.* TO '$DB_USER'@'${DB_HOST%%:*}'; FLUSH PRIVILEGES;"
$MYSQL "$STAGE_DB" < "$DUMP"
rm -f "$DUMP"

# --- 4. staging wp-config.php -----------------------------------------
log "writing staging wp-config.php"
cp "$LIVE_DIR/wp-config.php" "$STAGE_DIR/wp-config.php"

# point at the staging database
sed -i "s/define( *'DB_NAME' *, *'[^']*' *);/define( 'DB_NAME', '$STAGE_DB' );/" "$STAGE_DIR/wp-config.php"

# drop old salts (fresh ones below)
sed -i "/define( *'\(AUTH_KEY\|SECURE_AUTH_KEY\|LOGGED_IN_KEY\|NONCE_KEY\|AUTH_SALT\|SECURE_AUTH_SALT\|LOGGED_IN_SALT\|NONCE_SALT\)'/d" "$STAGE_DIR/wp-config.php"

# cut everything from the "stop editing" marker (we re-add the tail below)
sed -i "/stop editing/,\$d" "$STAGE_DIR/wp-config.php"

# fresh salts (WP API, php fallback, static comment as last resort)
SALTS=$(curl -fsSL --max-time 15 https://api.wordpress.org/secret-key/1.1/salt/ \
        || php -r 'for($i=0;$i<8;$i++) echo "define(\x27AUTH_KEY_$i\x27, \x27".bin2hex(random_bytes(32))."\x27);\n";' 2>/dev/null \
        || echo "// salts: regenerate at https://api.wordpress.org/secret-key/1.1/salt/")

{
    echo "$SALTS"
    echo "define( 'WP_HOME', 'https://$STAGE_DOMAIN' );"
    echo "define( 'WP_SITEURL', 'https://$STAGE_DOMAIN' );"
    echo "define( 'WP_DEBUG', false );"
    echo "/* That's all, stop editing! Happy publishing. */"
    echo "if ( ! defined( 'ABSPATH' ) ) { define( 'ABSPATH', __DIR__ . '/' ); }"
    echo "require_once ABSPATH . 'wp-settings.php';"
} >> "$STAGE_DIR/wp-config.php"

# --- 5. URL rewrite + discourage search engines ------------------------
if command -v wp >/dev/null 2>&1; then
    log "running wp-cli search-replace"
    if [[ -n "$LIVE_URL" ]]; then
        wp search-replace "$LIVE_URL" "https://$STAGE_DOMAIN" --path="$STAGE_DIR" --all-tables --allow-root --quiet
    fi
else
    log "wp-cli not found — updating siteurl/home via SQL"
    $MYSQL "$STAGE_DB" -e "UPDATE ${PREFIX}options SET option_value='https://$STAGE_DOMAIN' WHERE option_name IN ('siteurl','home');"
fi
$MYSQL "$STAGE_DB" -e "UPDATE ${PREFIX}options SET option_value='0' WHERE option_name='blog_public';"

# --- 6. permissions ----------------------------------------------------
WEB_USER=$(ps -o user= -C nginx 2>/dev/null | head -1 | tr -d ' ')
WEB_USER=${WEB_USER:-www-data}
chown -R "$WEB_USER:$WEB_USER" "$STAGE_DIR"
find "$STAGE_DIR" -type d -exec chmod 755 {} \;
find "$STAGE_DIR" -type f -exec chmod 644 {} \;
chmod 600 "$STAGE_DIR/wp-config.php"

log "done. Point your web server at $STAGE_DIR for https://$STAGE_DOMAIN (search indexing disabled)."
