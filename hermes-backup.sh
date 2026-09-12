#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups/hermes"
HERMES="/home/ubuntu/.local/bin/hermes"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

umask 077
mkdir -p "$BACKUP_DIR"

"$HERMES" backup --output "$BACKUP_DIR/hermes-$STAMP.zip"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'hermes-*.zip' -mtime +7 -delete
