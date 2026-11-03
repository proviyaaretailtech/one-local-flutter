-- 0651: the business day (Day close, pos_day_*) and Delete account (acct_delete_*) as they are on hosted (3 Nov 2026).
-- They were written on 31 Oct and applied on hosted from C:\onelocal\hosted_pending_2026-10-31_FINAL.sql, a file that never reached the
-- repo: the app and the server called functions that no migration made, so the local test database had none of them ("Something went
-- wrong" on Delete account). Copied exactly from hosted (hosted-push/run/35_export_day_close_delete_account_READ_ONLY.sql): 4 tables,
-- 19 functions, their grants and the two scheduled jobs (the 30-day purge at 03:40, the business day's auto start every 10 minutes).
-- One change from hosted (also hosted piece 36): the five internal helpers pos_day__can, pos_day__json, pos_day__today,
-- pos_day__window_end and pos_day_cash_totals could be called by anyone, signed in or not; they check nobody, and pos_day__json returns a
-- store's whole day (cash, who changed the opening cash, stock counts) for a day id. Only the functions that use them need them now.
-- Safe to run again; on hosted everything here already exists.

-- ---------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.pos_business_days (
  id uuid not null default gen_random_uuid() primary key,
  organization_id uuid not null references public.organizations(id),
  location_id uuid not null references public.locations(id),
  business_date date not null,
  status text not null check (status = any (array['started', 'provisional', 'attention', 'closed'])),
  attention_reason text check (attention_reason = any (array['no_previous_closing', 'previous_not_closed', 'not_closed', 'closing_approval'])),
  start_trigger text not null check (start_trigger = any (array['opening_time', 'first_activity', 'manual'])),
  started_by uuid,
  started_at timestamptz not null default now(),
  window_start timestamptz not null,
  prev_day_id uuid references public.pos_business_days(id),
  carried_cash numeric(12,2),
  opening_cash numeric(12,2) check (opening_cash is null or opening_cash >= 0),
  opening_cash_source text check (opening_cash_source = any (array['carried', 'entered', 'provisional'])),
  expected_cash numeric(12,2),
  counted_cash numeric(12,2) check (counted_cash is null or counted_cash >= 0),
  variance numeric(12,2),
  variance_reason text check (variance_reason is null or (char_length(variance_reason) >= 3 and char_length(variance_reason) <= 200)),
  cash_totals jsonb,
  counted_by uuid,
  counted_at timestamptz,
  close_key text,
  closed_by uuid,
  closed_at timestamptz,
  close_note text check (close_note is null or char_length(close_note) <= 300),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  unique (location_id, business_date)
);
create index if not exists pos_business_days_org_date on public.pos_business_days (organization_id, business_date desc);
alter table public.pos_business_days enable row level security;

create table if not exists public.pos_day_cash_adjustments (
  id uuid not null default gen_random_uuid() primary key,
  organization_id uuid not null references public.organizations(id),
  day_id uuid not null references public.pos_business_days(id),
  kind text not null check (kind = any (array['opening_initial', 'opening_correction', 'provisional_opening', 'opening_carried', 'closing_count'])),
  original_amount numeric(12,2),
  revised_amount numeric(12,2) not null check (revised_amount >= 0),
  reason text check (reason is null or (char_length(reason) >= 3 and char_length(reason) <= 200)),
  approval_status text not null default 'approved' check (approval_status = any (array['approved', 'pending', 'rejected'])),
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 300),
  idempotency_key text check (idempotency_key is null or (char_length(idempotency_key) >= 1 and char_length(idempotency_key) <= 100)),
  unique (organization_id, idempotency_key)
);
create index if not exists pos_day_cash_adjustments_day on public.pos_day_cash_adjustments (day_id, created_at);
alter table public.pos_day_cash_adjustments enable row level security;

create table if not exists public.pos_day_stock_snapshots (
  day_id uuid not null references public.pos_business_days(id),
  kind text not null check (kind = any (array['opening', 'closing'])),
  inventory_item_id uuid not null references public.inventory_items(id),
  on_hand numeric not null,
  taken_at timestamptz not null default now(),
  primary key (day_id, kind, inventory_item_id)
);
alter table public.pos_day_stock_snapshots enable row level security;

-- the store's cash-drawer close (the store team's Money; on hosted only until now)
create table if not exists public.money_store_day_close (
  organization_id uuid not null,
  location_id uuid not null,
  day date not null,
  expected_minor bigint not null,
  counted_minor bigint not null,
  closed_by uuid not null,
  closed_at timestamptz not null default now(),
  primary key (organization_id, location_id, day)
);
alter table public.money_store_day_close enable row level security;

