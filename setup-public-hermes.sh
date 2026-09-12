#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="/home/ubuntu/.hermes"
HERMES_REPO="$HERMES_HOME/hermes-agent"
ENV_FILE="$HERMES_HOME/.env"
PYTHON="$HERMES_REPO/venv/bin/python"
BOOTSTRAP_DIR="/home/ubuntu/.config/hermes-public-bootstrap"
SITE_DIR="/home/ubuntu/postpilot/infra/sites"
PUBLIC_URL="https://hermes.digitalamritomni.duckdns.org"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

umask 077
test -x "$PYTHON"
test -f "$ENV_FILE"
test "$(readlink -m "$BOOTSTRAP_DIR")" = "/home/ubuntu/.config/hermes-public-bootstrap"

rm -rf -- "$BOOTSTRAP_DIR"
install -d -m 700 "$BOOTSTRAP_DIR"
cp "$ENV_FILE" "$HERMES_HOME/backups/env.before-public-dashboard.$STAMP"

DASHBOARD_PASSWORD="$(openssl rand -base64 32 | tr -d '\r\n=')"
P12_PASSWORD="$(openssl rand -base64 24 | tr -d '\r\n=')"
SESSION_SECRET="$(openssl rand -hex 32)"

printf '%s\n' "$DASHBOARD_PASSWORD" > "$BOOTSTRAP_DIR/dashboard-password.raw"
printf '%s\n' "$P12_PASSWORD" > "$BOOTSTRAP_DIR/client-import-password.txt"

openssl genrsa -out "$BOOTSTRAP_DIR/client-ca.key" 4096 >/dev/null 2>&1
openssl req -x509 -new -sha256 -days 3650 \
  -key "$BOOTSTRAP_DIR/client-ca.key" \
  -subj "/CN=Amrit Hermes Browser Client CA" \
  -out "$BOOTSTRAP_DIR/client-ca.crt"

openssl genrsa -out "$BOOTSTRAP_DIR/hermes-browser.key" 3072 >/dev/null 2>&1
openssl req -new -sha256 \
  -key "$BOOTSTRAP_DIR/hermes-browser.key" \
  -subj "/CN=Amrit Hermes Browser" \
  -out "$BOOTSTRAP_DIR/hermes-browser.csr"

cat > "$BOOTSTRAP_DIR/client.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

openssl x509 -req -sha256 -days 397 \
  -in "$BOOTSTRAP_DIR/hermes-browser.csr" \
  -CA "$BOOTSTRAP_DIR/client-ca.crt" \
  -CAkey "$BOOTSTRAP_DIR/client-ca.key" \
  -CAcreateserial \
  -extfile "$BOOTSTRAP_DIR/client.ext" \
  -out "$BOOTSTRAP_DIR/hermes-browser.crt" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$BOOTSTRAP_DIR/hermes-browser.key" \
  -in "$BOOTSTRAP_DIR/hermes-browser.crt" \
  -certfile "$BOOTSTRAP_DIR/client-ca.crt" \
  -name "Hermes VPS Browser Access" \
  -passout "file:$BOOTSTRAP_DIR/client-import-password.txt" \
  -out "$BOOTSTRAP_DIR/hermes-browser.p12"

PASSWORD_HASH="$("$PYTHON" - "$BOOTSTRAP_DIR/dashboard-password.raw" <<'PY'
import pathlib
import sys
from plugins.dashboard_auth.basic import hash_password

password = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
print(hash_password(password))
PY
)"

TMP_ENV="$(mktemp)"
sed \
  -e '/^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=/d' \
  -e '/^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=/d' \
  -e '/^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=/d' \
  -e '/^HERMES_DASHBOARD_BASIC_AUTH_SECRET=/d' \
  -e '/^HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=/d' \
  -e '/^HERMES_DASHBOARD_PUBLIC_URL=/d' \
  "$ENV_FILE" > "$TMP_ENV"

{
  cat "$TMP_ENV"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=amrit\n'
  printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=%s\n' "$PASSWORD_HASH"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$SESSION_SECRET"
  printf 'HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=3600\n'
  printf 'HERMES_DASHBOARD_PUBLIC_URL=%s\n' "$PUBLIC_URL"
} > "$ENV_FILE"
rm -f "$TMP_ENV"
chmod 600 "$ENV_FILE"

install -m 644 "$BOOTSTRAP_DIR/client-ca.crt" "$SITE_DIR/hermes-client-ca.crt"

cat > "$BOOTSTRAP_DIR/dashboard-login.txt" <<EOF
URL=$PUBLIC_URL
Username=amrit
Password=$DASHBOARD_PASSWORD
EOF
chmod 600 "$BOOTSTRAP_DIR/dashboard-login.txt" "$BOOTSTRAP_DIR/client-import-password.txt" "$BOOTSTRAP_DIR/hermes-browser.p12"

unset DASHBOARD_PASSWORD P12_PASSWORD SESSION_SECRET PASSWORD_HASH
echo "Public-dashboard credentials and client certificate generated securely."
