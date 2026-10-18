#!/usr/bin/env bash
#
# migrate-wordpress.sh — migrate a WordPress site between servers in one shot.
#
# Modes:
#   1. EXPORT (run on the SOURCE server):
#        ./migrate-wordpress.sh --export --wp-path /var/www/site --out /root/site-migration.tar.gz
#      Creates a tarball containing: wp-content/, uploads.sql (DB dump),
#      .htaccess, and a MANIFEST with old URL + DB prefix.
#
#   2. IMPORT (run on the TARGET server, tarball copied over):
#        ./migrate-wordpress.sh --import --tarball site-migration.tar.gz \
#            --wp-path /var/www/site --new-url https://newsite.com \
#            --db-name wpdb --db-user wpuser --db-pass 'secret'
#      Restores files, creates the DB + user, imports SQL, rewrites old URLs
#      (serialized-data safe via wp-cli when available), refreshes salts.
#
# Requirements: tar, gzip, mysql client, mysqldump. wp-cli optional (used for
# URL rewriting when present; a serialized-safe PHP fallback is included).

set -euo pipefail

MODE=""; WP_PATH=""; OUT=""; TARBALL=""; NEW_URL=""
DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST="localhost"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --export)   MODE=export; shift ;;
        --import)   MODE=import; shift ;;
        --wp-path)  WP_PATH="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --tarball)  TARBALL="$2"; shift 2 ;;
        --new-url)  NEW_URL="$2"; shift 2 ;;
        --db-name)  DB_NAME="$2"; shift 2 ;;
        --db-user)  DB_USER="$2"; shift 2 ;;
        --db-pass)  DB_PASS="$2"; shift 2 ;;
        --db-host)  DB_HOST="$2"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

err() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$MODE" ]] || err "choose --export or --import"
[[ -n "$WP_PATH" ]] || err "--wp-path is required"

