#!/usr/bin/env bash
#
# backup-wordpress.sh — Back up a WordPress site (files + database).
# Keeps 7 daily backups, deletes older ones.
#
# Usage: ./backup-wordpress.sh /var/www/mysite db_name [db_user] [db_pass]
# Cron:  0 2 * * * /opt/scripts/backup-wordpress.sh /var/www/mysite mysite_db >> /var/log/wp-backup.log 2>&1
#
set -euo pipefail

SITE_DIR="${1:?Usage: $0 /var/www/mysite db_name [db_user] [db_pass]}"
DB_NAME="${2:?Usage: $0 /var/www/mysite db_name [db_user] [db_pass]}"
DB_USER="${3:-root}"
DB_PASS="${4:-}"
BACKUP_DIR="/var/backups/wordpress"
RETENTION_DAYS=7

DATE=$(date +%F)
SITE_SLUG=$(basename "$SITE_DIR")
DEST="$BACKUP_DIR/$SITE_SLUG-$DATE"

mkdir -p "$DEST"

echo "[$(date '+%F %T')] Backing up $SITE_SLUG ..."

# 1. Database dump
if [[ -n "$DB_PASS" ]]; then
  MYSQL_PWD="$DB_PASS" mysqldump -u "$DB_USER" --single-transaction "$DB_NAME" | gzip > "$DEST/db.sql.gz"
else
  mysqldump -u "$DB_USER" --single-transaction "$DB_NAME" | gzip > "$DEST/db.sql.gz"
fi

# 2. Site files (excluding cache)
tar -czf "$DEST/files.tar.gz" \
  --exclude='wp-content/cache' \
  --exclude='wp-content/uploads/cache' \
  -C "$(dirname "$SITE_DIR")" "$SITE_SLUG"

# 3. Single archive + cleanup
tar -czf "$BACKUP_DIR/$SITE_SLUG-$DATE.tar.gz" -C "$BACKUP_DIR" "$SITE_SLUG-$DATE"
rm -rf "$DEST"

# 4. Retention
find "$BACKUP_DIR" -name "$SITE_SLUG-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete

echo "[$(date '+%F %T')] Done: $BACKUP_DIR/$SITE_SLUG-$DATE.tar.gz ($(du -h "$BACKUP_DIR/$SITE_SLUG-$DATE.tar.gz" | cut -f1))"
