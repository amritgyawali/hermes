#!/usr/bin/env bash
set -euo pipefail

set -a
# shellcheck disable=SC1091
source /home/ubuntu/.hermes/.env
set +a

TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

MODELS_CODE="$(curl --silent --show-error --output "$TMP_BODY" --write-out '%{http_code}' \
  --connect-timeout 5 --max-time 30 \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  http://127.0.0.1:20128/v1/models)"
[[ "$MODELS_CODE" == "200" ]]

CHAT_CODE="$(curl --silent --show-error --output "$TMP_BODY" --write-out '%{http_code}' \
  --connect-timeout 5 --max-time 180 \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"model":"auto","messages":[{"role":"user","content":"Reply with exactly OK."}],"stream":false,"max_tokens":16}' \
  http://127.0.0.1:20128/v1/chat/completions)"
[[ "$CHAT_CODE" == "200" ]]

python3 - "$TMP_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

choices = payload.get("choices") or []
if not choices:
    raise SystemExit("OmniRoute returned no choices")
message = choices[0].get("message") or {}
if not str(message.get("content") or "").strip():
    raise SystemExit("OmniRoute returned empty content")
print("OmniRoute models and auto inference: OK")
PY
