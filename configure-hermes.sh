#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="/home/ubuntu/.hermes"
BOOTSTRAP_KEY_FILE="/home/ubuntu/.config/hermes-bootstrap/omniroute-api-key"
STAGED_CONFIG="/tmp/hermes-vps/config.yaml"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

umask 077
test -s "$BOOTSTRAP_KEY_FILE"
test -s "$STAGED_CONFIG"

mkdir -p "$HERMES_HOME/backups"
if [[ -f "$HERMES_HOME/config.yaml" ]]; then
  cp "$HERMES_HOME/config.yaml" "$HERMES_HOME/backups/config.yaml.$STAMP"
fi
if [[ -f "$HERMES_HOME/.env" ]]; then
  cp "$HERMES_HOME/.env" "$HERMES_HOME/backups/env.$STAMP"
fi

install -m 600 "$STAGED_CONFIG" "$HERMES_HOME/config.yaml"

OMNIROUTE_API_KEY="$(tr -d '\r\n' < "$BOOTSTRAP_KEY_FILE")"
API_SERVER_KEY="$(openssl rand -hex 32)"
cat > "$HERMES_HOME/.env" <<EOF
OPENAI_API_KEY=$OMNIROUTE_API_KEY
API_SERVER_ENABLED=true
API_SERVER_KEY=$API_SERVER_KEY
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=8642
HERMES_CRON_MAX_PARALLEL=1
HERMES_MAX_ITERATIONS=100
HERMES_API_TIMEOUT=600
EOF
chmod 600 "$HERMES_HOME/.env"

unset OMNIROUTE_API_KEY API_SERVER_KEY
rm -f "$BOOTSTRAP_KEY_FILE"

echo "Hermes configuration installed; secrets remain readable only by ubuntu."
