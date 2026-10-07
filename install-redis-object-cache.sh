#!/usr/bin/env bash
# install-redis-object-cache.sh — Install Redis and wire up the WordPress
# object-cache drop-in for a big TTFB / DB-load win.
#
# Usage: sudo ./install-redis-object-cache.sh [--wp-path /var/www/mysite] [--port 6379]
#
# Steps:
#   1. Installs redis-server + the PHP redis extension (via apt / pecl fallback).
#   2. Hardens redis.conf: binds to 127.0.0.1 only, sets a random requirepass,
#      disables dangerous commands (FLUSHALL/FLUSHDB) by renaming them.
#   3. Installs the official Redis Object Cache drop-in (object-cache.php)
#      into the WordPress wp-content dir and appends WP_REDIS_* constants.
#   4. Verifies with wp cache get / redis-cli ping.
set -euo pipefail

WP_PATH=""
PORT=6379

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wp-path) WP_PATH="$2"; shift 2 ;;
        --port)    PORT="$2";    shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
[[ -n "$WP_PATH" && -d "$WP_PATH" ]] || { echo "Give a valid --wp-path to your WordPress install." >&2; exit 1; }

echo "==> Installing redis-server + PHP redis extension"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq redis-server curl ca-certificates

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
if [[ -n "$PHP_VER" ]] && apt-cache show "php${PHP_VER}-redis" >/dev/null 2>&1; then
    apt-get install -y -qq "php${PHP_VER}-redis"
else
    apt-get install -y -qq php-pear php-dev build-essential
    pecl install -f redis <<< "" >/dev/null
    phpenmod redis 2>/dev/null || echo "extension=redis.so" > "/etc/php/${PHP_VER}/mods-available/redis.ini"
    phpenmod redis 2>/dev/null || true
fi

echo "==> Hardening redis.conf (localhost only, password, disable FLUSHALL/FLUSHDB)"
CONF=/etc/redis/redis.conf
[[ -f "$CONF" ]] || CONF=/etc/redis.conf
PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

set_conf() { # key value
    if grep -qE "^#? *$1 " "$CONF"; then
        sed -i -E "s|^#? *$1 .*|$1 $2|" "$CONF"
    else
        echo "$1 $2" >> "$CONF"
    fi
}

set_conf bind "127.0.0.1 ::1"
set_conf port "$PORT"
set_conf protected-mode "yes"
set_conf requirepass "$PASS"
set_conf rename-command "FLUSHALL \"\""
set_conf rename-command "FLUSHDB \"\""
set_conf maxmemory "256mb"
set_conf maxmemory-policy "allkeys-lru"

systemctl enable --now redis-server
systemctl restart redis-server

echo "==> Installing WordPress Redis Object Cache drop-in"
DROPIN_URL="https://raw.githubusercontent.com/rhubarbgroup/redis-cache/develop/includes/object-cache.php"
curl -fsSL -o "$WP_PATH/wp-content/object-cache.php" "$DROPIN_URL"

WP_CONFIG="$WP_PATH/wp-config.php"
if ! grep -q "WP_REDIS_HOST" "$WP_CONFIG"; then
    sed -i "/\/\* That's all, stop editing!/i \\
define('WP_REDIS_HOST', '127.0.0.1');\\
define('WP_REDIS_PORT', $PORT);\\
define('WP_REDIS_PASSWORD', '$PASS');\\
define('WP_REDIS_TIMEOUT', 1);\\
define('WP_REDIS_READ_TIMEOUT', 1);\\
define('WP_REDIS_DATABASE', 0);" "$WP_CONFIG"
fi

echo "==> Verifying"
redis-cli -a "$PASS" --no-auth-warning -p "$PORT" ping
if command -v wp >/dev/null 2>&1; then
    (cd "$WP_PATH" && wp cache set redis_health_check ok --allow-root && wp cache get redis_health_check --allow-root)
else
    echo "(wp-cli not installed — verify manually: install the 'Redis Object Cache' plugin and enable it)"
fi

echo
echo "Done. Redis password stored in $WP_CONFIG (WP_REDIS_PASSWORD)."
echo "Test in WordPress: Query Monitor will show object-cache hits."
