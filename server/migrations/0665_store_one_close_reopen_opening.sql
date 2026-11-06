-- 0665 (5 Nov 2026): the store POS closes its day in one place. STORE ONLY: the smoney_* functions and money_store_* tables are the store's,
-- and the guard below acts only where a money_store_day_close row exists. A restaurant never has one. The Service POS shares smoney_register and
-- smoney_close_day, so a service business is skipped by the guard and keeps its old register arithmetic.
--   * Money's Close day is the official close. A closed day stays closed: a sale, refund or cash entry at the counter is refused (POS_DAY_ENDED)
--     until someone with money:approve reopens the day, so a late sale is added to that day's end and counted at its next Close day.
--     Online orders are never refused: the customer has already paid.
--   * smoney_reopen_day: reopens with a reason; the count's difference is voided and the old close is kept in money_store_day_reopens.
--   * smoney_opening_count: the next day opens with the last counted cash. If the drawer holds something else, the exact amount is entered and the
--     difference is recorded as a shortage or an excess (kind cash_difference, shown apart from cash in and out, and in Reports).
--   * smoney_register also says who may reopen, the reopens, the opening count and the bills still open.
--   * inv__sole_approver: on a store with nobody else who may approve stock changes, the one person may approve their own adjustment.
-- Safe to run again.

create table if not exists public.money_store_day_reopens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  expected_minor bigint not null,
  counted_minor bigint not null,
  closed_by uuid,
  closed_at timestamptz not null,
  reason text not null check (char_length(reason) between 3 and 200),
  reopened_by uuid,
  reopened_at timestamptz not null default now()
);
create index if not exists money_store_day_reopens_org_day on public.money_store_day_reopens (organization_id, location_id, day);
alter table public.money_store_day_reopens enable row level security;
revoke all on public.money_store_day_reopens from anon, authenticated;

create table if not exists public.money_store_day_opening (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  carried_minor bigint not null,
  counted_minor bigint not null,
  counted_by uuid,
  counted_at timestamptz not null default now(),
  primary key (organization_id, location_id, day)
);
alter table public.money_store_day_opening enable row level security;
revoke all on public.money_store_day_opening from anon, authenticated;

-- ------------------------------------------------------------------- a closed day stays closed
create or replace function public.money_store__day_guard() returns trigger
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_org uuid := new.organization_id; v_loc uuid; v_day date := (now() at time zone public.money_tz())::date; o public.orders%rowtype;
begin
  if lower(coalesce((select business_domain from public.organizations where id = v_org), '')) ~ 'service' then return new; end if;
  if tg_table_name = 'money_store_entries' then
    if new.account <> 'cash' or new.kind = 'cash_difference' then return new; end if;
    if tg_op = 'UPDATE' and not (old.status = 'posted' and new.status <> 'posted') then return new; end if;
    v_loc := new.location_id; v_day := new.entry_date;
  else
    select * into o from public.orders where id = new.order_id;
    -- an online order was paid by the customer: it is never turned away
    if not found or o.channel = 'online' or o.placed_by = 'integration' then return new; end if;
    v_loc := o.location_id;
  end if;
  if exists (select 1 from public.money_store_day_close c where c.organization_id = v_org and c.location_id = v_loc and c.day = v_day) then
    raise exception 'POS_DAY_ENDED: this day is closed. Reopen it in Money, and this is added to the day end.';
  end if;
  return new;
end $f$;
revoke all on function public.money_store__day_guard() from public, anon, authenticated;

drop trigger if exists money_store_day_guard on public.payments;
create trigger money_store_day_guard before insert on public.payments for each row execute function public.money_store__day_guard();
drop trigger if exists money_store_day_guard on public.pos_refunds;
create trigger money_store_day_guard before insert on public.pos_refunds for each row execute function public.money_store__day_guard();
drop trigger if exists money_store_day_guard on public.money_store_entries;
create trigger money_store_day_guard before insert or update on public.money_store_entries for each row execute function public.money_store__day_guard();

