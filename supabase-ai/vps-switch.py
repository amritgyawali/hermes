#!/usr/bin/env python3
"""VPS service switchboard: manual on/off of hermes/omniroute/postiz via Supabase.

Reads the public.vps_services table (one row per service, enabled = true/false).
Applies ONLY when a row changes (change signal = hash of name/enabled/updated_at);
with no edits it is a silent no-op. It never decides state on its own — the DB is
the single source of truth; you flip the toggle in Supabase.

State model (disabled => service fully stopped, RAM/CPU freed for the other
services; watchdog/healthcheck timers are stopped too, so nothing auto-restarts
a service you turned off; re-enabling restores the timers). The switchboard's
own timer ALWAYS runs — it is the control plane.

  hermes     user units:   hermes-gateway.service, hermes-dashboard.service
             user timers:  hermes-healthcheck.timer, hermes-dashboard-healthcheck.timer
  omniroute  containers:   omniroute, omniroute-redis-1
             root timer:   omniroute-watchdog.timer
  postiz     containers:   postiz, postiz-postgres, postiz-redis, temporal,
                           temporal-ui, temporal-admin-tools, temporal-elasticsearch
             root timer:   postiz-watchdog.timer

Required env (same ~/.hermes/supabase-ai.env file):
  SUPABASE_URL, SUPABASE_SECRET_KEY
"""

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request

STATE_FILE = pathlib.Path.home() / ".vps-switch-state.json"

HERMES_CONTAINERS = []  # hermes is native + a sandbox container on demand
HERMES_UNITS = ["hermes-gateway.service", "hermes-dashboard.service"]
HERMES_TIMERS = ["hermes-healthcheck.timer", "hermes-dashboard-healthcheck.timer"]

OMNIROUTE_CONTAINERS = ["omniroute", "omniroute-redis-1"]
OMNIROUTE_TIMER = "omniroute-watchdog.timer"

POSTIZ_CONTAINERS = [
    "postiz", "postiz-postgres", "postiz-redis",
    "temporal", "temporal-ui", "temporal-admin-tools", "temporal-elasticsearch",
]
POSTIZ_TIMER = "postiz-watchdog.timer"


def log(msg: str) -> None:
    print(msg, flush=True)


def fetch_rows():
    url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SECRET_KEY"]
    req = urllib.request.Request(
        f"{url}/rest/v1/vps_services?select=*&order=name.asc",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def sh(*cmd, sudo=False):
    full = (["sudo", "-n"] if sudo else []) + list(cmd)
    r = subprocess.run(full, capture_output=True, text=True)
    if r.returncode != 0:
        log(f"  ! {' '.join(full)} -> rc={r.returncode} {r.stderr.strip()[:200]}")
    return r.returncode == 0


def containers_running(names):
    out = subprocess.run(
        ["docker", "ps", "--filter", "status=running", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    ).stdout.split()
    return all(n in out for n in names)


def apply_hermes(on: bool):
    if on:
        for u in HERMES_UNITS:
            sh("systemctl", "--user", "unmask", u)
        for u in HERMES_UNITS:
            sh("systemctl", "--user", "start", u)
        for t in HERMES_TIMERS:
            sh("systemctl", "--user", "unmask", t)
            sh("systemctl", "--user", "start", t)
    else:
        for t in HERMES_TIMERS:
            sh("systemctl", "--user", "stop", t)
        for u in HERMES_UNITS:
            sh("systemctl", "--user", "stop", u)


def apply_omniroute(on: bool):
    if on:
        sh("systemctl", "unmask", OMNIROUTE_TIMER, sudo=True)
        sh("systemctl", "start", OMNIROUTE_TIMER, sudo=True)
        for c in OMNIROUTE_CONTAINERS:
            sh("docker", "start", c, sudo=True)
    else:
        sh("systemctl", "stop", OMNIROUTE_TIMER, sudo=True)
        for c in OMNIROUTE_CONTAINERS:
            sh("docker", "stop", c, sudo=True)


def apply_postiz(on: bool):
    if on:
        sh("systemctl", "unmask", POSTIZ_TIMER, sudo=True)
        sh("systemctl", "start", POSTIZ_TIMER, sudo=True)
        for c in POSTIZ_CONTAINERS:
            sh("docker", "start", c, sudo=True)
    else:
        sh("systemctl", "stop", POSTIZ_TIMER, sudo=True)
        # reverse order: app first, then its datastores
        for c in reversed(POSTIZ_CONTAINERS):
            sh("docker", "stop", c, sudo=True)


APPLIERS = {
    "hermes": (apply_hermes, lambda: any(
        subprocess.run(["systemctl", "--user", "is-active", "-q", u]).returncode == 0
        for u in HERMES_UNITS)),
    "omniroute": (apply_omniroute, lambda: containers_running(OMNIROUTE_CONTAINERS)),
    "postiz": (apply_postiz, lambda: containers_running(POSTIZ_CONTAINERS)),
}


def main() -> int:
    try:
        rows = fetch_rows()
    except (urllib.error.URLError, KeyError, TimeoutError, OSError) as exc:
        log(f"supabase fetch failed ({type(exc).__name__}); no changes applied")
        return 1

    if not rows:
        return 0

    sig = hashlib.sha256(json.dumps(
        [[r["name"], r["enabled"], r["updated_at"]] for r in rows], sort_keys=True).encode()).hexdigest()

    changed = False
    for r in rows:
        name = r["name"]
        on = bool(r["enabled"])
        if name not in APPLIERS:
            continue
        apply_fn, live_fn = APPLIERS[name]
        live = live_fn()
        if live != on:
            log(f"service '{name}': live={'ON' if live else 'OFF'} -> desired={'ON' if on else 'OFF'}")
            apply_fn(on)
            changed = True
        else:
            log(f"service '{name}': already {'ON' if on else 'OFF'}")

    if changed or not STATE_FILE.exists() or json.loads(STATE_FILE.read_text()).get("signature") != sig:
        STATE_FILE.write_text(json.dumps({"signature": sig}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
