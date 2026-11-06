-- 0656 Guest experience builder: a restaurant's branded guest mini-app (onelocal.co/<store link> and the table QR), edited in the
-- partner app, published through a tiered gate (rules -> AI wording check -> OneLocal human review for money, compliance and
-- security), with version history, rollback, and pre-orders that land in the POS guest inbox.
-- Spec: specs/guest-experience-builder/spec.md (workspace root). Local dev DB 2026-11-04.
--
-- One source of truth each: name / store link / logo stay in org_listing_profiles; dishes, prices, photos in menu_items; the look
-- and blocks live here. A page never holds prices. Publishing is a database write: no build, no deploy.

begin;

-- ---------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.guest_experiences (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  draft jsonb,
  draft_version int not null default 0,
  live_version int,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.guest_experience_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  version int not null,
  definition jsonb not null,
  source text not null default 'publish' check (source in ('publish', 'rollback')),
  rollback_of int,
  status text not null check (status in ('pending_ai', 'pending_human', 'auto_approved', 'ai_approved', 'human_approved', 'rejected', 'superseded')),
  risk text not null check (risk in ('low', 'ai', 'high')),
  categories text[] not null default '{}',
  changes jsonb not null default '[]'::jsonb,       -- [{path, label, from, to, risk, category, why}]
  summary text,
  ai_note text,
  ai_model text,
  review_note text,
  ask_message text,
  submitted_by uuid references auth.users(id) on delete set null,
  submitted_at timestamptz not null default now(),
  decided_kind text check (decided_kind in ('rules', 'ai', 'human', 'rollback')),
  decided_by uuid,
  decided_by_name text,
  decided_at timestamptz,
  unique (organization_id, version),
  constraint gxv_decided check (not (status in ('pending_ai', 'pending_human') and decided_at is not null))
);
create index if not exists gxv_waiting on public.guest_experience_versions (submitted_at) where status in ('pending_ai', 'pending_human');

alter table public.guest_experiences enable row level security;
alter table public.guest_experience_versions enable row level security;
drop policy if exists gx_member_read on public.guest_experiences;
create policy gx_member_read on public.guest_experiences for select to authenticated using (organization_id = public.current_org_id());
drop policy if exists gxv_member_read on public.guest_experience_versions;
create policy gxv_member_read on public.guest_experience_versions for select to authenticated using (organization_id = public.current_org_id());
revoke insert, update, delete on public.guest_experiences, public.guest_experience_versions from anon, authenticated;
revoke all on public.guest_experiences, public.guest_experience_versions from anon;

-- pre-orders: the same inbox as table orders; a pre-order has no table or QR session but a pickup time and a phone
alter table public.guest_order_requests add column if not exists kind text not null default 'table';
alter table public.guest_order_requests add column if not exists pickup_at timestamptz;
alter table public.guest_order_requests add column if not exists guest_phone text;
alter table public.guest_order_requests add column if not exists track_hash text;
alter table public.guest_order_requests alter column table_id drop not null;
alter table public.guest_order_requests alter column session_id drop not null;
alter table public.guest_order_requests drop constraint if exists guest_order_requests_kind_shape;
alter table public.guest_order_requests add constraint guest_order_requests_kind_shape check (
  (kind = 'table' and table_id is not null and session_id is not null)
  or (kind = 'preorder' and table_id is null and session_id is null and pickup_at is not null and guest_phone ~ '^[6-9][0-9]{9}$'
      and guest_name is not null and track_hash is not null));
create unique index if not exists guest_order_requests_preorder_key on public.guest_order_requests (organization_id, idempotency_key) where kind = 'preorder';
create unique index if not exists guest_order_requests_track on public.guest_order_requests (track_hash) where track_hash is not null;


-- pre-orders have no QR session: the tenant check holds them to their own business and outlet instead; the edit guard compares with
-- "is distinct from" now that table and session can be empty
create or replace function public.guest_order_requests_tenant() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind = 'preorder' then
    if not exists (select 1 from public.locations l where l.id = new.location_id and l.organization_id = new.organization_id) then
      raise exception 'GUEST_TENANT: the outlet belongs to another business' using errcode = '23514'; end if;
  elsif not exists (select 1 from public.guest_qr_sessions s where s.id = new.session_id and s.organization_id = new.organization_id
                       and s.table_id = new.table_id and s.location_id = new.location_id) then
    raise exception 'GUEST_TENANT: the request does not match its session' using errcode = '23514'; end if;
  if new.order_id is not null and not exists (select 1 from public.orders o where o.id = new.order_id and o.organization_id = new.organization_id) then
    raise exception 'GUEST_TENANT: the order belongs to another business' using errcode = '23514'; end if;
  return new;
end $$;

create or replace function public.guest_order_requests_guard() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.status <> 'waiting' then raise exception 'GUEST_WRONG_STATE: this guest order was already %', old.status using errcode = '23514'; end if;
  if new.id <> old.id or new.organization_id <> old.organization_id or new.location_id <> old.location_id or new.table_id is distinct from old.table_id
     or new.session_id is distinct from old.session_id or new.lines <> old.lines or new.idempotency_key <> old.idempotency_key or new.body_hash <> old.body_hash
     or new.estimated_total <> old.estimated_total or new.created_at <> old.created_at or new.kind <> old.kind
     or new.pickup_at is distinct from old.pickup_at or new.guest_phone is distinct from old.guest_phone or new.track_hash is distinct from old.track_hash then
    raise exception 'GUEST_WRONG_STATE: a guest order cannot be edited' using errcode = '23514'; end if;
  return new;
end $$;

-- ------------------------------------------------------------------------------------------------------- text helpers
-- A page may never carry markup: < and > are refused outright (the gate never has to judge a script).
create or replace function public.gx__text(p text, p_max int, p_what text, p_default text default null)
returns text language plpgsql immutable set search_path = public, pg_temp as $$
declare v text := nullif(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), '');
begin
  if v is null then return p_default; end if;
  if v ~ '[<>]' then raise exception 'GX_BAD_REQUEST: % cannot contain < or >', p_what; end if;
  if char_length(v) > p_max then raise exception 'GX_BAD_REQUEST: % can be up to % characters', p_what, p_max; end if;
  return v;
end $$;

