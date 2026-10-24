-- Integrations with other POS / billing software: Petpooja and GoFrugal (Settings -> Integrations).
--
-- NOT NUMBERED YET. The canonical schema lives in `database/migrations` at the workspace root, which is not in this checkout; copy this
-- file there with the next free number before applying it. The server's manifest (server/src/rpc-manifest.ts) already lists the three
-- caller functions below, so `node scripts/manifest-audit.mjs` reports them MISSING until this file is applied.
--
-- What it holds per business and provider: the connection status, the non-secret account fields (Petpooja restaurant ID, GoFrugal store
-- URL and outlet), the provider keys ENCRYPTED with the server's PARTNER_PII_KEY (pgcrypto, the same way as PAN and bank numbers), the
-- last four characters of the main key so a person can recognise it, what to sync, and the result of the last connection check.
-- The keys are never returned to the app. Every rule (who may change it, which providers exist, connect before sync) is checked here.
--
-- Functions:
--   pos_integrations_get(p)          authenticated  the page: every provider with its status; account fields only for editors
--   pos_integration_set_sync(p)      authenticated  owner or manager: { provider, menu?, orders?, stock? } on a connected provider
--   pos_integration_disconnect(p)    authenticated  owner or manager: { provider }; deletes the keys and account fields
--   pos_integration_save(u, p, k)    service_role   secure handler, after the provider accepted the keys: store (encrypted) and mark connected
--   pos_integration_secret(u, p, k)  service_role   secure handler: decrypt the saved keys for a connection check
--   pos_integration_record_check(u, p) service_role secure handler: store the outcome of a connection check
-- The service_role functions take the user id the server verified from the token; authenticated may not execute them.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.pos_integrations (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  provider           text not null check (provider in ('petpooja', 'gofrugal')),
  status             text not null default 'disconnected' check (status in ('connected', 'error', 'disconnected')),
  account            jsonb not null default '{}'::jsonb check (jsonb_typeof(account) = 'object'),
  secret             bytea,
  key_hint           text check (key_hint is null or length(key_hint) <= 8),
  sync_menu          boolean not null default false,
  sync_orders        boolean not null default false,
  sync_stock         boolean not null default false,
  last_checked_at    timestamptz,
  last_check_ok      boolean,
  last_check_message text check (last_check_message is null or length(last_check_message) <= 300),
  connected_at       timestamptz,
  connected_by       uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (organization_id, provider),
  check (status = 'disconnected' or secret is not null)
);

-- No policies: the app never reads the table, only the functions below (and the service role) do.
alter table public.pos_integrations enable row level security;
revoke all on table public.pos_integrations from public, anon, authenticated;

-- The caller's business and whether they may change integrations. Same membership rule as the server's requireStaff: the earliest
-- active membership. Raises when there is none, or when [p_edit] and the role may not change integrations.
create or replace function public.pos__integration_actor(p_user_id uuid, p_edit boolean, out org uuid, out can_edit boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_role text;
begin
  if p_user_id is null then
    raise exception 'POS_FORBIDDEN: sign in to continue';
  end if;
  select ou.organization_id, r.slug into org, v_role
    from org_users ou
    left join roles r on r.id = ou.role_id
   where ou.user_id = p_user_id and ou.status = 'active'
   order by ou.created_at asc
   limit 1;
  if org is null then
    raise exception 'POS_FORBIDDEN: you are not a staff member of any business on One Local';
  end if;
  can_edit := coalesce(v_role, '') = any (array['owner', 'admin', 'manager', 'business_manager']);
  if p_edit and not can_edit then
    raise exception 'POS_FORBIDDEN: only the owner or a manager can change integrations';
  end if;
end $$;

-- The provider named in p, checked. Answers its display name for sentences.
create or replace function public.pos__integration_provider(p jsonb)
returns text
language plpgsql immutable set search_path = public, pg_temp as $$
begin
  case p->>'provider'
    when 'petpooja' then return 'Petpooja';
    when 'gofrugal' then return 'GoFrugal';
    else raise exception 'POS_BAD_REQUEST: choose Petpooja or GoFrugal';
  end case;
end $$;

-- The page. Every provider is listed, connected or not, in a fixed order; the keys never leave the database.
create or replace function public.pos__integrations_state(p_org uuid, p_can_edit boolean)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'can_edit', p_can_edit,
    'integrations', coalesce(jsonb_agg(jsonb_build_object(
      'provider', pv.provider,
      'status', coalesce(i.status, 'disconnected'),
      'account', case when p_can_edit and coalesce(i.status, 'disconnected') <> 'disconnected' then i.account else '{}'::jsonb end,
      'key_hint', case when p_can_edit and coalesce(i.status, 'disconnected') <> 'disconnected' then i.key_hint end,
      'sync', jsonb_build_object('menu', coalesce(i.sync_menu, false), 'orders', coalesce(i.sync_orders, false), 'stock', coalesce(i.sync_stock, false)),
      'last_check', case when i.last_checked_at is null or i.status = 'disconnected' then null
                         else jsonb_build_object('at', i.last_checked_at, 'ok', i.last_check_ok, 'message', i.last_check_message) end,
      'connected_at', case when i.status = 'disconnected' then null else i.connected_at end
    ) order by pv.ord), '[]'::jsonb))
  from (values ('petpooja', 1), ('gofrugal', 2)) as pv(provider, ord)
  left join pos_integrations i on i.organization_id = p_org and i.provider = pv.provider;
