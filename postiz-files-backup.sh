#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups/postiz-files"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FINAL="$BACKUP_DIR/postiz-files-$STAMP.tar"
TMP="$FINAL.tmp"

umask 077
mkdir -p "$BACKUP_DIR"
trap 'rm -f "$TMP"' EXIT

tar -cf "$TMP" \
  -C /opt postiz \
  -C /var/lib/docker/volumes postiz_postiz-config/_data postiz_postiz-uploads/_data
test -s "$TMP"
mv "$TMP" "$FINAL"
sha256sum "$FINAL" > "$FINAL.sha256"

find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'postiz-files-*.tar' -o -name 'postiz-files-*.tar.sha256' \) -mtime +14 -delete