create or replace function public.gx__bool(p jsonb, p_default boolean) returns boolean language sql immutable as $$
  select case when jsonb_typeof(p) = 'boolean' then (p #>> '{}')::boolean else p_default end;
$$;

create or replace function public.gx__int(p jsonb, p_lo int, p_hi int, p_default int, p_what text)
returns int language plpgsql immutable set search_path = public, pg_temp as $$
declare v int;
begin
  if p is null or jsonb_typeof(p) = 'null' then return p_default; end if;
  begin v := (p #>> '{}')::numeric::int; exception when others then raise exception 'GX_BAD_REQUEST: % must be a number', p_what; end;
  if v < p_lo or v > p_hi then raise exception 'GX_BAD_REQUEST: % must be between % and %', p_what, p_lo, p_hi; end if;
  return v;
end $$;

create or replace function public.gx__hhmm(p text, p_default text, p_what text)
returns text language plpgsql immutable set search_path = public, pg_temp as $$
begin
  if p is null or btrim(p) = '' then return p_default; end if;
  if p !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'GX_BAD_REQUEST: % must be a time like 09:30', p_what; end if;
  return p;
end $$;

-- ------------------------------------------------------------------------------------------------ looks and defaults
create or replace function public.gx__look_theme(p_look text) returns jsonb language sql immutable as $$
  select case p_look
    when 'bakery_warm' then jsonb_build_object('background', '#F6F1EA', 'surface', '#FFFFFF', 'text', '#2B1D14', 'muted', '#8A7766',
                                               'accent', '#2B1D14', 'accent_text', '#FFFFFF', 'font', 'serif')
    else jsonb_build_object('background', '#0E0E0E', 'surface', '#1C1C1C', 'text', '#FFFFFF', 'muted', '#A3A3A3',
                            'accent', '#F5B83D', 'accent_text', '#111111', 'font', 'sans') end;
$$;

create or replace function public.gx__default_block(p_type text) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', p_type, 'type', p_type, 'enabled', p_type not in ('preorder', 'highlights'), 'props',
    case p_type
      when 'welcome' then jsonb_build_object('headline', 'Food looks better when you explore it.', 'subtext', 'Swipe through dishes, set a budget, and order together.',
                                             'image_id', null, 'cta_label', 'Start exploring')
      when 'order_mode' then jsonb_build_object('dine_in', true, 'pre_order', false, 'dine_in_label', 'Dine-in', 'pre_order_label', 'Pre-order')
      when 'budget' then jsonb_build_object('min', 500, 'max', 20000, 'default', 2000, 'split', true)
      when 'categories' then jsonb_build_object('style', 'grid')
      when 'swipe' then jsonb_build_object('card_style', 'stack', 'budget_ring', true)
      when 'highlights' then jsonb_build_object('picks_title', 'Chef''s picks', 'pick_ids', '[]'::jsonb, 'limited_title', 'Limited today',
                                                'limited_ids', '[]'::jsonb, 'limited_until', null)
      when 'preorder' then jsonb_build_object('days_ahead', 5, 'slot_minutes', 30, 'opens', '09:00', 'closes', '21:00', 'lead_minutes', 30,
                                              'note_hint', 'e.g. pack separately, birthday message')
      when 'tracking' then jsonb_build_object('show_eta', true)
      when 'bill' then jsonb_build_object('split', true, 'feedback', true)
    end);
$$;

create or replace function public.gx__block_types() returns text[] language sql immutable as $$
  select array['welcome', 'order_mode', 'budget', 'categories', 'swipe', 'highlights', 'preorder', 'tracking', 'bill'];
$$;

-- blocks a guest page cannot work (or stay lawful) without: always present, always on
create or replace function public.gx__required_types() returns text[] language sql immutable as $$
  select array['welcome', 'order_mode', 'swipe', 'tracking', 'bill'];
$$;

create or replace function public.gx__default(p_look text default 'bistro_dark') returns jsonb language sql immutable as $$
  select jsonb_build_object('look', coalesce(p_look, 'bistro_dark'), 'theme', public.gx__look_theme(p_look),
    'blocks', (select jsonb_agg(public.gx__default_block(t) order by n) from unnest(public.gx__block_types()) with ordinality u(t, n)));
$$;

-- ------------------------------------------------------------------------------------------------------------ clean
-- Validates and rebuilds the document from known fields only: anything unknown is dropped, anything wrong is refused.
create or replace function public.gx__clean(p_org uuid, d jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_look text; t jsonb; th jsonb; b jsonb; pr jsonb; v_type text; v_seen text[] := '{}'; v_out jsonb := '[]'::jsonb; v_props jsonb;
  v_ids jsonb; v_min int; v_max int; v_def int; v_open text; v_close text; v_dine boolean; v_pre boolean; v_enabled boolean;
begin
  if d is null or jsonb_typeof(d) <> 'object' then raise exception 'GX_BAD_REQUEST: the page is missing'; end if;
  v_look := coalesce(nullif(d->>'look', ''), 'bistro_dark');
  if v_look not in ('bistro_dark', 'bakery_warm', 'custom') then raise exception 'GX_BAD_REQUEST: unknown look'; end if;
  th := public.gx__look_theme(case when v_look = 'custom' then 'bistro_dark' else v_look end);
  t := coalesce(d->'theme', '{}'::jsonb);
  if jsonb_typeof(t) <> 'object' then raise exception 'GX_BAD_REQUEST: the colours are not valid'; end if;
  th := jsonb_build_object(
    'background', public.sf__hex(t->>'background', th->>'background', 'Background colour'),
    'surface', public.sf__hex(t->>'surface', th->>'surface', 'Card colour'),
    'text', public.sf__hex(t->>'text', th->>'text', 'Text colour'),
    'muted', public.sf__hex(t->>'muted', th->>'muted', 'Soft text colour'),
    'accent', public.sf__hex(t->>'accent', th->>'accent', 'Button colour'),
    'accent_text', public.sf__hex(t->>'accent_text', th->>'accent_text', 'Button text colour'),
    'font', coalesce(nullif(t->>'font', ''), th->>'font'));
  if th->>'font' not in ('sans', 'serif') then raise exception 'GX_BAD_REQUEST: the font is sans or serif'; end if;

  if jsonb_typeof(coalesce(d->'blocks', 'null'::jsonb)) <> 'array' or jsonb_array_length(d->'blocks') not between 1 and 12 then
    raise exception 'GX_BAD_REQUEST: a page has 1 to 12 blocks'; end if;

  for b in select value from jsonb_array_elements(d->'blocks') loop
    if jsonb_typeof(b) <> 'object' then raise exception 'GX_BAD_REQUEST: a block is not valid'; end if;
    v_type := b->>'type';
    if v_type is null or not (v_type = any (public.gx__block_types())) then raise exception 'GX_BAD_REQUEST: unknown block type'; end if;
    if v_type = any (v_seen) then raise exception 'GX_BAD_REQUEST: the page has two % blocks', v_type; end if;
    v_seen := v_seen || v_type;
    pr := coalesce(b->'props', '{}'::jsonb);
    if jsonb_typeof(pr) <> 'object' then raise exception 'GX_BAD_REQUEST: a block setting is not valid'; end if;
    v_enabled := v_type = any (public.gx__required_types()) or public.gx__bool(b->'enabled', true);
    v_props := public.gx__default_block(v_type)->'props';

    if v_type = 'welcome' then
      v_props := jsonb_build_object(
        'headline', public.gx__text(pr->>'headline', 60, 'The headline', v_props->>'headline'),
        'subtext', public.gx__text(pr->>'subtext', 140, 'The welcome line', null),
        'image_id', public.sf__image(p_org, pr->>'image_id', 'The welcome picture'),
        'cta_label', public.gx__text(pr->>'cta_label', 24, 'The button', v_props->>'cta_label'));
    elsif v_type = 'order_mode' then
      v_dine := public.gx__bool(pr->'dine_in', true); v_pre := public.gx__bool(pr->'pre_order', false);
      if not (v_dine or v_pre) then raise exception 'GX_BAD_REQUEST: offer dine-in, pre-order or both'; end if;
      v_props := jsonb_build_object('dine_in', v_dine, 'pre_order', v_pre,
        'dine_in_label', public.gx__text(pr->>'dine_in_label', 24, 'The dine-in label', 'Dine-in'),
        'pre_order_label', public.gx__text(pr->>'pre_order_label', 24, 'The pre-order label', 'Pre-order'));
    elsif v_type = 'budget' then
      v_min := public.gx__int(pr->'min', 100, 100000, 500, 'The lowest budget');
      v_max := public.gx__int(pr->'max', 100, 100000, 20000, 'The highest budget');
      v_def := public.gx__int(pr->'default', 100, 100000, 2000, 'The starting budget');
      if not (v_min < v_max and v_def between v_min and v_max) then raise exception 'GX_BAD_REQUEST: the starting budget must sit between the lowest and the highest'; end if;
      v_props := jsonb_build_object('min', v_min, 'max', v_max, 'default', v_def, 'split', public.gx__bool(pr->'split', true));
    elsif v_type = 'categories' then
      if coalesce(pr->>'style', 'grid') <> 'grid' then raise exception 'GX_BAD_REQUEST: categories show as a grid'; end if;
      v_props := jsonb_build_object('style', 'grid');
    elsif v_type = 'swipe' then
      if coalesce(pr->>'card_style', 'stack') not in ('stack', 'full') then raise exception 'GX_BAD_REQUEST: cards are stacked or full screen'; end if;
      v_props := jsonb_build_object('card_style', coalesce(pr->>'card_style', 'stack'), 'budget_ring', public.gx__bool(pr->'budget_ring', true));
    elsif v_type = 'highlights' then
      for v_ids in select x from (values (pr->'pick_ids'), (pr->'limited_ids')) v(x) loop
        if v_ids is not null and jsonb_typeof(v_ids) <> 'null' and (jsonb_typeof(v_ids) <> 'array' or jsonb_array_length(v_ids) > 8) then
          raise exception 'GX_BAD_REQUEST: pick up to 8 dishes'; end if;
        if exists (select 1 from jsonb_array_elements_text(coalesce(nullif(v_ids, 'null'::jsonb), '[]'::jsonb)) i
                    where not exists (select 1 from public.menu_items m where m.organization_id = p_org and m.id::text = i)) then
          raise exception 'GX_BAD_REQUEST: a picked dish is not on your menu'; end if;
      end loop;
      v_props := jsonb_build_object(
        'picks_title', public.gx__text(pr->>'picks_title', 30, 'The picks title', 'Chef''s picks'),
        'pick_ids', (select coalesce(jsonb_agg(distinct i), '[]'::jsonb) from jsonb_array_elements_text(coalesce(nullif(pr->'pick_ids', 'null'::jsonb), '[]'::jsonb)) i),
        'limited_title', public.gx__text(pr->>'limited_title', 30, 'The limited title', 'Limited today'),
        'limited_ids', (select coalesce(jsonb_agg(distinct i), '[]'::jsonb) from jsonb_array_elements_text(coalesce(nullif(pr->'limited_ids', 'null'::jsonb), '[]'::jsonb)) i),
        'limited_until', case when nullif(pr->>'limited_until', '') is null then null else public.gx__hhmm(pr->>'limited_until', null, 'Limited until') end);
    elsif v_type = 'preorder' then
      v_open := public.gx__hhmm(pr->>'opens', '09:00', 'Pre-orders open'); v_close := public.gx__hhmm(pr->>'closes', '21:00', 'Pre-orders close');
      if v_open >= v_close then raise exception 'GX_BAD_REQUEST: pre-orders must open before they close'; end if;
      if coalesce(pr->>'slot_minutes', '30') not in ('15', '30', '60') then raise exception 'GX_BAD_REQUEST: time slots are 15, 30 or 60 minutes'; end if;
      v_props := jsonb_build_object('days_ahead', public.gx__int(pr->'days_ahead', 1, 14, 5, 'Days ahead'),
        'slot_minutes', coalesce(pr->>'slot_minutes', '30')::int, 'opens', v_open, 'closes', v_close,
        'lead_minutes', public.gx__int(pr->'lead_minutes', 0, 240, 30, 'Time to prepare'),
        'note_hint', public.gx__text(pr->>'note_hint', 60, 'The note hint', null));
    elsif v_type = 'tracking' then
      v_props := jsonb_build_object('show_eta', public.gx__bool(pr->'show_eta', true));
    elsif v_type = 'bill' then
      v_props := jsonb_build_object('split', public.gx__bool(pr->'split', true), 'feedback', public.gx__bool(pr->'feedback', true));
    end if;
    v_out := v_out || jsonb_build_object('id', v_type, 'type', v_type, 'enabled', v_enabled, 'props', v_props);
  end loop;

  -- a missing required block comes back with its defaults: it cannot be deleted
  for v_type in select unnest(public.gx__required_types()) loop
    if not (v_type = any (v_seen)) then v_out := v_out || public.gx__default_block(v_type); end if;
  end loop;
  -- pre-order offered means the pre-order block is on
  if exists (select 1 from jsonb_array_elements(v_out) x where x->>'type' = 'order_mode' and (x->'props'->>'pre_order')::boolean) then
    if not exists (select 1 from jsonb_array_elements(v_out) x where x->>'type' = 'preorder') then
      v_out := v_out || (public.gx__default_block('preorder') || '{"enabled": true}'::jsonb);
    else
      select jsonb_agg(case when x->>'type' = 'preorder' then x || '{"enabled": true}'::jsonb else x end order by n) into v_out
        from jsonb_array_elements(v_out) with ordinality e(x, n);
    end if;
  end if;
  return jsonb_build_object('look', v_look, 'theme', th, 'blocks', v_out);
end $$;

-- ------------------------------------------------------------------------------------------------------ diff + classify
-- Flattens a cleaned document into (path, label, value) rows; the gate reads changes, never the whole page.
create or replace function public.gx__flat(d jsonb)
returns table (path text, label text, kind text, value jsonb) language sql immutable as $$
  select 'look', 'Look', 'style', d->'look'
  union all
  select 'theme.' || k, 'Colour: ' || k, 'style', v from jsonb_each(d->'theme') e(k, v)
  union all
  select 'order', 'Block order', 'style', (select jsonb_agg(x->>'type' order by n) from jsonb_array_elements(d->'blocks') with ordinality o(x, n) where (x->>'enabled')::boolean)
  union all
  select 'blocks.' || (x->>'type') || '.enabled', initcap(replace(x->>'type', '_', ' ')) || ' block on', 'switch', x->'enabled'
    from jsonb_array_elements(d->'blocks') x
  union all
  select 'blocks.' || (x->>'type') || '.' || k, initcap(replace(x->>'type', '_', ' ')) || ': ' || replace(k, '_', ' '),
         case when jsonb_typeof(v) = 'string' and k not in ('image_id', 'card_style', 'style', 'opens', 'closes', 'limited_until') then 'text' else 'value' end, v
    from jsonb_array_elements(d->'blocks') x, jsonb_each(x->'props') p(k, v);
$$;

create or replace function public.gx__text_risk(p text)
returns table (category text, why text) language sql immutable as $$
  select 'money', 'mentions a price, discount or offer' where p ~* '(₹|\mrs\.?\s?[0-9]|%|\moff\M|\mfree\M|discount|\moffers?\M|\msale\M|cash ?back|\mdeals?\M|buy\s*[0-9]|[0-9]+\s*\+\s*[0-9]+|\mflat\s+[0-9])'
  union all
  select 'security', 'contains a phone number' where p ~ '(\+?[0-9][0-9 -]{8,}[0-9])'
  union all
  select 'security', 'contains an e-mail address' where p ~* '[^ @]+@[^ @]+\.[a-z]{2,}'
  union all
  select 'security', 'contains a web address' where p ~* '(https?:|www\.|\.(com|in|co|net|org|app|io|me|link|ly)(\M|/))';
$$;

-- changes (from -> to) with a risk each; risk of the publish = the highest. low < ai < high.
create or replace function public.gx__classify(p_old jsonb, p_new jsonb)
returns jsonb language plpgsql immutable set search_path = public, pg_temp as $$
declare c record; v_changes jsonb := '[]'::jsonb; v_risk text := 'low'; v_cats text[] := '{}'; r record; v_item jsonb; v_r text; v_cat text; v_why text;
begin
  for c in
    select coalesce(n.path, o.path) path, coalesce(n.label, o.label) label, coalesce(n.kind, o.kind) kind, o.value old_v, n.value new_v
      from public.gx__flat(p_old) o full join public.gx__flat(p_new) n on n.path = o.path
     where o.value is distinct from n.value
     order by 1
  loop
    v_r := 'low'; v_cat := 'style'; v_why := 'look and layout';
    if c.path in ('blocks.order_mode.dine_in', 'blocks.order_mode.pre_order') then
      v_r := 'high'; v_cat := 'compliance'; v_why := 'changes how guests can order (table number and GST bill depend on it)';
    elsif c.path in ('blocks.bill.feedback', 'blocks.bill.split') and c.new_v = 'false'::jsonb then
      v_r := 'high'; v_cat := 'compliance'; v_why := 'removes part of the guest''s bill';
    elsif c.kind = 'text' and c.new_v is not null and jsonb_typeof(c.new_v) = 'string' then
      v_r := 'ai'; v_cat := 'wording'; v_why := 'new wording, read by the AI reviewer';
      for r in select * from public.gx__text_risk(c.new_v #>> '{}') loop
        v_r := 'high'; v_cat := r.category; v_why := r.why; exit;
      end loop;
    end if;
    v_item := jsonb_build_object('path', c.path, 'label', c.label, 'from', c.old_v, 'to', c.new_v, 'risk', v_r, 'category', v_cat, 'why', v_why);
    v_changes := v_changes || v_item;
    if v_r = 'high' or (v_r = 'ai' and v_risk = 'low') then v_risk := v_r; end if;
    if v_r = 'high' and not (v_cat = any (v_cats)) then v_cats := v_cats || v_cat; end if;
  end loop;
  return jsonb_build_object('risk', v_risk, 'categories', to_jsonb(v_cats), 'changes', v_changes);
end $$;

-- one plain sentence for the reviewer and the restaurant
create or replace function public.gx__summary(p_changes jsonb, p_risk text) returns text language sql immutable as $$
  select case
    when jsonb_array_length(p_changes) = 0 then 'No changes.'
    when p_risk = 'high' then 'Held for review: ' || (select string_agg(x->>'label' || ' ' || (x->>'why') ||
            case when jsonb_typeof(x->'to') = 'string' then ' ("' || (x->>'to') || '")' else '' end, '; ')
            from jsonb_array_elements(p_changes) x where x->>'risk' = 'high') || '.'
    when p_risk = 'ai' then 'New wording in ' || (select string_agg(x->>'label', ', ') from jsonb_array_elements(p_changes) x where x->>'risk' = 'ai') || '.'
    else jsonb_array_length(p_changes) || ' look and layout change(s).' end;
$$;

-- ---------------------------------------------------------------------------------------------------------- state
create or replace function public.gx__live(p_org uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select v.definition from public.guest_experiences g join public.guest_experience_versions v on v.organization_id = g.organization_id and v.version = g.live_version
   where g.organization_id = p_org;
$$;

create or replace function public.gx__version_json(v public.guest_experience_versions, p_full boolean default false)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', v.id, 'version', v.version, 'status', v.status, 'risk', v.risk, 'categories', to_jsonb(v.categories),
    'summary', v.summary, 'ai_note', v.ai_note, 'review_note', v.review_note, 'ask_message', v.ask_message, 'source', v.source,
    'rollback_of', v.rollback_of, 'submitted_at', v.submitted_at, 'decided_at', v.decided_at, 'decided_kind', v.decided_kind,
    'decided_by_name', v.decided_by_name, 'change_count', jsonb_array_length(v.changes))
    || case when p_full then jsonb_build_object('changes', v.changes, 'definition', v.definition) else '{}'::jsonb end;
$$;

-- the experience a guest sees, with the welcome picture as a storage path the server turns into a link
create or replace function public.gx__public_def(p_org uuid) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d jsonb := coalesce(public.gx__live(p_org), public.gx__default('bistro_dark')); v_img text;
begin
  select si.path into v_img from public.storefront_images si
   where si.organization_id = p_org and si.deleted_at is null
     and si.id::text = (select x->'props'->>'image_id' from jsonb_array_elements(d->'blocks') x where x->>'type' = 'welcome');
  return d || jsonb_build_object('welcome_image_path', v_img, 'is_default', public.gx__live(p_org) is null);
end $$;

create or replace function public.gx_builder_get(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.sf__editor(auth.uid()); g public.guest_experiences%rowtype; l public.org_listing_profiles%rowtype; v_live jsonb;
begin
  select * into g from public.guest_experiences where organization_id = v_org;
  select * into l from public.org_listing_profiles where organization_id = v_org;
  v_live := public.gx__live(v_org);
  return jsonb_build_object(
    'draft', coalesce(g.draft, v_live, public.gx__default('bistro_dark')),
    'draft_version', coalesce(g.draft_version, 0),
    'has_unpublished', g.draft is not null and g.draft is distinct from v_live,
    'live_version', g.live_version,
    'live', v_live,
    'pending', (select public.gx__version_json(v, true) from public.guest_experience_versions v
                 where v.organization_id = v_org and v.status in ('pending_ai', 'pending_human') order by v.version desc limit 1),
    'last_decision', (select public.gx__version_json(v) from public.guest_experience_versions v
                       where v.organization_id = v_org and v.status not in ('superseded') order by v.version desc limit 1),
    'history', (select coalesce(jsonb_agg(public.gx__version_json(v) order by v.version desc), '[]'::jsonb)
                  from (select * from public.guest_experience_versions x where x.organization_id = v_org order by x.version desc limit 10) v),
    'business', jsonb_build_object('name', coalesce(l.public_name, (select name from public.organizations where id = v_org)), 'store_link', l.store_slug,
                                   'path', case when l.store_slug is not null then '/' || l.store_slug end),
    'blockers', to_jsonb(public.guest__public_blockers(v_org)),
    'can_publish', public.has_permission(v_org, 'storefront', 'publish'),
    'dishes', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price, 'image_url', m.image_url) order by m.sort_order, m.name), '[]'::jsonb)
                 from public.menu_items m where m.organization_id = v_org and m.is_available));
