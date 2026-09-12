# Supabase-driven AI endpoint registry + VPS service switchboard

Two DB-driven systems, one sync timer each:

1. **AI endpoint registry** (`hermes_ai_endpoints`) — manage which AI endpoint(s)
   (url + key + model) Hermes uses, from a Supabase table. Row #1 by priority =
   PRIMARY model, rows #2+ = ordered FALLBACK chain. Edit a row, and within ~60
   seconds the VPS applies it.
2. **Service switchboard** (`vps_services`) — turn hermes / omniroute / postiz
   on or OFF from Supabase. Off = containers/user services stopped + watchdogs
   paused, freeing their RAM/CPU for the others. Manual-only: nothing ever
   flips a service automatically — the table is the single source of truth.

## How it works

```
Supabase hermes_ai_endpoints (you edit rows)
        ^  every 60s: hermes-supabase-sync.timer -> sync-hermes-ai.py
        |   writes AI_KEY_<NAME> to ~/.hermes/.env (600), sets model.* + fallback_providers,
        |   restarts hermes-gateway, waits for /health, records applied state
Supabase vps_services (you flip `enabled`)
        ^  every 120s: vps-switch.timer -> vps-switch.py
        |   hermes: user units hermes-gateway/dashboard + healthcheck timers
        |   omniroute: docker stop/start omniroute + redis, omniroute-watchdog.timer
        |   postiz: docker stop/start postiz+temporal stack, postiz-watchdog.timer
        |   only acts on live-vs-desired mismatch; never touches the other services
```

## Day-to-day: service on/off (Supabase dashboard → Table Editor → vps_services)

```sql
update vps_services set enabled = false where name = 'omniroute';  -- stop (frees ~2.5 GiB)
update vps_services set enabled = true  where name = 'omniroute';  -- start again
```
Takes effect within ~2 minutes. Check: `systemctl --user status vps-switch.service`
/ `journalctl --user -u vps-switch.service -n 20`.

## Day-to-day: AI endpoints

```sql
-- add a new endpoint
insert into hermes_ai_endpoints (name, base_url, api_key, model, context_length, priority)
values ('openrouter', 'https://openrouter.ai/api/v1', 'sk-or-...', 'anthropic/claude-sonnet-5', 200000, 20);

-- reorder: priority 1 = primary, 2..N = fallback chain (tried in order)
update hermes_ai_endpoints set priority = 5 where name = 'openrouter';

-- park one without deleting it
update hermes_ai_endpoints set is_active = false where name = 'b.ai';
```

Verify: `hermes -z "Reply with exactly: SYNC_OK"` and
`journalctl --user -u hermes-supabase-sync.service -n 20`.

## Setup (once) — already done on 137.23.47.160

1. Run `schema.sql` in the Supabase SQL editor, then insert your endpoints
   (SQL is also in the file's tail comments).
2. On the VPS: `bash supabase-ai/install-sync.sh` (prompts for the secret key
   via stdin → `~/.hermes/supabase-ai.env`, 0600, never committed).

## Security

- RLS ON on both tables, no anon/authenticated policies → the publishable key
  reads nothing; only the secret key works. Secret key lives only in
  `~/.hermes/supabase-ai.env` (0600), never in a repo or argv.
- api_key plaintext in your own Supabase project (service-role only) —
  acceptable for personal use; rotate if the project is shared.
- Sync writes only model.*/fallback_providers config and restarts the gateway;
  switchboard only starts/stops the listed units — neither executes SQL or
  arbitrary commands from Supabase.
