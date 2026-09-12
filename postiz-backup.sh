#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups/postiz"
CONTAINER="postiz-postgres"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FINAL="$BACKUP_DIR/postiz-$STAMP.dump"
TMP="$FINAL.tmp"

umask 077
mkdir -p "$BACKUP_DIR"
trap 'rm -f "$TMP"' EXIT

POSTGRES_USER="$(docker exec "$CONTAINER" printenv POSTGRES_USER)"
POSTGRES_DB="$(docker exec "$CONTAINER" printenv POSTGRES_DB)"

docker exec "$CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$TMP"
test -s "$TMP"
docker exec -i "$CONTAINER" pg_restore -l < "$TMP" >/dev/null
mv "$TMP" "$FINAL"
sha256sum "$FINAL" > "$FINAL.sha256"

find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'postiz-*.dump' -o -name 'postiz-*.dump.sha256' \) -mtime +7 -delete