end $$;

create or replace function public.gx_draft_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.sf__editor(auth.uid()); g public.guest_experiences%rowtype; v_clean jsonb;
begin
  if nullif(p->>'expected_draft_version', '') is null then raise exception 'GX_BAD_REQUEST: reload the builder and try again'; end if;
  v_clean := public.gx__clean(v_org, p->'definition');
  insert into public.guest_experiences (organization_id, updated_by) values (v_org, auth.uid()) on conflict (organization_id) do nothing;
  select * into g from public.guest_experiences where organization_id = v_org for update;
  if (p->>'expected_draft_version')::int <> g.draft_version then raise exception 'GX_STALE: the page was changed on another device'; end if;
  update public.guest_experiences set draft = v_clean, draft_version = draft_version + 1, updated_by = auth.uid(), updated_at = now() where organization_id = v_org;
  return public.gx_builder_get('{}'::jsonb);
end $$;

-- makes an approved version the live one (the only writer of live_version)
create or replace function public.gx__go_live(p_id uuid, p_status text, p_kind text, p_by uuid, p_by_name text, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.guest_experience_versions%rowtype;
begin
  update public.guest_experience_versions set status = p_status, decided_kind = p_kind, decided_by = p_by, decided_by_name = p_by_name,
         decided_at = now(), review_note = coalesce(p_note, review_note)
   where id = p_id returning * into v;
  update public.guest_experiences set live_version = v.version, updated_at = now() where organization_id = v.organization_id
     and (live_version is null or live_version < v.version);
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (v.organization_id, case when p_kind = 'human' then p_by else v.submitted_by end, 'guest_experience.live', 'guest_experience_versions', v.id::text,
          null, jsonb_build_object('version', v.version, 'status', p_status, 'by', p_kind, 'by_name', p_by_name, 'risk', v.risk));
end $$;

create or replace function public.gx__submit(p_org uuid, p_def jsonb, p_source text, p_rollback_of int)
returns public.guest_experience_versions language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old jsonb; v_cls jsonb; v_next int; v public.guest_experience_versions%rowtype; v_risk text; v_status text;
begin
  v_old := coalesce(public.gx__live(p_org), public.gx__clean(p_org, public.gx__default('bistro_dark')));
  v_cls := public.gx__classify(v_old, p_def);
  if jsonb_array_length(v_cls->'changes') = 0 then raise exception 'GX_NOTHING_TO_PUBLISH: the guest page already looks like this'; end if;
  v_risk := case when p_source = 'rollback' then 'low' else v_cls->>'risk' end;
  v_status := case v_risk when 'low' then 'auto_approved' when 'ai' then 'pending_ai' else 'pending_human' end;
  -- one version waits at a time: a newer publish replaces the waiting one
  update public.guest_experience_versions set status = 'superseded', decided_at = now(), decided_kind = 'rules', review_note = 'Replaced by a newer publish'
   where organization_id = p_org and status in ('pending_ai', 'pending_human');
  select coalesce(max(version), 0) + 1 into v_next from public.guest_experience_versions where organization_id = p_org;
  insert into public.guest_experience_versions (organization_id, version, definition, source, rollback_of, status, risk, categories, changes, summary, submitted_by)
  values (p_org, v_next, p_def, p_source, p_rollback_of, v_status, v_risk,
          array(select jsonb_array_elements_text(v_cls->'categories')), v_cls->'changes',
          case when p_source = 'rollback' then 'Rolled back to version ' || p_rollback_of || '.' else public.gx__summary(v_cls->'changes', v_risk) end, auth.uid())
  returning * into v;
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (p_org, auth.uid(), 'guest_experience.submitted', 'guest_experience_versions', v.id::text, null,
          jsonb_build_object('version', v.version, 'risk', v.risk, 'status', v.status, 'categories', v.categories, 'changes', jsonb_array_length(v.changes)));
  if v_status = 'auto_approved' then
    perform public.gx__go_live(v.id, 'auto_approved', case when p_source = 'rollback' then 'rollback' else 'rules' end, null, 'Rules (look and layout only)');
    select * into v from public.guest_experience_versions where id = v.id;
  end if;
  return v;
end $$;

create or replace function public.gx_publish(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.sf__editor(auth.uid()); g public.guest_experiences%rowtype; l public.org_listing_profiles%rowtype; v public.guest_experience_versions%rowtype;
begin
  if not public.has_permission(v_org, 'storefront', 'publish') then raise exception 'GX_FORBIDDEN: your role cannot publish the guest page'; end if;
  select * into g from public.guest_experiences where organization_id = v_org for update;
  if not found or g.draft is null then raise exception 'GX_NOTHING_TO_PUBLISH: save a change first'; end if;
  if p ? 'expected_draft_version' and (p->>'expected_draft_version')::int <> g.draft_version then
    raise exception 'GX_STALE: the page changed after you previewed it'; end if;
  select * into l from public.org_listing_profiles where organization_id = v_org;
  if l.public_name is null or l.store_slug is null then raise exception 'GX_NOT_READY: add your business name and store link in Business Profile first'; end if;
  v := public.gx__submit(v_org, public.gx__clean(v_org, g.draft), 'publish', null);
  return jsonb_build_object('result', v.status, 'version', public.gx__version_json(v, true), 'path', '/' || l.store_slug)
      || jsonb_build_object('builder', public.gx_builder_get('{}'::jsonb));
end $$;

create or replace function public.gx_rollback(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.sf__editor(auth.uid()); old public.guest_experience_versions%rowtype; v public.guest_experience_versions%rowtype;
begin
  if not public.has_permission(v_org, 'storefront', 'publish') then raise exception 'GX_FORBIDDEN: your role cannot publish the guest page'; end if;
  perform 1 from public.guest_experiences where organization_id = v_org for update;
  select * into old from public.guest_experience_versions where organization_id = v_org and version = nullif(p->>'version', '')::int;
  if not found then raise exception 'GX_NOT_FOUND: that version does not exist'; end if;
  if old.status not in ('auto_approved', 'ai_approved', 'human_approved') then raise exception 'GX_BAD_REQUEST: only a version that was live can come back'; end if;
  v := public.gx__submit(v_org, old.definition, 'rollback', old.version);
  update public.guest_experiences set draft = old.definition, draft_version = draft_version + 1, updated_by = auth.uid() where organization_id = v_org;
  return jsonb_build_object('result', v.status, 'version', public.gx__version_json(v)) || jsonb_build_object('builder', public.gx_builder_get('{}'::jsonb));
end $$;

-- ----------------------------------------------------------------------------------------------- AI step (server only)
-- The server reads the changed wording of a pending_ai version, asks the AI reviewer, and reports here. Only the service key
-- (server) can call it. An "ok" can only publish what the rules already let through to AI; a "flag" sends it to a human.
create or replace function public.gx_ai_pending(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'organization_id', v.organization_id, 'version', v.version,
      'business', (select coalesce(l.public_name, o.name) from public.organizations o left join public.org_listing_profiles l on l.organization_id = o.id where o.id = v.organization_id),
      'wording', (select coalesce(jsonb_agg(jsonb_build_object('label', x->>'label', 'from', x->'from', 'to', x->'to')), '[]'::jsonb)
                    from jsonb_array_elements(v.changes) x where x->>'risk' = 'ai'))
      order by v.submitted_at), '[]'::jsonb)
    from public.guest_experience_versions v
   where v.status = 'pending_ai' and (nullif(p->>'id', '') is null or v.id = (p->>'id')::uuid);
$$;

create or replace function public.gx_ai_verdict(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.guest_experience_versions%rowtype; v_verdict text := p->>'verdict'; v_note text := left(nullif(btrim(coalesce(p->>'note', '')), ''), 400);
begin
  if v_verdict not in ('ok', 'flag', 'unavailable') then raise exception 'GX_BAD_REQUEST: verdict is ok, flag or unavailable'; end if;
  select * into v from public.guest_experience_versions where id = nullif(p->>'id', '')::uuid for update;
  if not found then raise exception 'GX_NOT_FOUND: version not found'; end if;
  if v.status <> 'pending_ai' then return public.gx__version_json(v) || jsonb_build_object('replayed', true); end if;
  update public.guest_experience_versions set ai_note = coalesce(v_note, case v_verdict when 'unavailable' then 'AI reviewer not reachable; rules found nothing risky.' end),
         ai_model = left(p->>'model', 80) where id = v.id;
  if v_verdict = 'flag' then
    update public.guest_experience_versions set status = 'pending_human', risk = 'high',
           categories = (select array_agg(distinct c) from unnest(categories || coalesce(nullif(p->>'category', ''), 'wording')) c)
     where id = v.id;
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, after)
    values (v.organization_id, 'guest_experience.ai_flagged', 'guest_experience_versions', v.id::text, jsonb_build_object('version', v.version, 'note', v_note));
  else
    perform public.gx__go_live(v.id, 'ai_approved', 'ai', null, coalesce(left(p->>'model', 80), 'AI reviewer'));
  end if;
  select * into v from public.guest_experience_versions where id = v.id;
  return public.gx__version_json(v);
end $$;

-- ------------------------------------------------------------------------------------------- OneLocal review (Master)
-- Called by the Master server (its own login and permission checks); not callable by restaurant logins.
create or replace function public.gx_review_queue(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_status text := coalesce(nullif(p->>'status', ''), 'waiting');
begin
  if v_status not in ('waiting', 'decided', 'all') then raise exception 'GX_BAD_REQUEST: unknown filter'; end if;
  return jsonb_build_object(
    'waiting', (select count(*) from public.guest_experience_versions where status in ('pending_ai', 'pending_human')),
    'items', (select coalesce(jsonb_agg(x order by (x->>'submitted_at') desc), '[]'::jsonb) from (
       select public.gx__version_json(v) || jsonb_build_object('organization_id', v.organization_id, 'business', coalesce(l.public_name, o.name),
                'store_link', l.store_slug) x
         from public.guest_experience_versions v join public.organizations o on o.id = v.organization_id
         left join public.org_listing_profiles l on l.organization_id = v.organization_id
        where (v_status = 'all' and v.status <> 'superseded')
           or (v_status = 'waiting' and v.status in ('pending_ai', 'pending_human'))
           or (v_status = 'decided' and v.status in ('human_approved', 'rejected', 'ai_approved', 'auto_approved'))
        order by v.submitted_at desc limit 200) q));
end $$;

create or replace function public.gx_review_get(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v public.guest_experience_versions%rowtype;
begin
  select * into v from public.guest_experience_versions where id = nullif(p->>'id', '')::uuid;
  if not found then raise exception 'GX_NOT_FOUND: review not found'; end if;
  return public.gx__version_json(v, true) || jsonb_build_object('organization_id', v.organization_id,
    'business', (select coalesce(l.public_name, o.name) from public.organizations o left join public.org_listing_profiles l on l.organization_id = o.id where o.id = v.organization_id),
    'store_link', (select store_slug from public.org_listing_profiles where organization_id = v.organization_id),
    'live_version', (select live_version from public.guest_experiences where organization_id = v.organization_id),
    'history', (select coalesce(jsonb_agg(public.gx__version_json(h) order by h.version desc), '[]'::jsonb)
                  from (select * from public.guest_experience_versions x where x.organization_id = v.organization_id order by x.version desc limit 10) h));
end $$;

create or replace function public.gx_review_decide(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.guest_experience_versions%rowtype; v_action text := p->>'action'; v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
  v_actor uuid := nullif(p->>'actor_id', '')::uuid; v_name text := left(coalesce(nullif(p->>'actor_name', ''), 'OneLocal reviewer'), 80);
begin
  if v_action not in ('approve', 'reject', 'ask') then raise exception 'GX_BAD_REQUEST: approve, reject or ask'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'GX_BAD_REQUEST: the note can be up to 500 characters'; end if;
  if v_action in ('reject', 'ask') and v_note is null then raise exception 'GX_BAD_REQUEST: write what the restaurant should change'; end if;
  select * into v from public.guest_experience_versions where id = nullif(p->>'id', '')::uuid for update;
  if not found then raise exception 'GX_NOT_FOUND: review not found'; end if;
  if v.status not in ('pending_human', 'pending_ai') then
    if (v_action = 'approve' and v.status = 'human_approved') or (v_action = 'reject' and v.status = 'rejected') then
      return public.gx__version_json(v, true) || jsonb_build_object('replayed', true); end if;
    raise exception 'GX_WRONG_STATE: this publish is already %', replace(v.status, '_', ' ');
  end if;
  if v_action = 'approve' then
    perform public.gx__go_live(v.id, 'human_approved', 'human', v_actor, v_name, v_note);
  elsif v_action = 'reject' then
    update public.guest_experience_versions set status = 'rejected', decided_kind = 'human', decided_by = v_actor, decided_by_name = v_name,
           decided_at = now(), review_note = v_note where id = v.id;
  else
    update public.guest_experience_versions set ask_message = v_note, status = 'pending_human' where id = v.id;
  end if;
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, after)
  values (v.organization_id, v_actor, 'guest_experience.review_' || v_action, 'guest_experience_versions', v.id::text,
          jsonb_build_object('version', v.version, 'by', v_actor, 'by_name', v_name, 'note', v_note));
  select * into v from public.guest_experience_versions where id = v.id;
  return public.gx__version_json(v, true);
end $$;

-- ------------------------------------------------------------------------------------------------------- public read
-- A restaurant with a live guest experience counts as published for the public link and the table QR.
create or replace function public.guest__published(p_org uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select v.definition from public.vinii_storefronts s
       join public.vinii_storefront_versions v on v.organization_id = s.organization_id and v.version = s.published_version
      where s.organization_id = p_org and s.published_version > 0),
    (select '{}'::jsonb where public.gx__live(p_org) is not null));
$$;

-- the menu answer (table QR and public link) also carries the experience
do $$
declare v_src text := replace(pg_get_functiondef('public.guest__menu'::regproc), E'\r', '');
begin
  if v_src not like '%''experience'', public.gx__public_def%' then
    v_src := replace(v_src, $r$'items', v_items);$r$, $r$'items', v_items,
    'experience', public.gx__public_def(p_org));$r$);
    if v_src not like '%''experience'', public.gx__public_def%' then raise exception '0656: guest__menu has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- store links that can never belong to a restaurant: they are pages of onelocal.co itself
