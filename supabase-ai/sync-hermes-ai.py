#!/usr/bin/env python3
"""Sync Hermes AI endpoints from Supabase into ~/.hermes + gateway.

Fetches ALL active rows (is_active = true) of hermes_ai_endpoints ordered by
priority ASC (then name).
Row #1 becomes the PRIMARY model (model.* keys). Every other row becomes a
FALLBACK entry (fallback_providers), tried in the same order when the primary
fails with rate-limit / overload / connection errors. Add 20 endpoints in
Supabase and Hermes gets a 20-deep failover chain — no SSH, no deploy.

Each row's API key is written to ~/.hermes/.env as AI_KEY_<SANITIZED_NAME>
(mode 600, never logged); config references it via key_env/${...} so the real
key never lands in config.yaml.

Change signal = hash of the whole ordered set (id, updated_at, is_active,
priority). Any add/update/delete/switch triggers re-apply + gateway restart.
Unchanged => silent no-op.

Required env (systemd EnvironmentFile ~/.hermes/supabase-ai.env):
  SUPABASE_URL          e.g. https://<project>.supabase.co
  SUPABASE_SECRET_KEY   secret key — must never appear in a repo
"""

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERMES_HOME = pathlib.Path(os.environ.get("HERMES_HOME", pathlib.Path.home() / ".hermes"))
ENV_FILE = HERMES_HOME / ".env"
STATE_FILE = HERMES_HOME / "supabase-ai-state.json"
BIN = pathlib.Path.home() / ".local" / "bin"


def log(msg: str) -> None:
    print(msg, flush=True)


def key_env_name(name: str) -> str:
    ident = re.sub(r"[^A-Za-z0-9_]", "_", name).upper()
    return f"AI_KEY_{ident}"


def fetch_rows():
    url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SECRET_KEY"]
    req = urllib.request.Request(
        f"{url}/rest/v1/hermes_ai_endpoints"
        "?select=*&is_active=eq.true&order=priority.asc,name.asc",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def update_env_vars(pairs: dict) -> None:
    """Replace-or-append multiple KEY=value lines in ~/.hermes/.env, atomically."""
    lines = ENV_FILE.read_text().splitlines() if ENV_FILE.exists() else []
    out, found = [], set()
    for ln in lines:
        k = ln.split("=", 1)[0]
        if k in pairs:
            out.append(f"{k}={pairs[k]}")
            found.add(k)
        else:
            out.append(ln)
    for k, v in pairs.items():
        if k not in found:
            out.append(f"{k}={v}")
    tmp = ENV_FILE.with_name(".env.tmp")
    tmp.write_text("\n".join(out) + "\n")
    tmp.chmod(0o600)
    tmp.replace(ENV_FILE)


def hermes_config(key: str, value) -> None:
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "") + os.pathsep + str(BIN)
    subprocess.run(
        ["hermes", "config", "set", key, json.dumps(value) if isinstance(value, list) else str(value)],
        check=True,
        capture_output=True,
        env=env,
    )


def wait_healthy(seconds: int = 30) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(2)
        try:
            with urllib.request.urlopen("http://127.0.0.1:8642/health", timeout=5) as r:
                if json.load(r).get("status") == "ok":
                    return True
        except Exception:
            pass
    return False


def main() -> int:
    try:
        rows = fetch_rows()
    except (urllib.error.URLError, KeyError, TimeoutError, OSError) as exc:
        log(f"supabase fetch failed ({type(exc).__name__}); keeping current config")
        return 1

    if not rows:
        log("no endpoints in Supabase; keeping current config")
        return 0

    signature = hashlib.sha256(
        json.dumps(
            [[r["id"], r["updated_at"], r.get("priority"), r.get("is_active", True)] for r in rows],
            sort_keys=True,
        ).encode()
    ).hexdigest()

    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    if state.get("signature") == signature:
        return 0  # silent no-op

    primary, rest = rows[0], rows[1:]
    log(f"applying {len(rows)} endpoint(s); primary='{primary['name']}' model={primary['model']}")

    env_pairs = {key_env_name(r["name"]): r["api_key"] for r in rows}
    update_env_vars(env_pairs)

    hermes_config("model.provider", primary.get("provider") or "custom")
    hermes_config("model.base_url", primary["base_url"])
    hermes_config("model.api_key", "${" + key_env_name(primary["name"]) + "}")
    hermes_config("model.default", primary["model"])
    if primary.get("context_length"):
        hermes_config("model.context_length", primary["context_length"])
    if primary.get("reasoning_effort"):
        hermes_config("agent.reasoning_effort", primary["reasoning_effort"])

    chain = []
    for r in rest:
        entry = {
            "provider": r.get("provider") or "custom",
            "model": r["model"],
            "base_url": r["base_url"],
            "key_env": key_env_name(r["name"]),
        }
        if r.get("context_length"):
            entry["context_length"] = r["context_length"]
        chain.append(entry)
    hermes_config("fallback_providers", chain)

    subprocess.run(["systemctl", "--user", "restart", "hermes-gateway.service"], check=True)
    if not wait_healthy():
        log("WARNING: gateway not healthy after restart; state not saved, will retry next run")
        return 1

    STATE_FILE.write_text(json.dumps({
        "signature": signature,
        "primary": primary["name"],
        "fallbacks": [r["name"] for r in rest],
    }))
    log(f"applied primary='{primary['name']}' + {len(rest)} fallback(s); gateway healthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