-- pos_day_cash_totals reads the store team's cash book (money_store_entries, on hosted only). Where it is missing (the local test
-- database) a table with just the columns it reads stands in, so the business day can be tried; hosted's own table is not touched.
do $c$ begin
  if to_regclass('public.money_store_entries') is null then
    create table public.money_store_entries (
      id uuid primary key default gen_random_uuid(), organization_id uuid not null, location_id uuid, account text not null, direction text not null,
      kind text not null, amount_minor bigint not null, status text not null default 'posted', created_at timestamptz not null default now());
    alter table public.money_store_entries enable row level security;
    comment on table public.money_store_entries is 'Local stand-in (0651) for the store team''s hosted table: only the columns pos_day_cash_totals reads.';
  end if;
end $c$;

-- ---------------------------------------------------------------------------------------------------------------- Delete account
CREATE OR REPLACE FUNCTION public.acct_delete_cancel()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_uid uuid := auth.uid(); q public.ol_privacy_requests%rowtype;
begin
  if v_uid is null then raise exception 'ACCT_FORBIDDEN: sign in first'; end if;
  update public.ol_privacy_requests set status = 'withdrawn', resolved_at = now(), updated_at = now(),
         details = details || jsonb_build_object('withdrawn', 'signed in again')
   where user_id = v_uid and kind = 'erasure' and status = 'received' and details->>'scope' = 'partner_account'
  returning * into q;
  if not found then return jsonb_build_object('cancelled', false); end if;
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, after)
  values (public.current_org_id(), v_uid, 'account.delete_cancelled', 'auth_user', v_uid::text, jsonb_build_object('reference', q.reference));
  return jsonb_build_object('cancelled', true, 'reference', q.reference);
end $function$;

CREATE OR REPLACE FUNCTION public.acct_delete_preview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'ACCT_FORBIDDEN: sign in first'; end if;
  return jsonb_build_object(
    'memberships', (select count(*) from public.org_users ou where ou.user_id = v_uid and ou.status = 'active'),
    -- businesses where this person is the only active owner: nobody will be able to manage them after
    'sole_owner_of', (select coalesce(jsonb_agg(o.name order by o.name), '[]'::jsonb)
                        from public.org_users ou join public.roles r on r.id = ou.role_id join public.organizations o on o.id = ou.organization_id
                       where ou.user_id = v_uid and ou.status = 'active' and r.slug = 'org_owner'
                         and not exists (select 1 from public.org_users x join public.roles xr on xr.id = x.role_id
                                          where x.organization_id = ou.organization_id and x.user_id <> v_uid and x.status = 'active' and xr.slug = 'org_owner')),
    'pending', (select jsonb_build_object('reference', q.reference, 'due_at', q.due_at) from public.ol_privacy_requests q
                 where q.user_id = v_uid and q.kind = 'erasure' and q.status = 'received' and q.details->>'scope' = 'partner_account'
                 order by q.created_at desc limit 1));
end $function$;

CREATE OR REPLACE FUNCTION public.acct_delete_request(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_uid uuid := auth.uid(); q public.ol_privacy_requests%rowtype; v_ref text;
begin
  if v_uid is null then raise exception 'ACCT_FORBIDDEN: sign in first'; end if;
  if coalesce(p->>'confirm', '') <> 'DELETE' then raise exception 'ACCT_BAD_REQUEST: type DELETE to confirm'; end if;
  -- asked twice (a retried tap): the same request
  select * into q from public.ol_privacy_requests where user_id = v_uid and kind = 'erasure' and status = 'received' and details->>'scope' = 'partner_account'
   order by created_at desc limit 1;
  if found then return jsonb_build_object('reference', q.reference, 'due_at', q.due_at, 'replayed', true); end if;
  loop
    v_ref := 'AD-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.ol_privacy_requests where reference = v_ref);
  end loop;
  insert into public.ol_privacy_requests (user_id, organization_id, kind, status, reference, details, due_at)
  values (v_uid, public.current_org_id(), 'erasure', 'received', v_ref,
          jsonb_build_object('scope', 'partner_account', 'requested_via', 'manage_account', 'reason', left(btrim(coalesce(p->>'reason', '')), 300)),
          now() + interval '30 days')
  returning * into q;
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, after)
  values (public.current_org_id(), v_uid, 'account.delete_requested', 'auth_user', v_uid::text, jsonb_build_object('reference', q.reference, 'due_at', q.due_at));
  return jsonb_build_object('reference', q.reference, 'due_at', q.due_at, 'replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.acct_deletion_purge()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q record; v_done int := 0; v_failed int := 0; v_gone text := '';
begin
  for q in select * from public.ol_privacy_requests
            where kind = 'erasure' and status = 'received' and details->>'scope' = 'partner_account' and due_at <= now() and user_id is not null
            order by due_at limit 200 loop
    begin
      v_gone := 'deleted-' || left(replace(q.user_id::text, '-', ''), 12) || '@deleted.invalid';
      -- out of every business; the rows stay (bills and audit point at them) but no longer name the person
      update public.org_users set status = 'suspended', email = v_gone, full_name = null, updated_at = now() where user_id = q.user_id;
      delete from public.org_user_locations where user_id = q.user_id;
      delete from public.user_preferences where user_id = q.user_id;
      delete from public.notifications where user_id = q.user_id;
      delete from public.ol_partner_devices where user_id = q.user_id;
      delete from public.user_sessions where user_id = q.user_id;
      -- the login: every way in removed, personal details scrubbed, blocked for good
      delete from auth.sessions where user_id = q.user_id;
      delete from auth.refresh_tokens where user_id = q.user_id::text;
      delete from auth.identities where user_id = q.user_id;
      delete from auth.mfa_factors where user_id = q.user_id;
      update auth.users set email = null, phone = null, encrypted_password = '', email_change = '', phone_change = '',
             raw_user_meta_data = '{}'::jsonb, raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"account_deleted": true}'::jsonb,
             banned_until = 'infinity', deleted_at = now(), updated_at = now()
       where id = q.user_id;
      update public.ol_privacy_requests set status = 'completed', resolved_at = now(), updated_at = now(),
             details = details || jsonb_build_object('kept', 'sales, bills and tax records the business must keep, without the person''s details')
       where id = q.id;
      insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, after)
      values (q.organization_id, null, 'account.deleted', 'privacy_request', q.reference, jsonb_build_object('reference', q.reference));
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      update public.ol_privacy_requests set details = details || jsonb_build_object('last_error', left(sqlerrm, 300), 'last_try', now()) where id = q.id;
    end;
  end loop;
  return jsonb_build_object('deleted', v_done, 'failed', v_failed);