create or replace function public.gx__reserved_slug(p text) returns boolean language sql immutable as $$
  select lower(p) = any (array['privacy', 'terms', 'delete-account', 'join', 'auth', 'api', 'm', 't', 'b', 'r', 'guest', 'rpc', 'health',
    'admin', 'partner', 'partners', 'app', 'static', 'assets', 'www', 'help', 'support', 'about', 'login', 'signup', 'signin', 'onelocal',
    'source', 'ol-api', 'webhooks', 'download', 'blog', 'careers', 'contact', 'master', 'rider', 'riders', 'store', 'stores']);
$$;

create or replace function public.org_listing_slug_not_reserved() returns trigger language plpgsql as $$
begin
  if new.store_slug is not null and public.gx__reserved_slug(new.store_slug) then
    raise exception 'SF_BAD_REQUEST: "%" is a OneLocal page name; choose another store link', new.store_slug;
  end if;
  return new;
end $$;
drop trigger if exists org_listing_slug_not_reserved on public.org_listing_profiles;
create trigger org_listing_slug_not_reserved before insert or update of store_slug on public.org_listing_profiles
  for each row execute function public.org_listing_slug_not_reserved();

-- ----------------------------------------------------------------------------------------------------------- pre-order
create or replace function public.gx__preorder_block(p_org uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select x->'props' from jsonb_array_elements(public.gx__live(p_org)->'blocks') x
   where x->>'type' = 'preorder' and (x->>'enabled')::boolean
     and exists (select 1 from jsonb_array_elements(public.gx__live(p_org)->'blocks') m where m->>'type' = 'order_mode' and (m->'props'->>'pre_order')::boolean);
$$;

-- the time slots a guest may pick (restaurant time zone), for the next days_ahead days
create or replace function public.gx_preorder_slots(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_slug text := lower(btrim(coalesce(p->>'slug', ''))); v_org uuid; b jsonb; v_tz text; v_now timestamptz := now(); v_days jsonb := '[]'::jsonb;
  d date; s timestamptz; v_slots jsonb; v_end timestamptz;
begin
  select organization_id into v_org from public.org_listing_profiles where store_slug = v_slug;
  if v_org is null or cardinality(public.guest__public_blockers(v_org)) > 0 then raise exception 'GUEST_NOT_FOUND: this page is not available right now.'; end if;
  b := public.gx__preorder_block(v_org);
  if b is null then raise exception 'GUEST_NOT_FOUND: this restaurant does not take pre-orders right now.'; end if;
  v_tz := coalesce((public.guest__public_outlet(v_org)).timezone, 'Asia/Kolkata');
  for d in select generate_series((v_now at time zone v_tz)::date, (v_now at time zone v_tz)::date + ((b->>'days_ahead')::int - 1), interval '1 day')::date loop
    v_slots := '[]'::jsonb;
    s := (d + (b->>'opens')::time) at time zone v_tz; v_end := (d + (b->>'closes')::time) at time zone v_tz;
    while s < v_end loop
      if s >= v_now + make_interval(mins => (b->>'lead_minutes')::int) then v_slots := v_slots || to_jsonb(s); end if;
      s := s + make_interval(mins => (b->>'slot_minutes')::int);
    end loop;
    if jsonb_array_length(v_slots) > 0 then v_days := v_days || jsonb_build_object('date', d, 'slots', v_slots); end if;
  end loop;
  return jsonb_build_object('timezone', v_tz, 'slot_minutes', (b->>'slot_minutes')::int, 'note_hint', b->>'note_hint', 'days', v_days);
end $$;

create or replace function public.gx_preorder_place(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_slug text := lower(btrim(coalesce(p->>'slug', ''))); v_org uuid; v_loc public.locations%rowtype; v_key text := btrim(coalesce(p->>'idempotency_key', ''));
  v_name text; v_note text; v_phone text := regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'); v_at timestamptz; v_slots jsonb;
  v_chk jsonb; v_hash text; v_token text; r public.guest_order_requests%rowtype;
begin
  if char_length(v_key) not between 8 and 100 or v_key !~ '^[A-Za-z0-9_:.-]+$' then raise exception 'GUEST_BAD_REQUEST: the request key is missing'; end if;
  select organization_id into v_org from public.org_listing_profiles where store_slug = v_slug;
  if v_org is null or cardinality(public.guest__public_blockers(v_org)) > 0 then raise exception 'GUEST_NOT_FOUND: this page is not available right now.'; end if;
  if public.gx__preorder_block(v_org) is null then raise exception 'GUEST_NOT_FOUND: this restaurant does not take pre-orders right now.'; end if;
  if char_length(v_phone) = 12 and v_phone like '91%' then v_phone := substr(v_phone, 3); end if;
  if v_phone !~ '^[6-9][0-9]{9}$' then raise exception 'GUEST_BAD_REQUEST: enter a 10-digit mobile number'; end if;
  v_name := public.guest__text(p->>'guest_name', 40, 'a name');
  if v_name is null then raise exception 'GUEST_BAD_REQUEST: enter your name so the staff can call you'; end if;
  v_note := public.guest__text(p->>'note', 300, 'a note');
  begin v_at := (p->>'pickup_at')::timestamptz; exception when others then raise exception 'GUEST_BAD_REQUEST: pick a pickup time'; end;
  v_slots := public.gx_preorder_slots(jsonb_build_object('slug', v_slug));
  if v_at is null or not exists (select 1 from jsonb_array_elements(v_slots->'days') dd, jsonb_array_elements_text(dd->'slots') sl where sl::timestamptz = v_at) then
    raise exception 'GUEST_BAD_REQUEST: that pickup time is not available any more, pick another'; end if;
  v_hash := public.guest__hash(coalesce(p->'lines', 'null'::jsonb)::text || '|' || v_name || '|' || v_phone || '|' || v_at::text || '|' || coalesce(v_note, ''));
  select * into r from public.guest_order_requests where organization_id = v_org and kind = 'preorder' and idempotency_key = v_key;
  if found then
    if r.body_hash <> v_hash then raise exception 'GUEST_IDEMPOTENCY_MISMATCH: this request key was already used for a different order'; end if;
    return public.guest__request_json(r) || jsonb_build_object('replayed', true, 'kind', 'preorder', 'pickup_at', r.pickup_at,
      'track', null, 'message', 'Already sent. Use the tracking link you got the first time.');
  end if;
  perform 1 from public.organizations where id = v_org for update;   -- one sender at a time per restaurant: the limits below hold
  if (select count(*) from public.guest_order_requests q where q.organization_id = v_org and q.kind = 'preorder' and q.guest_phone = v_phone and q.status = 'waiting') >= 2 then
    raise exception 'GUEST_RATE_LIMITED: you already have pre-orders waiting for the restaurant. They will confirm shortly.'; end if;
  if (select count(*) from public.guest_order_requests q where q.organization_id = v_org and q.kind = 'preorder' and q.status = 'waiting') >= 30 then
    raise exception 'GUEST_RATE_LIMITED: the restaurant is busy right now. Please try again in a few minutes.'; end if;
  v_loc := public.guest__public_outlet(v_org);
  v_chk := public.guest__lines(v_org, v_loc.id, p->'lines');
  v_token := encode(extensions.gen_random_bytes(18), 'hex');
  insert into public.guest_order_requests (organization_id, location_id, table_id, session_id, idempotency_key, body_hash, lines, item_count, estimated_total,
                                           guest_name, note, kind, pickup_at, guest_phone, track_hash)
  values (v_org, v_loc.id, null, null, v_key, v_hash, v_chk->'lines', (v_chk->>'item_count')::int, (v_chk->>'estimated_total')::numeric,
          v_name, v_note, 'preorder', v_at, v_phone, public.guest__hash(v_token))
  returning * into r;
  return public.guest__request_json(r) || jsonb_build_object('replayed', false, 'kind', 'preorder', 'pickup_at', r.pickup_at, 'track', v_token);
end $$;

create or replace function public.gx_preorder_status(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.guest_order_requests%rowtype; v_tok text := btrim(coalesce(p->>'track', ''));
begin
  if v_tok !~ '^[0-9a-f]{36}$' then raise exception 'GUEST_NOT_FOUND: this tracking link is not valid.'; end if;
  select * into r from public.guest_order_requests where track_hash = public.guest__hash(v_tok) and kind = 'preorder';
  if not found then raise exception 'GUEST_NOT_FOUND: this tracking link is not valid.'; end if;
  return public.guest__request_json(r) || jsonb_build_object('kind', 'preorder', 'pickup_at', r.pickup_at, 'guest_name', r.guest_name,
    'business', (select coalesce(l.public_name, o.name) from public.organizations o left join public.org_listing_profiles l on l.organization_id = o.id where o.id = r.organization_id));
end $$;

-- staff see the kind and the pickup time; accepting a pre-order makes a pickup order through the one order writer
create or replace function public.guest__staff_request_json(r public.guest_order_requests)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select public.guest__request_json(r) || jsonb_build_object('table', (select jsonb_build_object('id', t.id, 'label', t.label) from public.dining_tables t where t.id = r.table_id),
    'guest_name', r.guest_name, 'minutes_waiting', greatest(0, floor(extract(epoch from (coalesce(r.decided_at, now()) - r.created_at)) / 60))::int,
    'order_id', r.order_id, 'kind', r.kind, 'pickup_at', r.pickup_at, 'guest_phone', r.guest_phone);
$$;

do $$
declare v_src text := replace(pg_get_functiondef('public.guest_request_decide'::regproc), E'\r', '');
begin
  if v_src not like '%r.kind = ''preorder''%' then
    v_src := replace(v_src,
      $r$  select * into t from public.dining_tables where id = r.table_id;
  if not t.is_active then raise exception 'TBL_NOT_FOUND: this table is no longer in use'; end if;
  select jsonb_agg(jsonb_build_object('menu_item_id', l->'menu_item_id', 'qty', l->'qty', 'notes', l->'notes')) into v_lines from jsonb_array_elements(r.lines) l;$r$,
      $r$  select jsonb_agg(jsonb_build_object('menu_item_id', l->'menu_item_id', 'qty', l->'qty', 'notes', l->'notes')) into v_lines from jsonb_array_elements(r.lines) l;
  if r.kind = 'preorder' then
    v_place := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'pickup',
      'placed_by', 'guest', 'idempotency_key', 'guest:' || r.id, 'lines', v_lines, 'customer_name', r.guest_name,
      'notes', concat_ws(' · ', 'Pre-order from the guest page', 'pickup ' || to_char(r.pickup_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
                         'phone ' || r.guest_phone, r.note)));
    update public.guest_order_requests set status = 'accepted', decided_by = auth.uid(), decided_at = now(), order_id = (v_place->>'id')::uuid where id = r.id returning * into r;
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, r.order_id, 'guest_request_accepted', 'Pre-order for ' || r.guest_name || ' accepted', 'pos', jsonb_build_object('by', auth.uid(), 'request_id', r.id, 'kind', 'preorder'));
    return public.guest__staff_request_json(r) || jsonb_build_object('replayed', false, 'order', v_place);
  end if;
  select * into t from public.dining_tables where id = r.table_id;
  if not t.is_active then raise exception 'TBL_NOT_FOUND: this table is no longer in use'; end if;$r$);
    if v_src not like '%r.kind = ''preorder''%' then raise exception '0656: guest_request_decide has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------------------ grants
revoke all on function public.gx_builder_get(jsonb), public.gx_draft_save(jsonb), public.gx_publish(jsonb), public.gx_rollback(jsonb) from public, anon;
grant execute on function public.gx_builder_get(jsonb), public.gx_draft_save(jsonb), public.gx_publish(jsonb), public.gx_rollback(jsonb) to authenticated;
-- server (service key) and Master server only
revoke all on function public.gx_ai_pending(jsonb), public.gx_ai_verdict(jsonb), public.gx_review_queue(jsonb), public.gx_review_get(jsonb),
  public.gx_review_decide(jsonb), public.gx_preorder_slots(jsonb), public.gx_preorder_place(jsonb), public.gx_preorder_status(jsonb) from public, anon, authenticated;
grant execute on function public.gx_ai_pending(jsonb), public.gx_ai_verdict(jsonb), public.gx_review_queue(jsonb), public.gx_review_get(jsonb),
  public.gx_review_decide(jsonb), public.gx_preorder_slots(jsonb), public.gx_preorder_place(jsonb), public.gx_preorder_status(jsonb) to service_role;
-- internal helpers: no direct calls from apps
revoke all on function public.gx__clean(uuid, jsonb), public.gx__live(uuid), public.gx__public_def(uuid), public.gx__go_live(uuid, text, text, uuid, text, text),
  public.gx__submit(uuid, jsonb, text, int), public.gx__preorder_block(uuid), public.gx__version_json(public.guest_experience_versions, boolean) from public, anon, authenticated;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0656_guest_experience.sql', 'Guest experience builder: experience draft/versions, tiered publish gate (rules, AI, OneLocal review), rollback, pre-orders into the guest inbox (local dev DB 2026-11-04)')
on conflict do nothing;

commit;