-- ------------------------------------------------------------------- the cash register
CREATE OR REPLACE FUNCTION public.smoney_register(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_today date := (now() at time zone public.money_tz())::date;
  v_day date; v_open bigint; d record; c public.money_store_day_close%rowtype; o public.money_store_day_opening%rowtype; v_open_diff bigint; v_bills jsonb;
  v_service boolean := lower(coalesce((select business_domain from public.organizations where id = v_org), '')) ~ 'service';
begin
  begin v_day := coalesce(nullif(p->>'day', '')::date, v_today); exception when others then raise exception 'MONEY_BAD_REQUEST: the date must look like 2026-10-17'; end;
  -- the opening is what the last day ended with: every close and opening difference before today is already in it
  select coalesce(sum(case direction when 'in' then amount else -amount end), 0) into v_open from public.smoney_moves(v_org, v_locs, date '2000-01-01', v_day - 1) where account = 'cash';
  select coalesce(sum(amount) filter (where direction = 'in' and kind = 'sales'), 0) sales,
         coalesce(sum(amount) filter (where direction = 'in' and kind <> 'sales' and (v_service or kind <> 'cash_difference')), 0) cash_in,
         coalesce(sum(amount) filter (where direction = 'out' and kind = 'refund'), 0) refunds,
         coalesce(sum(amount) filter (where direction = 'out' and kind <> 'refund' and (v_service or kind <> 'cash_difference')), 0) cash_out
    into d from public.smoney_moves(v_org, v_locs, v_day, v_day) where account = 'cash';
  -- a difference found at the opening changes what should be in the drawer; the close's own difference is shown as the count
  select coalesce(sum(case s.direction when 'in' then s.amount_minor else -s.amount_minor end), 0) into v_open_diff from public.money_store_entries s
   where s.organization_id = v_org and s.location_id = any (v_locs) and s.status = 'posted' and s.kind = 'cash_difference' and s.entry_date = v_day and s.idempotency_key like 'open:%' and not v_service;
  select * into c from public.money_store_day_close where organization_id = v_org and location_id = v_locs[1] and day = v_day;
  select * into o from public.money_store_day_opening where organization_id = v_org and location_id = v_locs[1] and day = v_day;
  select jsonb_build_object('count', count(*), 'due_minor', coalesce(sum(round(b.total * 100)), 0)::bigint) into v_bills from public.orders b
   where b.organization_id = v_org and b.location_id = any (v_locs) and b.paid_at is null and b.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready', 'awaiting_payment');
  return jsonb_build_object('day', v_day, 'opening_minor', v_open, 'sales_minor', d.sales, 'cash_in_minor', d.cash_in, 'refunds_minor', d.refunds, 'cash_out_minor', d.cash_out,
    'expected_minor', v_open + v_open_diff + d.sales + d.cash_in - d.refunds - d.cash_out,
    'opening_count', case when o.day is null then null else jsonb_build_object('counted_minor', o.counted_minor, 'difference_minor', o.counted_minor - o.carried_minor,
      'by', public.money_person(v_org, o.counted_by), 'at', o.counted_at) end,
    'can_count_opening', v_day = v_today and c.day is null and o.day is null and public.has_permission(v_org, 'money', 'record', null),
    'open_bills', v_bills,
    'can_reopen', c.day is not null and public.has_permission(v_org, 'money', 'approve', null),
    'reopens', (select coalesce(jsonb_agg(jsonb_build_object('at', x.reopened_at, 'by', public.money_person(v_org, x.reopened_by), 'reason', x.reason, 'counted_minor', x.counted_minor) order by x.reopened_at), '[]'::jsonb)
                  from public.money_store_day_reopens x where x.organization_id = v_org and x.location_id = v_locs[1] and x.day = v_day),
    'closed', case when c.day is null then null else jsonb_build_object('counted_minor', c.counted_minor, 'expected_minor', c.expected_minor,
      'difference_minor', c.counted_minor - c.expected_minor, 'by', public.money_person(v_org, c.closed_by), 'at', c.closed_at) end);
end $function$;

CREATE OR REPLACE FUNCTION public.smoney_close_day(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'record'); v_loc uuid := public.money_write_location(v_org, p, 'record'); v_day date := public.money_day(p, 'day');
  v_counted bigint; r jsonb; v_exp bigint; v_diff bigint;
begin
  if (p->>'counted_minor') !~ '^[0-9]{1,11}$' then raise exception 'MONEY_BAD_REQUEST: enter the cash you counted'; end if;
  v_counted := (p->>'counted_minor')::bigint;
  if exists (select 1 from public.money_store_day_close where organization_id = v_org and location_id = v_loc and day = v_day) then
    raise exception 'MONEY_DUPLICATE: this day is already closed'; end if;
  r := public.smoney_register(jsonb_build_object('day', v_day, 'location_id', v_loc));
  v_exp := (r->>'expected_minor')::bigint; v_diff := v_counted - v_exp;
  insert into public.money_store_day_close (organization_id, location_id, day, expected_minor, counted_minor, closed_by) values (v_org, v_loc, v_day, v_exp, v_counted, auth.uid());
  if v_diff <> 0 then
    insert into public.money_store_entries (organization_id, location_id, entry_no, entry_date, account, direction, kind, amount_minor, note, created_by, idempotency_key)
    values (v_org, v_loc, 'TXN-' || lpad(public.next_org_seq(v_org, 'money_store')::text, 4, '0'), v_day, 'cash', case when v_diff > 0 then 'in' else 'out' end,
            'cash_difference', abs(v_diff), case when v_diff > 0 then 'Extra cash found at close' else 'Cash short at close' end, auth.uid(), 'close:' || v_loc || ':' || v_day || ':' || extract(epoch from clock_timestamp())::bigint);
  end if;
  return public.smoney_register(jsonb_build_object('day', v_day, 'location_id', v_loc));
end $function$;

-- ------------------------------------------------------------------- reopen a closed day
create or replace function public.smoney_reopen_day(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_org uuid := public.money_require('money', 'approve'); v_loc uuid := public.money_write_location(v_org, p, 'approve'); v_day date := public.money_day(p, 'day');
  v_reason text := nullif(btrim(coalesce(p->>'reason', '')), ''); c public.money_store_day_close%rowtype;
begin
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'MONEY_REASON_REQUIRED: write why the day is reopened'; end if;
  if char_length(v_reason) > 200 then raise exception 'MONEY_BAD_REQUEST: keep the reason under 200 characters'; end if;
  select * into c from public.money_store_day_close where organization_id = v_org and location_id = v_loc and day = v_day for update;
  if not found then raise exception 'MONEY_BAD_REQUEST: this day is not closed'; end if;
  insert into public.money_store_day_reopens (organization_id, location_id, day, expected_minor, counted_minor, closed_by, closed_at, reason, reopened_by)
  values (v_org, v_loc, v_day, c.expected_minor, c.counted_minor, c.closed_by, c.closed_at, v_reason, auth.uid());
  delete from public.money_store_day_close where organization_id = v_org and location_id = v_loc and day = v_day;
  -- the count's extra or short cash no longer stands: the day is counted again at its next Close day
  update public.money_store_entries set status = 'void', void_reason = left('Day reopened: ' || v_reason, 200), voided_by = auth.uid(), voided_at = now()
   where organization_id = v_org and location_id = v_loc and kind = 'cash_difference' and entry_date = v_day and status = 'posted' and idempotency_key like 'close:%';
  return public.smoney_register(jsonb_build_object('day', v_day, 'location_id', v_loc));
end $f$;
revoke all on function public.smoney_reopen_day(jsonb) from public, anon;
grant execute on function public.smoney_reopen_day(jsonb) to authenticated, service_role;

-- ------------------------------------------------------------------- the opening count
create or replace function public.smoney_opening_count(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_org uuid := public.money_require('money', 'record'); v_loc uuid := public.money_write_location(v_org, p, 'record'); v_day date := (now() at time zone public.money_tz())::date;
  v_counted bigint; v_carried bigint; v_diff bigint;
begin
  if (p->>'counted_minor') !~ '^[0-9]{1,11}$' then raise exception 'MONEY_BAD_REQUEST: enter the cash you found in the drawer'; end if;
  v_counted := (p->>'counted_minor')::bigint;
  if exists (select 1 from public.money_store_day_close where organization_id = v_org and location_id = v_loc and day = v_day) then
    raise exception 'POS_DAY_ENDED: this day is closed. Reopen it in Money first.'; end if;
  if exists (select 1 from public.money_store_day_opening where organization_id = v_org and location_id = v_loc and day = v_day) then
    raise exception 'MONEY_DUPLICATE: the opening cash is already counted today'; end if;
  v_carried := (public.smoney_register(jsonb_build_object('day', v_day, 'location_id', v_loc))->>'opening_minor')::bigint;
  v_diff := v_counted - v_carried;
  insert into public.money_store_day_opening (organization_id, location_id, day, carried_minor, counted_minor, counted_by) values (v_org, v_loc, v_day, v_carried, v_counted, auth.uid());
  if v_diff <> 0 then
    insert into public.money_store_entries (organization_id, location_id, entry_no, entry_date, account, direction, kind, amount_minor, note, created_by, idempotency_key)
    values (v_org, v_loc, 'TXN-' || lpad(public.next_org_seq(v_org, 'money_store')::text, 4, '0'), v_day, 'cash', case when v_diff > 0 then 'in' else 'out' end,
            'cash_difference', abs(v_diff), case when v_diff > 0 then 'Extra cash found at opening' else 'Cash short at opening' end, auth.uid(), 'open:' || v_loc || ':' || v_day);
  end if;
  return public.smoney_register(jsonb_build_object('day', v_day, 'location_id', v_loc));
end $f$;
revoke all on function public.smoney_opening_count(jsonb) from public, anon;
grant execute on function public.smoney_opening_count(jsonb) to authenticated, service_role;

-- ------------------------------------------------------------------- shortage and excess, for Reports
create or replace function public.smoney_cash_differences(p jsonb) returns jsonb
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $f$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_out jsonb;
begin
  select jsonb_build_object('short_minor', coalesce(sum(s.amount_minor) filter (where s.direction = 'out'), 0), 'extra_minor', coalesce(sum(s.amount_minor) filter (where s.direction = 'in'), 0)) into v_out
    from public.money_store_entries s
   where s.organization_id = v_org and s.location_id = any (v_locs) and s.kind = 'cash_difference' and s.status = 'posted'
     and s.entry_date between (p->>'from')::date and (p->>'to')::date;
  return v_out;
end $f$;
revoke all on function public.smoney_cash_differences(jsonb) from public, anon;
grant execute on function public.smoney_cash_differences(jsonb) to authenticated, service_role;

-- ------------------------------------------------------------------- stock adjustments on a one-login store
create or replace function public.inv__sole_approver(p_org uuid, p_loc uuid) returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $f$
  select lower(coalesce((select business_domain from public.organizations where id = p_org), '')) !~ 'restaurant|food|service'
     and not exists (select 1 from public.org_users ou where ou.organization_id = p_org and ou.status = 'active' and ou.user_id is distinct from auth.uid()
                        and public.user_has_permission(ou.user_id, p_org, 'inventory', 'approve', p_loc));
$f$;
revoke all on function public.inv__sole_approver(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.inv_document_act(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); d public.inventory_documents%rowtype; l public.inventory_document_lines%rowtype; v_action text := p->>'action';
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_to text; v_from text; v_lot uuid; v_acc numeric; v_on numeric; v_cap numeric;
  v_qbin uuid; v_tob uuid; v_split jsonb; v_note text := nullif(btrim(coalesce(p->>'note', '')), ''); v_new jsonb; v_n_exp int;
begin
  if auth.uid() is null or v_org is null then raise exception 'INV_FORBIDDEN: sign in to a business first'; end if;
  select * into d from public.inventory_documents where id = nullif(p->>'id', '')::uuid for update;
  if not found or d.organization_id is distinct from v_org
     or not (public.location_is_allowed(v_org, d.location_id) or (d.to_location_id is not null and public.location_is_allowed(v_org, d.to_location_id))) then
    raise exception 'INV_NOT_FOUND: document not found'; end if;
  -- permission first: a role that may not act learns nothing about the document's state or version (re-review P3)
  -- who may act
  if v_action in ('approve', 'reject') then
    if not public.has_permission(v_org, 'inventory', 'approve', d.location_id) then raise exception 'INV_FORBIDDEN: only an approver can % a stock adjustment', v_action; end if;
    -- four eyes: whoever raised the adjustment cannot approve it (H-07); they can still send it back or cancel it
    if v_action = 'approve' and d.created_by = auth.uid() and not public.inv__sole_approver(v_org, d.location_id) then raise exception 'INV_FORBIDDEN: you cannot approve an adjustment you raised'; end if;
  elsif v_action = 'receive' then
    if not public.has_permission(v_org, 'inventory', 'record', d.to_location_id) then raise exception 'INV_FORBIDDEN: your role cannot receive stock here'; end if;
  elsif not public.has_permission(v_org, 'inventory', 'record', d.location_id) then
    raise exception 'INV_FORBIDDEN: your role cannot change stock';
  end if;
  if v_key is not null and char_length(v_key) > 100 then raise exception 'INV_BAD_REQUEST: the idempotency key is too long'; end if;
  if v_key is not null and exists (select 1 from public.inventory_document_events where document_id = d.id and idempotency_key = v_key) then
    if not exists (select 1 from public.inventory_document_events where document_id = d.id and idempotency_key = v_key and action = v_action) then
      raise exception 'INV_BAD_REQUEST: this key was used for another action'; end if;
    return public.inv_document_view(jsonb_build_object('id', d.id)) || jsonb_build_object('replayed', true);
  end if;
  if nullif(p->>'version', '') is null then raise exception 'INV_BAD_REQUEST: version is required'; end if;
  if (p->>'version')::int <> d.version then raise exception 'INV_STALE: someone changed % since you opened it', d.doc_no; end if;
  select t.to_status into v_to from public.inventory_document_transitions t where t.doc_type = d.doc_type and t.from_status = d.status and t.action = v_action;
  if v_to is null then
    if not exists (select 1 from public.inventory_document_transitions t where t.action = v_action) then raise exception 'INV_BAD_REQUEST: unknown action'; end if;
    raise exception 'INV_WRONG_STATE: % is % and cannot %', d.doc_no, replace(d.status, '_', ' '), v_action;
  end if;
  v_from := d.status;

  -- checks before the move
  if v_action in ('submit', 'post', 'dispatch', 'approve') and not exists (select 1 from public.inventory_document_lines where document_id = d.id) then
    raise exception 'INV_BAD_REQUEST: add at least one item first'; end if;
  if d.doc_type = 'adjustment' and v_action = 'submit' and d.reason = '' then raise exception 'INV_BAD_REQUEST: choose a reason first'; end if;
  if d.doc_type = 'adjustment' and v_action = 'reject' and v_note is null then raise exception 'INV_BAD_REQUEST: say why the adjustment is sent back'; end if;
  if d.doc_type = 'transfer' and v_action = 'post' and d.to_location_id is not null then raise exception 'INV_WRONG_STATE: dispatch an inter-facility transfer, then receive it there'; end if;
  if d.doc_type = 'transfer' and v_action = 'dispatch' and d.to_location_id is null then raise exception 'INV_WRONG_STATE: an internal transfer is posted, not dispatched'; end if;
  if d.doc_type = 'audit' and v_action = 'submit' and exists (select 1 from public.inventory_document_lines where document_id = d.id and counted_qty is null) then
    raise exception 'INV_BAD_REQUEST: count every item before review'; end if;
  if d.doc_type = 'receipt' and v_action in ('submit', 'post') then
    select xl.line_no into v_n_exp from public.inventory_document_lines xl
      left join public.inventory_lots xt on xt.id = xl.lot_id or (xl.lot_id is null and xt.inventory_item_id = xl.inventory_item_id and xt.lot_code = xl.lot_code)
     where xl.document_id = d.id and coalesce(xl.qty, 0) - xl.rejected_qty > 0 and least(xl.expiry_date, xt.expiry_date) < current_date order by xl.line_no limit 1;
    if found then raise exception 'INV_BAD_REQUEST: line % is already past its expiry date; reject those units instead of receiving them', v_n_exp; end if;
  end if;
  if d.doc_type = 'receipt' and v_action = 'post' and not exists (select 1 from public.inventory_document_lines where document_id = d.id and coalesce(qty, 0) - rejected_qty > 0) then
    raise exception 'INV_BAD_QTY: nothing accepted to post'; end if;

  perform set_config('inv.posting', d.id::text, true);
  -- the move itself
  if d.doc_type = 'receipt' and v_action = 'post' then
    for l in select * from public.inventory_document_lines where document_id = d.id order by line_no loop
      v_acc := coalesce(l.qty, 0) - l.rejected_qty;
      continue when v_acc <= 0;
      v_lot := l.lot_id;
      if v_lot is null and l.lot_code is not null then
        insert into public.inventory_lots (organization_id, inventory_item_id, lot_code, expiry_date) values (v_org, l.inventory_item_id, l.lot_code, l.expiry_date)
        on conflict (inventory_item_id, lot_code) do update set expiry_date = coalesce(inventory_lots.expiry_date, excluded.expiry_date)
        returning id into v_lot;
        update public.inventory_document_lines set lot_id = v_lot where id = l.id;
      end if;
      perform public.inv_post_movement(d, l, d.location_id, 'receipt', 1, coalesce(l.to_bin_id, public.inv_default_bin(v_org, d.location_id)),
        jsonb_build_array(jsonb_build_object('lot_id', v_lot, 'qty', v_acc)));
    end loop;
  elsif d.doc_type = 'adjustment' and v_action = 'approve' then
    for l in select * from public.inventory_document_lines where document_id = d.id order by line_no loop
      if l.adjust_type in ('decrease', 'quarantine', 'write_off') then
        v_on := public.inv_bin_on_hand(l.from_bin_id, l.inventory_item_id, l.lot_id);
        if v_on < l.qty then raise exception 'INV_SHORT: line % takes % but only % is there now', l.line_no, l.qty, v_on; end if;
      end if;
      case l.adjust_type
        when 'decrease' then perform public.inv_post_movement(d, l, d.location_id, 'adjustment', -1, l.from_bin_id, public.inv_split(l.from_bin_id, l.inventory_item_id, l.lot_id, l.qty));
        when 'increase' then perform public.inv_post_movement(d, l, d.location_id, 'adjustment', 1, coalesce(l.to_bin_id, public.inv_default_bin(v_org, d.location_id)),
                               jsonb_build_array(jsonb_build_object('lot_id', l.lot_id, 'qty', l.qty)));
        when 'quarantine' then
          v_qbin := coalesce(l.to_bin_id, public.inv_default_bin(v_org, d.location_id, 'quarantine'));
          v_split := public.inv_split(l.from_bin_id, l.inventory_item_id, l.lot_id, l.qty);
          perform public.inv_post_movement(d, l, d.location_id, 'transfer_out', -1, l.from_bin_id, v_split);
          perform public.inv_post_movement(d, l, d.location_id, 'transfer_in', 1, v_qbin, v_split);
        when 'write_off' then perform public.inv_post_movement(d, l, d.location_id, 'wastage', -1, l.from_bin_id, public.inv_split(l.from_bin_id, l.inventory_item_id, l.lot_id, l.qty));
      end case;
    end loop;
    update public.inventory_documents set approved_by = auth.uid() where id = d.id;
  elsif d.doc_type = 'transfer' and v_action in ('post', 'dispatch') then
    for l in select * from public.inventory_document_lines where document_id = d.id order by line_no loop
      v_on := public.inv_bin_on_hand(l.from_bin_id, l.inventory_item_id, l.lot_id);
      if v_on < l.qty then raise exception 'INV_SHORT: line % moves % but only % is in that place now', l.line_no, l.qty, v_on; end if;
      if v_action = 'post' then
        if (select storage from public.inventory_bins where id = l.from_bin_id) <> (select storage from public.inventory_bins where id = l.to_bin_id) then
          raise exception 'INV_STORAGE: line % moves stock between different storage types', l.line_no; end if;
        select capacity_units into v_cap from public.inventory_bins where id = l.to_bin_id;
        if v_cap is not null and (select coalesce(sum(on_hand), 0) from public.inventory_bin_balances where bin_id = l.to_bin_id) + l.qty > v_cap then
          raise exception 'INV_CAPACITY: line % does not fit the destination', l.line_no; end if;
        v_split := public.inv_split(l.from_bin_id, l.inventory_item_id, l.lot_id, l.qty);
        perform public.inv_post_movement(d, l, d.location_id, 'transfer_out', -1, l.from_bin_id, v_split);
        perform public.inv_post_movement(d, l, d.location_id, 'transfer_in', 1, l.to_bin_id, v_split);
      else
        perform public.inv_post_movement(d, l, d.location_id, 'transfer_out', -1, l.from_bin_id, public.inv_split(l.from_bin_id, l.inventory_item_id, l.lot_id, l.qty));
      end if;
    end loop;
  elsif d.doc_type = 'transfer' and v_action = 'receive' then
    for l in select * from public.inventory_document_lines where document_id = d.id order by line_no loop
      -- the units arrive as the lots they left with
      v_tob := coalesce(l.to_bin_id, public.inv_default_bin(v_org, d.to_location_id));
      select coalesce(jsonb_agg(jsonb_build_object('lot_id', a.lot_id, 'qty', -a.quantity)), '[]'::jsonb) into v_split
        from public.stock_movements m join public.stock_allocations a on a.movement_id = m.id
       where m.ref_type = 'inventory_document_lines' and m.ref_id = l.id::text and m.kind = 'transfer_out';
      perform public.inv_post_movement(d, l, d.to_location_id, 'transfer_in', 1, v_tob, v_split);
    end loop;
  end if;
  perform set_config('inv.posting', '', true);

  update public.inventory_documents set status = v_to, version = version + 1,
    submitted_by = case when v_action = 'submit' then auth.uid() else submitted_by end,
    submitted_at = case when v_action = 'submit' then now() else submitted_at end,
    posted_by = case when v_to in ('posted', 'completed') then auth.uid() else posted_by end,
    posted_at = case when v_to in ('posted', 'completed') then now() else posted_at end,
    cancelled_at = case when v_to = 'cancelled' then now() else cancelled_at end
  where id = d.id;
  insert into public.inventory_document_events (organization_id, document_id, action, from_status, to_status, actor, note, idempotency_key)
  values (v_org, d.id, v_action, v_from, v_to, auth.uid(), v_note, v_key);
  return public.inv_document_view(jsonb_build_object('id', d.id)) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.inv_document_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); d public.inventory_documents%rowtype; v_actions jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'INV_FORBIDDEN: sign in to a business first'; end if;
  select * into d from public.inventory_documents where id = nullif(p->>'id', '')::uuid;
  if not found or d.organization_id is distinct from v_org
     or not (public.location_is_allowed(v_org, d.location_id) or (d.to_location_id is not null and public.location_is_allowed(v_org, d.to_location_id))) then
    raise exception 'INV_NOT_FOUND: document not found'; end if;
  -- a transfer is also visible to staff bound only to its destination (H-05)
  if not public.has_permission(v_org, 'inventory', 'read', d.location_id) and not public.has_permission(v_org, 'inventory', 'record', d.location_id)
     and not (d.to_location_id is not null and (public.has_permission(v_org, 'inventory', 'read', d.to_location_id) or public.has_permission(v_org, 'inventory', 'record', d.to_location_id))) then
    raise exception 'INV_FORBIDDEN: your role cannot see stock'; end if;
  select coalesce(jsonb_agg(t.action order by t.action), '[]'::jsonb) into v_actions
    from public.inventory_document_transitions t
   where t.doc_type = d.doc_type and t.from_status = d.status
     and case when t.action = 'approve' then public.has_permission(v_org, 'inventory', 'approve', d.location_id) and (d.created_by is distinct from auth.uid() or public.inv__sole_approver(v_org, d.location_id))
              when t.action = 'reject' then public.has_permission(v_org, 'inventory', 'approve', d.location_id)
              when t.action = 'receive' then public.has_permission(v_org, 'inventory', 'record', d.to_location_id)
              else public.has_permission(v_org, 'inventory', 'record', d.location_id) end
     and not (d.doc_type = 'transfer' and t.action = 'post' and d.to_location_id is not null)
     and not (d.doc_type = 'transfer' and t.action = 'dispatch' and d.to_location_id is null);
  return jsonb_build_object(
    'id', d.id, 'doc_type', d.doc_type, 'doc_no', d.doc_no, 'status', d.status, 'title', d.title, 'reason', d.reason, 'note', d.note,
    'supplier_name', d.supplier_name, 'po_ref', d.po_ref, 'invoice_ref', d.invoice_ref, 'expected_at', d.expected_at, 'version', d.version,
    'location', (select jsonb_build_object('id', l.id, 'name', l.name, 'code', l.code) from public.locations l where l.id = d.location_id),
    'to_location', (select jsonb_build_object('id', l.id, 'name', l.name, 'code', l.code) from public.locations l where l.id = d.to_location_id),
    'linked', (select jsonb_build_object('id', x.id, 'doc_no', x.doc_no, 'doc_type', x.doc_type, 'status', x.status) from public.inventory_documents x where x.id = d.linked_document_id),
    'linked_from', (select jsonb_agg(jsonb_build_object('id', x.id, 'doc_no', x.doc_no, 'doc_type', x.doc_type, 'status', x.status) order by x.created_at)
                      from public.inventory_documents x where x.linked_document_id = d.id),
    'operator', public.inv_person(v_org, d.operator_id), 'created_by', public.inv_person(v_org, d.created_by),
    'submitted_by', public.inv_person(v_org, d.submitted_by), 'approved_by', public.inv_person(v_org, d.approved_by), 'posted_by', public.inv_person(v_org, d.posted_by),
    'created_at', d.created_at, 'submitted_at', d.submitted_at, 'posted_at', d.posted_at, 'cancelled_at', d.cancelled_at, 'updated_at', d.updated_at,
    'allowed_actions', v_actions,
    'can_draft_adjustment', d.doc_type = 'audit' and d.status in ('review', 'completed') and public.has_permission(v_org, 'inventory', 'record', d.location_id)
       and exists (select 1 from public.inventory_document_lines x where x.document_id = d.id and x.counted_qty is distinct from x.system_qty)
       and not exists (select 1 from public.inventory_documents x where x.linked_document_id = d.id and x.status <> 'cancelled'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'line_no', l.line_no,
        'item', jsonb_build_object('id', i.id, 'name', i.name, 'sku', i.sku, 'barcode', i.barcode, 'category', i.category, 'unit', i.unit, 'item_type', i.item_type),
        'lot', (select jsonb_build_object('id', lt.id, 'lot_code', lt.lot_code, 'expiry_date', lt.expiry_date) from public.inventory_lots lt where lt.id = l.lot_id),
        'lot_code', l.lot_code, 'expiry_date', l.expiry_date, 'adjust_type', l.adjust_type,
        'from_bin', public.inv_bin_json(l.from_bin_id, l.inventory_item_id, l.lot_id),
        'to_bin', public.inv_bin_json(l.to_bin_id, l.inventory_item_id, l.lot_id),
        'expected_qty', l.expected_qty, 'qty', l.qty, 'rejected_qty', l.rejected_qty, 'reject_reason', l.reject_reason,
        'accepted_qty', case when d.doc_type = 'receipt' then coalesce(l.qty, 0) - l.rejected_qty end,
        'system_qty', l.system_qty, 'counted_qty', l.counted_qty, 'variance', case when l.counted_qty is not null then l.counted_qty - l.system_qty end,
        'note', l.note,
        'position', (select jsonb_build_object('sellable', coalesce(sum(pp.sellable), 0), 'damaged', coalesce(sum(pp.damaged), 0),
                                               'reserved', coalesce(sum(pp.reserved), 0), 'available', coalesce(sum(pp.available), 0))
                       from public.inventory_item_positions pp where pp.location_id = d.location_id and pp.inventory_item_id = l.inventory_item_id),
        'inbound', public.inv_inbound(d.location_id, l.inventory_item_id),
        'bins', (select coalesce(jsonb_agg(jsonb_build_object('id', bb.bin_id, 'code', bb.bin_code, 'name', bb.bin_name, 'zone', bb.zone, 'on_hand', bb.q) order by bb.zone, bb.bin_code), '[]'::jsonb)
                   from (select bin_id, bin_code, bin_name, zone, sum(on_hand) q from public.inventory_bin_balances
                          where location_id = d.location_id and inventory_item_id = l.inventory_item_id group by 1, 2, 3, 4 having sum(on_hand) <> 0) bb)
      ) order by l.line_no), '[]'::jsonb)
      from public.inventory_document_lines l join public.inventory_items i on i.id = l.inventory_item_id where l.document_id = d.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'from_status', e.from_status, 'to_status', e.to_status,
        'actor', public.inv_person(v_org, e.actor), 'note', e.note, 'at', e.created_at) order by e.id), '[]'::jsonb)
      from public.inventory_document_events e where e.document_id = d.id and e.action <> 'save'));
end $function$;