end $function$;

-- ---------------------------------------------------------------------------------------------------------------- business day: helpers
CREATE OR REPLACE FUNCTION public.pos_day__can(p_what text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.has_org_role(case p_what
    when 'read' then array['org_owner', 'org_admin', 'manager', 'biller', 'business_manager', 'location_manager', 'finance_manager', 'accountant', 'operations_manager']
    when 'count' then array['org_owner', 'org_admin', 'manager', 'biller', 'business_manager', 'location_manager', 'finance_manager']
    else array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'finance_manager'] end)
$function$;

CREATE OR REPLACE FUNCTION public.pos_day__today(p_loc uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ select (now() at time zone coalesce((select nullif(timezone, '') from public.locations where id = p_loc), 'Asia/Kolkata'))::date $function$;

CREATE OR REPLACE FUNCTION public.pos_day__window_end(p_day uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(d.closed_at, (select n.window_start from public.pos_business_days n where n.prev_day_id = d.id order by n.business_date limit 1), clock_timestamp())
  from public.pos_business_days d where d.id = p_day
$function$;

CREATE OR REPLACE FUNCTION public.pos_day_cash_totals(p_day uuid, p_until timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.pos_business_days%rowtype; v_to timestamptz; v_sales numeric; v_bills int; v_refunds numeric; v_in numeric := 0; v_out numeric := 0;
  v_exp numeric := 0; v_dep numeric := 0; m record; v_open numeric; v_noncash jsonb;
begin
  select * into d from public.pos_business_days where id = p_day;
  if not found then return null; end if;
  v_to := coalesce(p_until, public.pos_day__window_end(d.id));
  -- cash on counter bills only: an online / Zomato / Swiggy order's cash is the rider's (custody ledger), not the drawer's
  select coalesce(sum(y.amount), 0), count(distinct y.order_id) into v_sales, v_bills from public.payments y join public.orders o on o.id = y.order_id
   where o.organization_id = d.organization_id and o.location_id = d.location_id and y.method = 'cash'
     and o.channel not in ('online', 'swiggy', 'zomato') and coalesce(o.placed_by, 'pos') in ('pos', 'captain')
     and y.created_at >= d.window_start and y.created_at < v_to;
  -- the other ways money came in, for the summary only (never in the drawer's cash)
  select coalesce(jsonb_object_agg(t.method, t.amt), '{}'::jsonb) into v_noncash from (
    select y.method, sum(y.amount) amt from public.payments y join public.orders o on o.id = y.order_id
     where o.organization_id = d.organization_id and o.location_id = d.location_id and y.method not in ('cash', 'due')
       and y.created_at >= d.window_start and y.created_at < v_to group by y.method) t;
  select coalesce(sum(r.amount), 0) into v_refunds from public.pos_refunds r
   where r.organization_id = d.organization_id and r.location_id = d.location_id and r.method = 'cash' and r.created_at >= d.window_start and r.created_at < v_to;
  -- the drawer's pay-in / pay-out
  select coalesce(sum(amount) filter (where kind = 'in'), 0), coalesce(sum(amount) filter (where kind = 'out'), 0) into v_in, v_out
    from public.till_cash_moves where organization_id = d.organization_id and location_id = d.location_id and created_at >= d.window_start and created_at < v_to;
  -- the cash book's cash entries (a close's own "cash difference" true-up is not a movement)
  for m in select direction, kind, amount_minor from public.money_store_entries
            where organization_id = d.organization_id and location_id = d.location_id and account = 'cash' and status = 'posted' and kind <> 'cash_difference'
              and created_at >= d.window_start and created_at < v_to loop
    if m.direction = 'in' then v_in := v_in + m.amount_minor / 100.0;
    elsif m.kind = 'refund' then v_refunds := v_refunds + m.amount_minor / 100.0;
    elsif m.kind in ('expense', 'purchase', 'supplier_payment', 'salary') then v_exp := v_exp + m.amount_minor / 100.0;
    elsif m.kind in ('owner_out', 'transfer_out') then v_dep := v_dep + m.amount_minor / 100.0;
    else v_out := v_out + m.amount_minor / 100.0; end if;
  end loop;
  for m in select direction, amount_minor from public.money_cash_entries
            where organization_id = d.organization_id and location_id = d.location_id and status = 'posted' and created_at >= d.window_start and created_at < v_to loop
    if m.direction = 'in' then v_in := v_in + m.amount_minor / 100.0; else v_exp := v_exp + m.amount_minor / 100.0; end if;
  end loop;
  v_open := coalesce(d.opening_cash, 0);
  return jsonb_build_object('opening_cash', d.opening_cash, 'cash_sales', v_sales, 'bills', v_bills, 'other_cash_in', round(v_in, 2), 'cash_refunds', round(v_refunds, 2),
    'cash_expenses', round(v_exp, 2), 'deposits_withdrawals', round(v_dep, 2), 'other_cash_out', round(v_out, 2), 'other_methods', v_noncash,
    'expected_cash', round(v_open + v_sales + v_in - v_refunds - v_exp - v_dep - v_out, 2), 'from', d.window_start, 'until', v_to);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day__json(p_day uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_jsonb(d) - 'organization_id' - 'close_key'
    || jsonb_build_object(
      'location_name', l.name,
      'status_label', case d.status when 'started' then 'Started' when 'provisional' then 'Provisional' when 'attention' then 'Requires attention' else 'Closed' end,
      'cash', case when d.status = 'closed' then d.cash_totals else public.pos_day_cash_totals(d.id) end,
      'prev', (select jsonb_build_object('id', p.id, 'business_date', p.business_date, 'status', p.status, 'counted_cash', p.counted_cash) from public.pos_business_days p where p.id = d.prev_day_id),
      'adjustments', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'original_amount', a.original_amount, 'revised_amount', a.revised_amount,
                        'reason', a.reason, 'approval_status', a.approval_status, 'created_at', a.created_at,
                        'by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), 'Staff') from auth.users u where u.id = a.created_by)) order by a.created_at), '[]'::jsonb)
                      from public.pos_day_cash_adjustments a where a.day_id = d.id),
      'stock', jsonb_build_object(
        'opening_items', (select count(*) from public.pos_day_stock_snapshots s where s.day_id = d.id and s.kind = 'opening'),
        'opening_units', (select coalesce(sum(on_hand), 0) from public.pos_day_stock_snapshots s where s.day_id = d.id and s.kind = 'opening'),
        'closing_items', (select count(*) from public.pos_day_stock_snapshots s where s.day_id = d.id and s.kind = 'closing'),
        'moved_since_last_close', (select count(*) from public.pos_day_stock_snapshots o join public.pos_day_stock_snapshots c
                                     on c.day_id = d.prev_day_id and c.kind = 'closing' and c.inventory_item_id = o.inventory_item_id
                                    where o.day_id = d.id and o.kind = 'opening' and o.on_hand <> c.on_hand)))
  from public.pos_business_days d join public.locations l on l.id = d.location_id where d.id = p_day
$function$;

CREATE OR REPLACE FUNCTION public.pos_day__start(p_org uuid, p_loc uuid, p_trigger text, p_by uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_date date := public.pos_day__today(p_loc); v_id uuid; p public.pos_business_days%rowtype; v_status text; v_reason text; v_open numeric; v_src text;
  v_window timestamptz := clock_timestamp();
begin
  select id into v_id from public.pos_business_days where location_id = p_loc and business_date = v_date;
  if found then return v_id; end if;
  perform pg_advisory_xact_lock(hashtext('pos_day:' || p_loc));
  select id into v_id from public.pos_business_days where location_id = p_loc and business_date = v_date; -- a second trigger waited for the first
  if found then return v_id; end if;
  select * into p from public.pos_business_days where location_id = p_loc and business_date < v_date order by business_date desc limit 1;
  if not found then
    v_status := 'attention'; v_reason := 'no_previous_closing'; -- the first day: someone enters the cash in the drawer
  elsif p.status = 'closed' then
    v_status := 'started'; v_open := p.counted_cash; v_src := 'carried'; v_window := p.closed_at;
  else
    v_status := 'attention'; v_reason := 'previous_not_closed';
    update public.pos_business_days set status = 'attention', attention_reason = 'not_closed', version = version + 1 where id = p.id and status <> 'closed';
  end if;
  insert into public.pos_business_days (organization_id, location_id, business_date, status, attention_reason, start_trigger, started_by, window_start, prev_day_id,
                                        carried_cash, opening_cash, opening_cash_source)
  values (p_org, p_loc, v_date, v_status, v_reason, p_trigger, p_by, v_window, p.id, case when p.status = 'closed' then p.counted_cash end, v_open, v_src)
  on conflict (location_id, business_date) do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.pos_business_days where location_id = p_loc and business_date = v_date; return v_id; end if;
  if v_src = 'carried' then
    insert into public.pos_day_cash_adjustments (organization_id, day_id, kind, original_amount, revised_amount, reason, created_by)
    values (p_org, v_id, 'opening_carried', null, v_open, 'Carried from ' || to_char(p.business_date, 'DD Mon YYYY') || '''s counted closing cash', p_by);
  end if;
  insert into public.pos_day_stock_snapshots (day_id, kind, inventory_item_id, on_hand)
  select v_id, 'opening', b.inventory_item_id, sum(b.on_hand) from public.inventory_balances b
   where b.organization_id = p_org and b.location_id = p_loc group by b.inventory_item_id
  on conflict do nothing;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_auto_start()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l record; v_n int := 0;
begin
  for l in select loc.id, loc.organization_id from public.locations loc
            left join public.org_listing_profiles lp on lp.organization_id = loc.organization_id
           where loc.status = 'active'
             -- only stores that use the POS (a cash shift or a counter bill), not every location ever made
             and (exists (select 1 from public.till_shifts t where t.location_id = loc.id) or exists (select 1 from public.orders o where o.location_id = loc.id and o.placed_by = 'pos'))
             and (now() at time zone coalesce(nullif(loc.timezone, ''), 'Asia/Kolkata'))::time >= coalesce(lp.opens_at, time '00:00')
             and not exists (select 1 from public.pos_business_days d where d.location_id = loc.id and d.business_date = public.pos_day__today(loc.id)) loop
    perform public.pos_day__start(l.organization_id, l.id, 'opening_time', null);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('started', v_n);
end $function$;

-- ---------------------------------------------------------------------------------------------------------------- business day: the app's calls
CREATE OR REPLACE FUNCTION public.pos_day_today(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := public.pos_till_location(nullif(p->>'location_id', '')::uuid); v_id uuid;
  v_trigger text := case when p->>'trigger' = 'manual' then 'manual' else 'first_activity' end;
begin
  if not public.pos_day__can('read') then raise exception 'POS_FORBIDDEN: your role cannot see the business day'; end if;
  if coalesce((p->>'start')::boolean, true) and public.pos_day__can('count') then
    v_id := public.pos_day__start(v_org, v_loc, v_trigger, auth.uid());
  else
    select id into v_id from public.pos_business_days where location_id = v_loc and business_date = public.pos_day__today(v_loc);
  end if;
  return jsonb_build_object('location_id', v_loc, 'business_date', public.pos_day__today(v_loc),
    'day', case when v_id is null then null else public.pos_day__json(v_id) end,
    'can_manage', public.pos_day__can('manage'), 'can_count', public.pos_day__can('count'),
    'opens_at', (select opens_at from public.org_listing_profiles where organization_id = v_org));
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_opening_set(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); d public.pos_business_days%rowtype;
  v_amount numeric; v_reason text := nullif(btrim(coalesce(p->>'reason', '')), ''); v_kind text; v_mgr boolean := public.pos_day__can('manage'); a public.pos_day_cash_adjustments%rowtype;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  select * into a from public.pos_day_cash_adjustments where organization_id = v_org and idempotency_key = v_key;
  if found then return public.pos_day__json(a.day_id) || jsonb_build_object('replayed', true); end if;
  select * into d from public.pos_business_days where id = nullif(p->>'day_id', '')::uuid for update;
  if not found or auth.uid() is null or d.organization_id is distinct from v_org or not public.location_is_allowed(d.organization_id, d.location_id) then
    raise exception 'POS_NOT_FOUND: day not found'; end if;
  if not public.pos_day__can('count') then raise exception 'POS_FORBIDDEN: your role cannot change the opening cash'; end if;
  if d.status = 'closed' then raise exception 'POS_WRONG_STATE: this day is closed; its opening cash cannot change'; end if;
  if (p->>'expected_version') is not null and (p->>'expected_version')::int <> d.version then raise exception 'POS_STALE: this day was changed on another device'; end if;
  begin v_amount := (p->>'amount')::numeric; exception when others then v_amount := null; end;
  if v_amount is null or v_amount < 0 or v_amount >= 10000000 or v_amount <> round(v_amount, 2) then raise exception 'POS_BAD_REQUEST: enter the opening cash (0 or more)'; end if;
  if v_reason is null or char_length(v_reason) not between 3 and 200 then raise exception 'POS_REASON_REQUIRED: give a reason (3 to 200 characters)'; end if;
  v_kind := case when d.attention_reason = 'previous_not_closed' and d.opening_cash is null then 'provisional_opening'
                 when d.opening_cash is null then 'opening_initial' else 'opening_correction' end;
  if v_kind = 'provisional_opening' and not v_mgr then raise exception 'POS_FORBIDDEN: only a manager can open a day while the day before is not closed'; end if;
  insert into public.pos_day_cash_adjustments (organization_id, day_id, kind, original_amount, revised_amount, reason, approval_status, created_by, decided_by, decided_at, idempotency_key)
  values (v_org, d.id, v_kind, d.opening_cash, v_amount, v_reason, case when v_mgr then 'approved' else 'pending' end, auth.uid(),
          case when v_mgr then auth.uid() end, case when v_mgr then now() end, v_key);
  if v_mgr then
    update public.pos_business_days set opening_cash = v_amount,
      opening_cash_source = case v_kind when 'provisional_opening' then 'provisional' when 'opening_initial' then 'entered' else coalesce(opening_cash_source, 'entered') end,
      status = case when v_kind = 'provisional_opening' then 'provisional' when status = 'attention' and attention_reason = 'no_previous_closing' then 'started' else status end,
      attention_reason = case when v_kind = 'provisional_opening' or (status = 'attention' and attention_reason = 'no_previous_closing') then null else attention_reason end,
      version = version + 1
    where id = d.id;
  end if;
  return public.pos_day__json(d.id) || jsonb_build_object('replayed', false, 'pending', not v_mgr);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_adjustment_decide(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.pos_day_cash_adjustments%rowtype; d public.pos_business_days%rowtype; v_ok boolean := (p->>'decision') = 'approve'; v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
begin
  select * into a from public.pos_day_cash_adjustments where id = nullif(p->>'adjustment_id', '')::uuid for update;
  if not found or a.organization_id is distinct from public.current_org_id() then raise exception 'POS_NOT_FOUND: change not found'; end if;
  select * into d from public.pos_business_days where id = a.day_id for update;
  if not public.location_is_allowed(d.organization_id, d.location_id) then raise exception 'POS_NOT_FOUND: change not found'; end if;
  if a.approval_status <> 'pending' then
    if a.decided_by = auth.uid() and a.approval_status = (case when v_ok then 'approved' else 'rejected' end) then return public.pos_day__json(d.id) || jsonb_build_object('replayed', true); end if;
    raise exception 'POS_WRONG_STATE: this change was already decided';
  end if;
  if not public.pos_day__can('manage') then raise exception 'POS_FORBIDDEN: only a manager can approve an opening-cash change'; end if;
  if (p->>'decision') not in ('approve', 'reject') then raise exception 'POS_BAD_REQUEST: approve or reject'; end if;
  if d.status = 'closed' and v_ok then raise exception 'POS_WRONG_STATE: this day is closed'; end if;
  update public.pos_day_cash_adjustments set approval_status = case when v_ok then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = v_note where id = a.id;
  if v_ok then
    update public.pos_business_days set opening_cash = a.revised_amount,
      opening_cash_source = case when a.kind = 'opening_initial' then 'entered' else coalesce(opening_cash_source, 'entered') end,
      status = case when status = 'attention' and attention_reason = 'no_previous_closing' then 'started' else status end,
      attention_reason = case when status = 'attention' and attention_reason = 'no_previous_closing' then null else attention_reason end,
      version = version + 1 where id = d.id;
  end if;
  return public.pos_day__json(d.id) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_cash_count(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); d public.pos_business_days%rowtype; a public.pos_day_cash_adjustments%rowtype;
  v_counted numeric; v_reason text := nullif(btrim(coalesce(p->>'reason', '')), ''); v_tot jsonb; v_exp numeric; v_var numeric;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  select * into a from public.pos_day_cash_adjustments where organization_id = v_org and idempotency_key = v_key;
  if found then return public.pos_day__json(a.day_id) || jsonb_build_object('replayed', true); end if;
  select * into d from public.pos_business_days where id = nullif(p->>'day_id', '')::uuid for update;
  if not found or auth.uid() is null or d.organization_id is distinct from v_org or not public.location_is_allowed(d.organization_id, d.location_id) then
    raise exception 'POS_NOT_FOUND: day not found'; end if;
  if not public.pos_day__can('count') then raise exception 'POS_FORBIDDEN: your role cannot count the cash'; end if;
  if d.status = 'closed' then raise exception 'POS_WRONG_STATE: this day is already closed'; end if;
  if d.opening_cash is null then raise exception 'POS_NO_OPENING: enter the opening cash first'; end if;
  begin v_counted := (p->>'counted_cash')::numeric; exception when others then v_counted := null; end;
  if v_counted is null or v_counted < 0 or v_counted >= 10000000 or v_counted <> round(v_counted, 2) then raise exception 'POS_BAD_REQUEST: enter the cash counted in the drawer'; end if;
  v_tot := public.pos_day_cash_totals(d.id); v_exp := (v_tot->>'expected_cash')::numeric; v_var := v_counted - v_exp;
  if v_var <> 0 and (v_reason is null or char_length(v_reason) not between 3 and 200) then
    raise exception 'POS_REASON_REQUIRED: the count is % from what is expected; give a reason (3 to 200 characters)', v_var; end if;
  insert into public.pos_day_cash_adjustments (organization_id, day_id, kind, original_amount, revised_amount, reason, created_by, idempotency_key)
  values (v_org, d.id, 'closing_count', d.counted_cash, v_counted, case when v_var = 0 then null else v_reason end, auth.uid(), v_key);
  update public.pos_business_days set expected_cash = v_exp, counted_cash = v_counted, variance = v_var, variance_reason = case when v_var = 0 then null else v_reason end,
    cash_totals = v_tot, counted_by = auth.uid(), counted_at = clock_timestamp(), version = version + 1 where id = d.id;
  return public.pos_day__json(d.id) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_close(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); d public.pos_business_days%rowtype;
  v_note text := nullif(btrim(coalesce(p->>'note', '')), ''); v_at timestamptz; v_tot jsonb; v_exp numeric; v_var numeric; v_next uuid;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  select * into d from public.pos_business_days where id = nullif(p->>'day_id', '')::uuid for update;
  if not found or auth.uid() is null or d.organization_id is distinct from v_org or not public.location_is_allowed(d.organization_id, d.location_id) then
    raise exception 'POS_NOT_FOUND: day not found'; end if;
  if d.status = 'closed' then
    if d.close_key = v_key then return public.pos_day__json(d.id) || jsonb_build_object('replayed', true); end if;
    raise exception 'POS_WRONG_STATE: this day is already closed';
  end if;
  if not public.pos_day__can('manage') then raise exception 'POS_FORBIDDEN: only a manager can close the day'; end if;
  if (p->>'expected_version') is not null and (p->>'expected_version')::int <> d.version then raise exception 'POS_STALE: this day was changed on another device'; end if;
  if d.opening_cash is null then raise exception 'POS_NO_OPENING: enter the opening cash first'; end if;
  if d.counted_cash is null then raise exception 'POS_NO_COUNT: count the cash in the drawer first (Closing cash)'; end if;
  if exists (select 1 from public.pos_day_cash_adjustments where day_id = d.id and approval_status = 'pending') then
    raise exception 'POS_PENDING_CHANGE: an opening-cash change is waiting for approval; approve or reject it first'; end if;
  -- a day that was left open closes at the moment the next day started, so the next day's cash is not counted here too
  select n.window_start into v_at from public.pos_business_days n where n.prev_day_id = d.id order by n.business_date limit 1;
  v_at := coalesce(v_at, clock_timestamp());
  v_tot := public.pos_day_cash_totals(d.id, v_at); v_exp := (v_tot->>'expected_cash')::numeric; v_var := d.counted_cash - v_exp;
  if v_var <> 0 and coalesce(d.variance_reason, v_note) is null then
    raise exception 'POS_REASON_REQUIRED: the count is % from what is expected; give a reason', v_var; end if;
  update public.pos_business_days set status = 'closed', attention_reason = null, expected_cash = v_exp, variance = v_var,
    variance_reason = case when v_var = 0 then null else coalesce(d.variance_reason, v_note) end, cash_totals = v_tot,
    close_key = v_key, closed_by = auth.uid(), closed_at = v_at, close_note = v_note, version = version + 1 where id = d.id;
  insert into public.pos_day_stock_snapshots (day_id, kind, inventory_item_id, on_hand)
  select d.id, 'closing', b.inventory_item_id, sum(b.on_hand) from public.inventory_balances b
   where b.organization_id = d.organization_id and b.location_id = d.location_id group by b.inventory_item_id
  on conflict do nothing;
  -- the next day was waiting on this one: it may now carry the counted cash (a provisional opening stays provisional, with its reason)
  select id into v_next from public.pos_business_days where prev_day_id = d.id and status = 'attention' and attention_reason = 'previous_not_closed' and opening_cash is null;
  if v_next is not null then
    update public.pos_business_days set status = 'started', attention_reason = null, carried_cash = d.counted_cash, opening_cash = d.counted_cash,
      opening_cash_source = 'carried', version = version + 1 where id = v_next;
    insert into public.pos_day_cash_adjustments (organization_id, day_id, kind, original_amount, revised_amount, reason, created_by)
    values (d.organization_id, v_next, 'opening_carried', null, d.counted_cash, 'Carried from ' || to_char(d.business_date, 'DD Mon YYYY') || '''s counted closing cash (closed later)', auth.uid());
  end if;
  return public.pos_day__json(d.id) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_get(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.pos_business_days%rowtype;
begin
  select * into d from public.pos_business_days where id = nullif(p->>'day_id', '')::uuid;
  if not found or d.organization_id is distinct from public.current_org_id() or not public.location_is_allowed(d.organization_id, d.location_id) or not public.pos_day__can('read') then
    raise exception 'POS_NOT_FOUND: day not found'; end if;
  return public.pos_day__json(d.id);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.pos_till_location(nullif(p->>'location_id', '')::uuid); v_limit int := least(greatest(coalesce(nullif(p->>'limit', '')::int, 30), 1), 100);
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.pos_day__can('read') then raise exception 'POS_FORBIDDEN: your role cannot see the business days'; end if;
  return (select coalesce(jsonb_agg(public.pos_day__json(d.id) order by d.business_date desc), '[]'::jsonb)
            from (select id, business_date from public.pos_business_days where location_id = v_loc
                    and (nullif(p->>'before', '') is null or business_date < (p->>'before')::date) order by business_date desc limit v_limit) d);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_day_stock(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.pos_business_days%rowtype; v_kind text := coalesce(nullif(p->>'kind', ''), 'opening'); v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
begin
  select * into d from public.pos_business_days where id = nullif(p->>'day_id', '')::uuid;
  if not found or d.organization_id is distinct from public.current_org_id() or not public.location_is_allowed(d.organization_id, d.location_id) or not public.pos_day__can('read') then
    raise exception 'POS_NOT_FOUND: day not found'; end if;
  if v_kind not in ('opening', 'closing') then raise exception 'POS_BAD_REQUEST: opening or closing'; end if;
  return jsonb_build_object('day_id', d.id, 'kind', v_kind, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('inventory_item_id', i.id, 'name', i.name, 'sku', i.sku, 'unit', i.unit, 'on_hand', s.on_hand,
             'previous_closing', c.on_hand, 'moved', case when c.on_hand is null then null else s.on_hand - c.on_hand end) order by i.name)
      from public.pos_day_stock_snapshots s join public.inventory_items i on i.id = s.inventory_item_id
      left join public.pos_day_stock_snapshots c on v_kind = 'opening' and c.day_id = d.prev_day_id and c.kind = 'closing' and c.inventory_item_id = s.inventory_item_id
     where s.day_id = d.id and s.kind = v_kind and (v_q is null or i.name ilike '%' || v_q || '%' or i.sku ilike '%' || v_q || '%')), '[]'::jsonb));
end $function$;

-- ---------------------------------------------------------------------------------------------------------------- grants (as on hosted)
-- the app's calls: signed-in staff (the functions check the business, outlet and role)
revoke all on function public.acct_delete_cancel() from public, anon;
revoke all on function public.acct_delete_preview() from public, anon;
revoke all on function public.acct_delete_request(jsonb) from public, anon;
grant execute on function public.acct_delete_cancel(), public.acct_delete_preview(), public.acct_delete_request(jsonb) to authenticated, service_role;
revoke all on function public.pos_day_today(jsonb), public.pos_day_opening_set(jsonb), public.pos_day_adjustment_decide(jsonb), public.pos_day_cash_count(jsonb),
  public.pos_day_close(jsonb), public.pos_day_list(jsonb), public.pos_day_get(jsonb), public.pos_day_stock(jsonb) from public, anon;
grant execute on function public.pos_day_today(jsonb), public.pos_day_opening_set(jsonb), public.pos_day_adjustment_decide(jsonb), public.pos_day_cash_count(jsonb),
  public.pos_day_close(jsonb), public.pos_day_list(jsonb), public.pos_day_get(jsonb), public.pos_day_stock(jsonb) to authenticated, service_role;
-- the scheduled jobs' functions: only the database itself
revoke all on function public.acct_deletion_purge(), public.pos_day_auto_start(), public.pos_day__start(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.acct_deletion_purge(), public.pos_day_auto_start(), public.pos_day__start(uuid, uuid, text, uuid) to service_role;
-- the internal helpers (changed from hosted, also hosted piece 36): only the functions above call them, never the app
revoke all on function public.pos_day__can(text), public.pos_day__json(uuid), public.pos_day__today(uuid), public.pos_day__window_end(uuid),
  public.pos_day_cash_totals(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.pos_day__can(text), public.pos_day__json(uuid), public.pos_day__today(uuid), public.pos_day__window_end(uuid),
  public.pos_day_cash_totals(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------------------------- scheduled jobs (as on hosted)
-- where pg_cron is installed and the jobs are not there yet; hosted already has both
do $j$ begin
  if to_regclass('cron.job') is not null then
    if not exists (select 1 from cron.job where jobname = 'acct_deletion_purge') then
      perform cron.schedule('acct_deletion_purge', '40 3 * * *', 'select public.acct_deletion_purge()');
    end if;
    if not exists (select 1 from cron.job where jobname = 'pos_day_auto_start') then
      perform cron.schedule('pos_day_auto_start', '*/10 * * * *', 'select public.pos_day_auto_start()');
    end if;
  end if;
end $j$;

notify pgrst, 'reload schema';
