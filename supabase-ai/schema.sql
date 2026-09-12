-- ============================================================================
-- Supabase schema for the VPS: AI endpoint registry + service switchboard
-- Run this whole file in the Supabase SQL editor (idempotent).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Hermes AI endpoint registry
-- The VPS sync agent (supabase-ai/sync-hermes-ai.py) polls this table, ordered
-- by priority ASC over is_active rows, and applies it to ~/.hermes/config.yaml
-- + restarts the gateway: #1 = PRIMARY model, #2..N = ordered FALLBACK chain.
--
-- SECURITY: api_key holds live credentials. RLS is enabled with NO anon /
-- authenticated policies, so the publishable key returns nothing at all.
-- Only the secret key (service role) can read this table. Never expose it
-- from a browser.
-- ----------------------------------------------------------------------------

create table if not exists public.hermes_ai_endpoints (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  provider         text not null default 'custom',
  base_url         text not null,
  api_key          text not null,
  model            text not null,
  context_length   integer,
  reasoning_effort text check (reasoning_effort in ('minimal','low','medium','high')),
  priority         integer not null default 100,
  is_active        boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Upgrades for tables created before `priority` existed:
--   (already applied on synacyspjibmpvrnpcia — kept here for fresh projects)
alter table public.hermes_ai_endpoints
  add column if not exists priority integer not null default 100;

-- Older designs had a one-active-row unique index + activate() helper; the
-- priority-chain model allows many active rows, so drop them if present:
drop index if exists public.hermes_ai_one_active;
drop function if exists public.hermes_activate_endpoint(text);

alter table public.hermes_ai_endpoints enable row level security;

-- Keep updated_at fresh on every edit (the sync agent uses it as change signal).
create or replace function public.hermes_touch_endpoints() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_hermes_touch_endpoints on public.hermes_ai_endpoints;
create trigger trg_hermes_touch_endpoints
  before update on public.hermes_ai_endpoints
  for each row execute function public.hermes_touch_endpoints();

-- Day-to-day usage (Supabase dashboard → Table editor, or SQL editor):
--   add:    insert into hermes_ai_endpoints (name, base_url, api_key, model, context_length, priority)
--           values ('openrouter','https://openrouter.ai/api/v1','sk-or-...','some/model', 200000, 20);
--   reorder:update hermes_ai_endpoints set priority = 5  where name = 'openrouter';  -- becomes primary
--   park:   update hermes_ai_endpoints set is_active = false where name = 'b.ai';
--   edit:   update hermes_ai_endpoints set api_key='...' where name='openrouter';
--   delete: delete from hermes_ai_endpoints where name = 'openrouter';
--
-- With 20+ rows Hermes gets a 20-deep failover chain: any endpoint that
-- rate-limits or errors falls through to the next by priority, automatically.
-- Do NOT seed an active row with a placeholder key — the VPS applies the
-- active chain within ~60s; insert rows only with real keys.

-- ----------------------------------------------------------------------------
-- 2) VPS service switchboard — manual on/off for the three services
-- The VPS switchboard (supabase-ai/vps-switch.py) polls this table every 2
-- minutes. It ONLY acts when live state differs from `enabled`; it never
-- decides on its own — this table is the single source of truth and YOU flip
-- the toggles. Disabled = service stopped + its watchdog/healthcheck timers
-- paused, so its RAM/CPU is freed for the others.
-- ----------------------------------------------------------------------------

create table if not exists public.vps_services (
  name         text primary key,          -- hermes | omniroute | postiz
  enabled      boolean not null default true,
  updated_at   timestamptz not null default now()
);

insert into public.vps_services (name, enabled) values
  ('hermes',    true),
  ('omniroute', true),
  ('postiz',    true)
on conflict (name) do nothing;

alter table public.vps_services enable row level security;

create or replace function public.vps_touch_services() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_vps_touch_services on public.vps_services;
create trigger trg_vps_touch_services
  before update on public.vps_services
  for each row execute function public.vps_touch_services();

-- Usage:
--   update vps_services set enabled = false where name = 'omniroute';  -- stop
--   update vps_services set enabled = true  where name = 'omniroute';  -- start
-- Takes effect within ~2 minutes on the VPS (journalctl --user -u vps-switch.service).