$$;

create or replace function public.pos_integrations_get(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  a record;
begin
  select * into a from pos__integration_actor(auth.uid(), false);
  return pos__integrations_state(a.org, a.can_edit);
end $$;

create or replace function public.pos_integration_set_sync(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a record;
  v_name text := pos__integration_provider(p);
  v_key text;
  n int;
begin
  select * into a from pos__integration_actor(auth.uid(), true);
  foreach v_key in array array['menu', 'orders', 'stock'] loop
    if p ? v_key and jsonb_typeof(p->v_key) <> 'boolean' then
      raise exception 'POS_BAD_REQUEST: choose on or off';
    end if;
  end loop;
  if not (p ?| array['menu', 'orders', 'stock']) then
    raise exception 'POS_BAD_REQUEST: choose what to sync';
  end if;
  update pos_integrations
     set sync_menu   = coalesce((p->>'menu')::boolean, sync_menu),
         sync_orders = coalesce((p->>'orders')::boolean, sync_orders),
         sync_stock  = coalesce((p->>'stock')::boolean, sync_stock),
         updated_at  = now()
   where organization_id = a.org and provider = p->>'provider' and status <> 'disconnected';
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'POS_WRONG_STATE: connect % first', v_name;
  end if;
  return pos__integrations_state(a.org, a.can_edit);
end $$;

-- Disconnecting deletes the keys and the account fields. Nothing changes on the provider's side. Already disconnected: the page as it is.
create or replace function public.pos_integration_disconnect(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a record;
begin
  perform pos__integration_provider(p);
  select * into a from pos__integration_actor(auth.uid(), true);
  update pos_integrations
     set status = 'disconnected', account = '{}'::jsonb, secret = null, key_hint = null,
         sync_menu = false, sync_orders = false, sync_stock = false,
         last_checked_at = null, last_check_ok = null, last_check_message = null,
         connected_at = null, connected_by = null, updated_at = now()
   where organization_id = a.org and provider = p->>'provider' and status <> 'disconnected';
  return pos__integrations_state(a.org, a.can_edit);
end $$;

-- Service role only (secure handler pos_integration_connect), called after the provider accepted the keys.
-- p = { provider, account: {..}, credentials: {..}, key_hint, message }. p_key is the server's PARTNER_PII_KEY, used for this call only.
create or replace function public.pos_integration_save(p_user_id uuid, p jsonb, p_key text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a record;
begin
  perform pos__integration_provider(p);
  if coalesce(length(p_key), 0) < 16 then
    raise exception 'POS_UNAVAILABLE: saving integration keys is not available right now';
  end if;
  if jsonb_typeof(p->'account') is distinct from 'object' or jsonb_typeof(p->'credentials') is distinct from 'object' then
    raise exception 'POS_BAD_REQUEST: the integration details are incomplete';
  end if;
  select * into a from pos__integration_actor(p_user_id, true);
  insert into pos_integrations as i
         (organization_id, provider, status, account, secret, key_hint,
          last_checked_at, last_check_ok, last_check_message, connected_at, connected_by)
  values (a.org, p->>'provider', 'connected', p->'account', extensions.pgp_sym_encrypt((p->'credentials')::text, p_key), left(p->>'key_hint', 4),
          now(), true, left(p->>'message', 300), now(), p_user_id)
  on conflict (organization_id, provider) do update
     set status = 'connected', account = excluded.account, secret = excluded.secret, key_hint = excluded.key_hint,
         last_checked_at = now(), last_check_ok = true, last_check_message = excluded.last_check_message,
         connected_at = case when i.status = 'disconnected' then now() else i.connected_at end,
         connected_by = excluded.connected_by, updated_at = now();
  return pos__integrations_state(a.org, a.can_edit);
end $$;

-- Service role only (secure handler pos_integration_test): the saved account and keys of one provider, for a connection check.
create or replace function public.pos_integration_secret(p_user_id uuid, p jsonb, p_key text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a record;
  v_name text := pos__integration_provider(p);
  v_row pos_integrations%rowtype;
  v_credentials jsonb;
begin
  select * into a from pos__integration_actor(p_user_id, true);
  select * into v_row from pos_integrations where organization_id = a.org and provider = p->>'provider' and status <> 'disconnected';
  if not found then
    raise exception 'POS_WRONG_STATE: connect % first', v_name;
  end if;
  begin
    v_credentials := extensions.pgp_sym_decrypt(v_row.secret, p_key)::jsonb;
  exception when others then
    raise exception 'POS_UNAVAILABLE: the saved % keys could not be read. Connect again with your keys', v_name;
  end;
  return jsonb_build_object('provider', v_row.provider, 'account', v_row.account, 'credentials', v_credentials);
end $$;

-- Service role only (secure handler pos_integration_test): the outcome of a connection check. A failed check marks the provider "error"
-- (needs attention) but keeps the keys, so a provider that was only down for a while can be checked again.
create or replace function public.pos_integration_record_check(p_user_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a record;
  v_name text := pos__integration_provider(p);
  n int;
begin
  if jsonb_typeof(p->'ok') is distinct from 'boolean' then
    raise exception 'POS_BAD_REQUEST: the check result is incomplete';
  end if;
  select * into a from pos__integration_actor(p_user_id, true);
  update pos_integrations
     set status = case when (p->>'ok')::boolean then 'connected' else 'error' end,
         last_checked_at = now(), last_check_ok = (p->>'ok')::boolean, last_check_message = left(p->>'message', 300), updated_at = now()
   where organization_id = a.org and provider = p->>'provider' and status <> 'disconnected';
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'POS_WRONG_STATE: connect % first', v_name;
  end if;
  return pos__integrations_state(a.org, a.can_edit);
end $$;

-- Grants. Functions are executable by PUBLIC by default; take that away from every one of them first.
revoke all on function public.pos__integration_actor(uuid, boolean) from public, anon, authenticated;
revoke all on function public.pos__integration_provider(jsonb) from public, anon, authenticated;
revoke all on function public.pos__integrations_state(uuid, boolean) from public, anon, authenticated;
revoke all on function public.pos_integrations_get(jsonb) from public, anon;
revoke all on function public.pos_integration_set_sync(jsonb) from public, anon;
revoke all on function public.pos_integration_disconnect(jsonb) from public, anon;
revoke all on function public.pos_integration_save(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.pos_integration_secret(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.pos_integration_record_check(uuid, jsonb) from public, anon, authenticated;

grant execute on function public.pos_integrations_get(jsonb) to authenticated;
grant execute on function public.pos_integration_set_sync(jsonb) to authenticated;
grant execute on function public.pos_integration_disconnect(jsonb) to authenticated;
grant execute on function public.pos_integration_save(uuid, jsonb, text) to service_role;
grant execute on function public.pos_integration_secret(uuid, jsonb, text) to service_role;
grant execute on function public.pos_integration_record_check(uuid, jsonb) to service_role;