# Read DB credentials + site URL from wp-config.php
read_config() {
    local cfg="$1/wp-config.php"
    [[ -f "$cfg" ]] || err "wp-config.php not found in $1"
    cfg_val() { grep -oP "define\(\s*'$1'\s*,\s*'\K[^']+" "$cfg" | head -1; }
    DB_NAME="${DB_NAME:-$(cfg_val DB_NAME)}"
    DB_USER="${DB_USER:-$(cfg_val DB_USER)}"
    DB_PASS="${DB_PASS:-$(cfg_val DB_PASSWORD)}"
    DB_HOST="${DB_HOST:-$(cfg_val DB_HOST)}"
    OLD_URL="$(php -r '
        $c = file_get_contents($argv[1]);
        foreach (["WP_HOME","WP_SITEURL"] as $k) {
            if (preg_match("/define\(\s*.$k.\s*,\s*.([^)]+).\)/", $c, $m)) {
                echo trim($m[1], " \t\n\r\0\x0B" . chr(39) . chr(34));
                exit;
            }
        }' "$cfg" 2>/dev/null || true)"
    TABLE_PREFIX="$(grep -oP '^\$table_prefix\s*=\s*.\K[^'"'"'"]+' "$cfg" | head -1)"
    [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASS" ]] || err "could not read DB credentials from wp-config.php"
}

do_export() {
    [[ -n "$OUT" ]] || err "--out is required for --export"
    command -v mysqldump >/dev/null || err "mysqldump not found"
    read_config "$WP_PATH"

    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "-> dumping database $DB_NAME"
    mysqldump -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --single-transaction \
        --routines --triggers "$DB_NAME" | gzip > "$TMP/database.sql.gz"

    echo "-> packing wp-content + extras"
    tar -C "$WP_PATH" -czf "$TMP/files.tar.gz" wp-content .htaccess 2>/dev/null || \
        tar -C "$WP_PATH" -czf "$TMP/files.tar.gz" wp-content

    cat > "$TMP/MANIFEST" <<EOF
migrated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old_url=${OLD_URL:-unknown}
table_prefix=${TABLE_PREFIX:-wp_}
wp_path=$WP_PATH
EOF

    tar -czf "$OUT" -C "$TMP" database.sql.gz files.tar.gz MANIFEST
    echo "Export complete: $OUT ($(du -h "$OUT" | cut -f1))"
    echo "Old URL recorded as: ${OLD_URL:-unknown}  (used for search-replace on import)"
}

do_import() {
    [[ -n "$TARBALL" ]] || err "--tarball is required for --import"
    [[ -n "$NEW_URL" ]] || err "--new-url is required for --import"
    command -v mysql >/dev/null || err "mysql client not found"
    [[ -f "$TARBALL" ]] || err "tarball not found: $TARBALL"

    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    tar -xzf "$TARBALL" -C "$TMP"
    # shellcheck disable=SC1091
    source <(grep -E '^(old_url|table_prefix)=' "$TMP/MANIFEST" | sed 's/^/MANIFEST_/')
    OLD_URL="${MANIFEST_old_url:-}"; PREFIX="${MANIFEST_table_prefix:-wp_}"

    echo "-> creating target directory $WP_PATH"
    mkdir -p "$WP_PATH"
    tar -xzf "$TMP/files.tar.gz" -C "$WP_PATH"

    echo "-> creating database $DB_NAME + user $DB_USER"
    mysql -h"$DB_HOST" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$DB_HOST';
FLUSH PRIVILEGES;
SQL

    echo "-> importing database"
    zcat "$TMP/database.sql.gz" | mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"

    echo "-> writing wp-config.php"
    SALTS="$(curl -fsS https://api.wordpress.org/secret-key/1.1/salt/ || echo '')"
    cat > "$WP_PATH/wp-config.php" <<PHP
<?php
define('DB_NAME', '$DB_NAME');
define('DB_USER', '$DB_USER');
define('DB_PASSWORD', '$DB_PASS');
define('DB_HOST', '$DB_HOST');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
\$table_prefix = '$PREFIX';
define('WP_HOME', '$NEW_URL');
define('WP_SITEURL', '$NEW_URL');
$([ -n "$SALTS" ] && echo "$SALTS" || echo "/* salts: visit https://api.wordpress.org/secret-key/1.1/salt/ */")
define('WP_DEBUG', false);
if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');
require_once ABSPATH . 'wp-settings.php';
PHP

    # URL rewrite: prefer wp-cli (serialized-safe); else PHP fallback.
    if [[ -n "$OLD_URL" && "$OLD_URL" != "unknown" && "$OLD_URL" != "$NEW_URL" ]]; then
        if command -v wp >/dev/null; then
            echo "-> search-replace via wp-cli: $OLD_URL -> $NEW_URL"
            wp search-replace "$OLD_URL" "$NEW_URL" --all-tables --path="$WP_PATH" --quiet || \
                echo "   wp-cli search-replace reported issues — check manually"
        else
            echo "-> search-replace via PHP fallback (serialized-safe)"
            php -r '
                [$host, $user, $pass, $name, $prefix, $old, $new] = array_slice($argv, 1);
                $db = new mysqli($host, $user, $pass, $name);
                if ($db->connect_error) { fwrite(STDERR, "DB connect failed\n"); exit(1); }
                $res = $db->query("SHOW TABLES LIKE \"{$db->real_escape_string($prefix)}%\"");
                $tables = [];
                while ($r = $res->fetch_row()) { $tables[] = $r[0]; }
                foreach ($tables as $t) {
                    $cols = [];
                    $cres = $db->query("SHOW COLUMNS FROM `$t`");
                    while ($c = $cres->fetch_assoc()) {
                        if (preg_match("/text|char|blob/i", $c["Type"])) { $cols[] = $c["Field"]; }
                    }
                    if (!$cols) continue;
                    $rows = $db->query("SELECT * FROM `$t`");
                    while ($row = $rows->fetch_assoc()) {
                        $sets = [];
                        foreach ($cols as $col) {
                            if (isset($row[$col]) && strpos((string)$row[$col], $old) !== false) {
                                $fixed = str_replace($old, $new, $row[$col]);
                                // repair serialized string lengths after replacement
                                $fixed = preg_replace_callback(
                                    "/s:(\d+):\"(.*?)\";/s",
                                    function ($m) { return "s:" . strlen($m[2]) . ":\"{$m[2]}\";"; },
                                    $fixed
                                );
                                $sets[] = "`$col` = \"" . $db->real_escape_string($fixed) . "\"";
                            }
                        }
                        if ($sets) {
                            $pk = $db->query("SHOW KEYS FROM `$t` WHERE Key_name = \"PRIMARY\"")->fetch_assoc();
                            $where = $pk ? "`{$pk["Column_name"]}` = \"{$db->real_escape_string($row[$pk["Column_name"]])}\"" : "1=1 LIMIT 1";
                            $db->query("UPDATE `$t` SET " . implode(", ", $sets) . " WHERE $where");
                        }
                    }
                }
                echo "search-replace done\n";
            ' "$DB_HOST" "$DB_USER" "$DB_PASS" "$DB_NAME" "$PREFIX" "$OLD_URL" "$NEW_URL"
        fi
    else
        echo "-> skipping search-replace (same or unknown old URL)"
    fi

    echo "-> fixing permissions"
    chown -R www-data:www-data "$WP_PATH" 2>/dev/null || true
    find "$WP_PATH" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WP_PATH" -type f -exec chmod 644 {} + 2>/dev/null || true

    echo
    echo "Import complete. Visit $NEW_URL/wp-admin and check Settings → Permalinks (save once)."
}

case "$MODE" in
    export) do_export ;;
    import) do_import ;;
esac
