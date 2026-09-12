#!/usr/bin/env bash
# One-time install of the Supabase->Hermes endpoint sync on the VPS.
# Run as ubuntu. Idempotent. The secret key lives only in ~/.hermes/supabase-ai.env.
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://synacyspjibmpvrnpcia.supabase.co}"
ENV_FILE="$HOME/.hermes/supabase-ai.env"
SCRIPT_DIR="$HOME/.local/lib/hermes-supabase-ai"

# 1. script
mkdir -p "$SCRIPT_DIR"
install -m 700 "$(dirname "$0")/sync-hermes-ai.py" "$SCRIPT_DIR/sync-hermes-ai.py"
[[ -f "$(dirname "$0")/vps-switch.py" ]] && install -m 700 "$(dirname "$0")/vps-switch.py" "$SCRIPT_DIR/vps-switch.py"

# 2. env file (secret key from stdin prompt, never argv)
if [[ ! -f "$ENV_FILE" ]]; then
  read -rsp "Paste SUPABASE_SECRET_KEY (sb_secret_...): " KEY; echo
  umask 077
  cat > "$ENV_FILE" <<EOF
SUPABASE_URL=$SUPABASE_URL
SUPABASE_SECRET_KEY=$KEY
EOF
  unset KEY
  chmod 600 "$ENV_FILE"
fi

# 3. systemd user service + timer (every minute)
SVC_DIR="$HOME/.config/systemd/user"
mkdir -p "$SVC_DIR"
cat > "$SVC_DIR/hermes-supabase-sync.service" <<EOF
[Unit]
Description=Sync active AI endpoint from Supabase into Hermes config
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $SCRIPT_DIR/sync-hermes-ai.py
EOF

cat > "$SVC_DIR/hermes-supabase-sync.timer" <<EOF
[Unit]
Description=Poll Supabase for Hermes AI endpoint changes

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=15

[Install]
WantedBy=timers.target
EOF

# 3b. service switchboard (every 2 min; apply-on-change, silent otherwise)
cat > "$SVC_DIR/vps-switch.service" <<EOF
[Unit]
Description=Apply Supabase vps_services on/off switches
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $SCRIPT_DIR/vps-switch.py
EOF

cat > "$SVC_DIR/vps-switch.timer" <<EOF
[Unit]
Description=Poll Supabase for VPS service switch changes

[Timer]
OnBootSec=60
OnUnitActiveSec=120
AccuracySec=15

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now hermes-supabase-sync.timer
systemctl --user enable --now vps-switch.timer

# 4. immediate first run + verify
systemctl --user start hermes-supabase-sync.service
sleep 2
systemctl --user status hermes-supabase-sync.service --no-pager | tail -5
journalctl --user -u hermes-supabase-sync.service -n 20 --no-pager | tail -10

echo "installed: timer runs every 60s; service log via journalctl --user -u hermes-supabase-sync.service"
