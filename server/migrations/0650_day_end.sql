-- 0650: Day end (founder, 3 Nov 2026: "Day end doesn't warn about open tables or unpaid bills, and a closed day can't be reopened. If the
-- count is invalid, the button silently does nothing. (Rename close day to day end, Unsettled tables should go in revenue leakage)").
-- The restaurant's cash drawer Close day (rmoney_close_day, 0622) becomes Day end:
--   * rmoney__open_bills: the outlet's bills still open (a table's, a takeaway's or a phone delivery's; app and aggregator orders are
--     paid on their platform): place, status and what is still due.
--   * rmoney_register: shows them ('open_bills'), the note and the open bills of the day end, who may reopen, and the day's reopens.
--   * rmoney_close_day: with bills still open it stops and says so (MONEY_OPEN_BILLS); ending the day anyway needs confirm_open_bills and a
--     note, and each open bill is recorded as 'day_end_unsettled' on the bill: it shows in Revenue leakage.
--   * rmoney_reopen_day (money:approve, the owner and admins): reopens an ended day with a reason; the count's cash difference is voided,
--     the day end is kept in rmoney_day_reopens, and the reopen shows in Revenue leakage too.
--   * rmoney_record, rmoney_void: an ended day says Day end is done and that the owner can reopen it.
--   * rst_report_audit ('day_end') and rst_home_insights (leakage.unsettled, leakage.reopened): the unsettled bills and the reopens.
-- Days already closed stay closed. Safe to run again.

alter table public.rmoney_day_closes add column if not exists note text;
alter table public.rmoney_day_closes add column if not exists open_bills int not null default 0;
alter table public.rmoney_day_closes add column if not exists open_due_minor bigint not null default 0;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'rmoney_day_closes_note_check') then
    alter table public.rmoney_day_closes add constraint rmoney_day_closes_note_check check (note is null or char_length(note) <= 200);
  end if;
end $c$;

create table if not exists public.rmoney_day_reopens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  expected_minor bigint not null,
  counted_minor bigint not null,
  closed_by uuid,
  closed_at timestamptz not null,
  close_note text,
  reason text not null check (char_length(reason) between 3 and 200),
  reopened_by uuid,
  reopened_at timestamptz not null default now()
);
create index if not exists rmoney_day_reopens_org_day on public.rmoney_day_reopens (organization_id, location_id, day);
create index if not exists rmoney_day_reopens_org_at on public.rmoney_day_reopens (organization_id, reopened_at);
alter table public.rmoney_day_reopens enable row level security;
revoke all on public.rmoney_day_reopens from anon, authenticated;

create or replace function public.rmoney__open_bills(p_org uuid, p_locs uuid[]) returns jsonb
  language sql stable security definer set search_path to 'public', 'pg_temp' as $f$
  with b as (
    select o.id, coalesce(o.display_no, o.order_no::text) bill, o.status, o.created_at,
           case when o.table_id is not null then 'Table ' || coalesce((select t.label from public.dining_tables t where t.id = o.table_id), '?')
                when o.channel = 'pickup' then 'Takeaway' else 'Delivery' end place,
           round(greatest(o.total - coalesce((select sum(y.amount) from public.payments y where y.order_id = o.id), 0), 0) * 100)::bigint due_minor
      from public.orders o
     where o.organization_id = p_org and o.location_id = any (p_locs) and o.channel in ('dine_in', 'pickup', 'delivery')
       and public.tbl_order_open(o.status, o.paid_at)
       and exists (select 1 from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'))
  select jsonb_build_object('count', (select count(*) from b), 'tables', (select count(*) from b where place like 'Table %'),
    'due_minor', (select coalesce(sum(due_minor), 0) from b),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', id, 'bill', bill, 'place', place, 'status', status, 'due_minor', due_minor, 'opened_at', created_at)
                                         order by created_at), '[]'::jsonb) from b));
$f$;
revoke all on function public.rmoney__open_bills(uuid, uuid[]) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rmoney_register(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); r record; c public.rmoney_day_closes;
begin
  select coalesce(sum(case when l.day < v_day then case l.direction when 'in' then l.amount_minor else -l.amount_minor end end), 0) opening,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'in' and l.source = 'sale'), 0) sales,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'in' and l.source <> 'sale'), 0) other_in,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'out' and l.source = 'refund'), 0) refunds,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'out' and l.source <> 'refund'), 0) paid_out
    into r from public.rmoney_ledger(v_org, v_locs) l where l.account = 'cash' and l.day <= v_day
      -- the day's own close difference is shown as the count, not as cash in or out
      and not (l.kind = 'cash_difference' and l.day = v_day);
  select * into c from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day;
  return jsonb_build_object('day', v_day,
    -- 0650: bills still open now (Day end warns about them), who may reopen an ended day, and the day's reopens
    'open_bills', public.rmoney__open_bills(v_org, array[v_locs[1]]),
    'can_reopen', public.has_permission(v_org, 'money', 'approve', null) and c.day is not null,
    'reopens', (select coalesce(jsonb_agg(jsonb_build_object('at', x.reopened_at, 'by', public.money_person(v_org, x.reopened_by), 'reason', x.reason,
                  'counted_minor', x.counted_minor) order by x.reopened_at), '[]'::jsonb)
                from public.rmoney_day_reopens x where x.organization_id = v_org and x.location_id = v_locs[1] and x.day = v_day), 'opening_minor', r.opening, 'cash_sales_minor', r.sales, 'other_in_minor', r.other_in, 'refunds_minor', r.refunds,
    'paid_out_minor', r.paid_out, 'expected_minor', r.opening + r.sales + r.other_in - r.refunds - r.paid_out,
    'closed', case when c.day is null then null else jsonb_build_object('counted_minor', c.counted_minor, 'expected_minor', c.expected_minor,
               'difference_minor', c.counted_minor - c.expected_minor, 'at', c.created_at, 'by', public.money_person(v_org, c.created_by),
               'note', c.note, 'open_bills', c.open_bills, 'open_due_minor', c.open_due_minor) end,
    'can_close', public.has_permission(v_org, 'money', 'record', null) and c.day is null);
end $function$;

CREATE OR REPLACE FUNCTION public.rmoney_close_day(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'record'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); v_counted bigint := nullif(p->>'counted_minor', '')::bigint;
  v_reg jsonb; v_exp bigint; v_diff bigint; v_open jsonb; v_n int; v_note text := nullif(btrim(coalesce(p->>'note', '')), ''); v_round int;
begin
  if v_counted is null or v_counted < 0 then raise exception 'MONEY_BAD_REQUEST: enter the cash you counted'; end if;
  if v_day > (now() at time zone v_tz)::date then raise exception 'MONEY_BAD_REQUEST: that day has not come yet'; end if;
  if exists (select 1 from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day) then
    raise exception 'MONEY_BAD_REQUEST: this day has already ended'; end if;
  -- 0650: bills still open: say so first; ending the day anyway needs a note, and each goes to Revenue leakage
  v_open := public.rmoney__open_bills(v_org, array[v_locs[1]]); v_n := (v_open->>'count')::int;
  if v_note is not null and char_length(v_note) > 200 then raise exception 'MONEY_BAD_REQUEST: keep the note under 200 characters'; end if;
  if v_n > 0 then
    if not coalesce((p->>'confirm_open_bills')::boolean, false) then
      raise exception 'MONEY_OPEN_BILLS: % still open (₹%); settle them, or end the day with a note and they go to Revenue leakage',
        case when v_n = 1 then '1 bill is' else v_n || ' bills are' end, trim(to_char((v_open->>'due_minor')::bigint / 100.0, 'FM99999999990.00')); end if;
    if v_note is null or char_length(v_note) < 3 then raise exception 'MONEY_REASON_REQUIRED: write why the day ends with bills still open'; end if;
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    select v_org, (b->>'order_id')::uuid, 'day_end_unsettled',
           (b->>'place') || ' left unsettled at day end, ₹' || trim(to_char((b->>'due_minor')::bigint / 100.0, 'FM99999999990.00')) || ' due', 'pos',
           jsonb_build_object('by', auth.uid(), 'day', v_day, 'place', b->>'place', 'status', b->>'status', 'due_minor', (b->>'due_minor')::bigint, 'note', v_note)
      from jsonb_array_elements(v_open->'list') b;
  end if;
  v_reg := public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
  v_exp := (v_reg->>'expected_minor')::bigint; v_diff := v_counted - v_exp;
  insert into public.rmoney_day_closes (organization_id, location_id, day, expected_minor, counted_minor, created_by, note, open_bills, open_due_minor)
  values (v_org, v_locs[1], v_day, v_exp, v_counted, auth.uid(), v_note, v_n, coalesce((v_open->>'due_minor')::bigint, 0));
  -- a day ended again after a reopen keeps its own cash difference entry
  select count(*) into v_round from public.rmoney_day_reopens where organization_id = v_org and location_id = v_locs[1] and day = v_day;
  if v_diff <> 0 then
    insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, note, entry_date, created_by, idempotency_key)
    values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), case when v_diff > 0 then 'in' else 'out' end, 'cash_difference',
            case when v_diff > 0 then 'Extra cash at close' else 'Cash short at close' end, 'cash', abs(v_diff), null, v_day, auth.uid(), 'close:' || v_locs[1] || ':' || v_day || case when v_round > 0 then ':' || v_round else '' end);
  end if;
  return public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
end $function$;

create or replace function public.rmoney_reopen_day(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_org uuid := public.money_require('money', 'approve'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  c public.rmoney_day_closes%rowtype;
begin
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'MONEY_REASON_REQUIRED: write why the day is reopened'; end if;
  if char_length(v_reason) > 200 then raise exception 'MONEY_BAD_REQUEST: keep the reason under 200 characters'; end if;
  select * into c from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day for update;
  if not found then raise exception 'MONEY_BAD_REQUEST: this day has not ended'; end if;
  insert into public.rmoney_day_reopens (organization_id, location_id, day, expected_minor, counted_minor, closed_by, closed_at, close_note, reason, reopened_by)
  values (v_org, c.location_id, v_day, c.expected_minor, c.counted_minor, c.created_by, c.created_at, c.note, v_reason, auth.uid());
  -- the count's extra or short cash no longer stands: the day is counted again at its next Day end
  update public.rmoney_entries set status = 'voided', void_reason = left('Day reopened: ' || v_reason, 200)
   where organization_id = v_org and location_id = c.location_id and kind = 'cash_difference' and entry_date = v_day and status = 'posted';
  delete from public.rmoney_day_closes where organization_id = v_org and location_id = c.location_id and day = v_day;
  return public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
end $f$;
revoke all on function public.rmoney_reopen_day(jsonb) from public, anon;
grant execute on function public.rmoney_reopen_day(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rmoney_record(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'record'); v_key text := public.money_key(p); v_locs uuid[] := public.money_scope(v_org, p);
  v_dir text := coalesce(p->>'direction', ''); v_kind text := nullif(btrim(coalesce(p->>'kind', '')), '');
  v_method text := nullif(p->>'method', ''); v_amt bigint := public.money_amount(p, false); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'entry_date', '')::date, (now() at time zone v_tz)::date);
  v_party text := nullif(btrim(coalesce(p->>'party', '')), ''); v_phone text := nullif(btrim(coalesce(p->>'party_phone', '')), '');
  v_from text := nullif(p->>'from_account', ''); v_to text := nullif(p->>'to_account', ''); e public.rmoney_entries;
  v_bill uuid := nullif(p->>'bill_receipt_id', '')::uuid; b record; -- b: a pur_bills row (the table exists where Received does)
  v_ref text := nullif(left(btrim(coalesce(p->>'reference', '')), 60), '');
  v_cash bigint;
begin
  select * into e from public.rmoney_entries where organization_id = v_org and idempotency_key = v_key;
  if found then return to_jsonb(e) || jsonb_build_object('replayed', true); end if;
  if v_dir not in ('in', 'out', 'move') then raise exception 'MONEY_BAD_REQUEST: choose money in, money out or a move'; end if;
  if v_day > (now() at time zone v_tz)::date then raise exception 'MONEY_BAD_REQUEST: the date cannot be in the future'; end if;
  if v_dir = 'move' then
    if v_from is null or v_to is null or v_from = v_to or v_from not in ('cash', 'upi', 'bank') or v_to not in ('cash', 'upi', 'bank') then
      raise exception 'MONEY_BAD_REQUEST: choose two different accounts'; end if;
    v_method := null; v_kind := 'transfer';
  else
    if v_method is null or v_method not in ('cash', 'upi', 'gpay', 'phonepe', 'card', 'bank') then raise exception 'MONEY_BAD_REQUEST: choose how the money moved'; end if;
    if v_bill is not null then v_kind := 'supplier_payment'; end if; -- paying a purchase bill is always a supplier payment
    if v_kind is null then raise exception 'MONEY_BAD_REQUEST: choose what it is for'; end if;
    v_from := null; v_to := null;
  end if;
  if v_kind = 'due_received' and v_party is null then raise exception 'MONEY_BAD_REQUEST: say who paid the due'; end if;
  -- 3. a closed day keeps its cash count
  if (v_method = 'cash' or 'cash' in (v_from, v_to)) and public.rmoney_day_closed(v_org, v_locs[1], v_day) then
    raise exception 'MONEY_DAY_CLOSED: Day end is done for %; the owner can reopen the day to record cash on it', to_char(v_day, 'DD Mon');
  end if;
  -- 2. cash cannot leave the drawer beyond what is in it
  if (v_dir = 'out' and v_method = 'cash') or (v_dir = 'move' and v_from = 'cash') then
    v_cash := public.rmoney_cash_now(v_org, v_locs);
    if v_amt > v_cash then
      raise exception 'MONEY_NOT_ENOUGH_CASH: only % in the cash drawer', public.notice_money(greatest(v_cash, 0) / 100.0, 'INR');
    end if;
  end if;
  -- 1. a purchase bill paid from Money (the store's rule: what is left = total − paid − credit)
  if v_bill is not null then
    if v_dir <> 'out' then raise exception 'MONEY_BAD_REQUEST: a purchase bill is paid with money out'; end if;
    select * into b from public.pur_bills where receipt_document_id = v_bill and organization_id = v_org for update;
    if not found or not b.saved then raise exception 'MONEY_NOT_FOUND: purchase bill not found (save the bill first)'; end if;
    if v_amt > b.total_minor - b.paid_minor - b.credit_minor then
      raise exception 'MONEY_BAD_REQUEST: only % is left to pay on this bill', public.notice_money((b.total_minor - b.paid_minor - b.credit_minor) / 100.0, 'INR');
    end if;
    v_kind := 'supplier_payment'; v_party := coalesce(v_party, left(b.supplier_name, 60)); v_ref := coalesce(v_ref, nullif(left(b.invoice_no, 60), ''));
    update public.pur_bills set paid_minor = least(paid_minor + v_amt, total_minor),
           payment_status = case when paid_minor + v_amt + credit_minor >= total_minor then 'paid' else 'partly_paid' end, updated_at = now()
     where receipt_document_id = b.receipt_document_id;
  end if;
  insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, party, party_phone, reference, note,
                                     from_account, to_account, entry_date, created_by, idempotency_key, bill_receipt_id)
  values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), v_dir, v_kind,
          coalesce(nullif(left(btrim(coalesce(p->>'category', '')), 60), ''), case when v_bill is not null then 'Purchase bill' end), v_method, v_amt,
          left(v_party, 60), left(v_phone, 20), v_ref, nullif(left(btrim(coalesce(p->>'note', '')), 300), ''), v_from, v_to, v_day, auth.uid(), v_key, v_bill)
  returning * into e;
  return to_jsonb(e) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.rmoney_void(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'approve'); e public.rmoney_entries; v_reason text := btrim(coalesce(p->>'reason', ''));
begin
  if v_reason = '' then raise exception 'MONEY_BAD_REQUEST: say why it is removed'; end if;
  select * into e from public.rmoney_entries where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'MONEY_NOT_FOUND: entry not found (only entries made here can be removed)'; end if;
  if e.kind = 'cash_difference' then raise exception 'MONEY_BAD_REQUEST: a day close cannot be undone'; end if;
  if e.status = 'voided' then return to_jsonb(e); end if;
  -- 3. a closed day keeps its cash count
  if (e.method = 'cash' or 'cash' in (e.from_account, e.to_account)) and public.rmoney_day_closed(v_org, e.location_id, e.entry_date) then
    raise exception 'MONEY_DAY_CLOSED: Day end is done for %; the owner can reopen the day to change this entry', to_char(e.entry_date, 'DD Mon');
  end if;
  -- cash that came into the drawer (cash in, or a move into cash) cannot be taken back once it has gone out again: the drawer never goes
  -- below zero (0647: removing a cash in used to)
  if ((e.direction = 'in' and e.method = 'cash') or (e.direction = 'move' and e.to_account = 'cash'))
     and e.amount_minor > public.rmoney_cash_now(v_org, array[e.location_id]) then
    raise exception 'MONEY_NOT_ENOUGH_CASH: only % is in the cash drawer, so this % cannot be removed; that cash has gone out already',
      public.notice_money(greatest(public.rmoney_cash_now(v_org, array[e.location_id]), 0) / 100.0, 'INR'), public.notice_money(e.amount_minor / 100.0, 'INR');
  end if;
  -- 1. a purchase bill payment comes off the bill again
  if e.bill_receipt_id is not null then
    update public.pur_bills set paid_minor = greatest(paid_minor - e.amount_minor, 0),
           payment_status = case when greatest(paid_minor - e.amount_minor, 0) = 0 then 'unpaid'
                                 when greatest(paid_minor - e.amount_minor, 0) + credit_minor >= total_minor then 'paid' else 'partly_paid' end,
           updated_at = now()
     where receipt_document_id = e.bill_receipt_id and organization_id = v_org;
  end if;
  update public.rmoney_entries set status = 'voided', void_reason = left(v_reason, 200) where id = e.id returning * into e;
  return to_jsonb(e);
end $function$;

CREATE OR REPLACE FUNCTION public.rst_report_audit(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_today_start timestamptz;
begin
  if not public.has_permission(v_org, 'pos_audit_log', 'read', null) then raise exception 'MONEY_FORBIDDEN: your role cannot see the audit'; end if;
  select * into w from public.rst_rep__window(p);
  v_today_start := ((now() at time zone w.tz)::date)::timestamp at time zone w.tz;
  return (
    with mine as (select o.* from public.orders o where o.organization_id = v_org and (o.location_id = any (v_locs) or (o.location_id is null and v_all))),
    cancelled as (
      select o.*, (select coalesce(sum(round(i.unit_price * i.qty * 100)), 0) from public.order_items i where i.order_id = o.id) value_minor,
             exists (select 1 from public.order_events e where e.order_id = o.id and e.kind = 'kot_fired') kot_sent,
             public.order_cancel_info(o.id) info,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1) by_user
        from mine o where o.status = 'cancelled' and o.updated_at >= w.t_from and o.updated_at < w.t_to),
    unpaid as (
      -- 0645: a bill shows at once, by when it was generated (not when the order was opened, nor only after the day ends)
      select o.* from mine o, lateral (select coalesce((select max(e.created_at) from public.order_events e where e.order_id = o.id and e.kind = 'status_awaiting_payment'), o.created_at) as billed_at) g
       where o.status = 'awaiting_payment' and g.billed_at >= w.t_from and g.billed_at < w.t_to),
    ev as (
      select e.*, o.display_no, o.order_no from public.order_events e join mine o on o.id = e.order_id
       where e.created_at >= w.t_from and e.created_at < w.t_to),
    reprints as (select * from ev where kind like 'receipt\_%' or kind = 'kot_reprinted'),
    after_bill as (
      select * from ev where kind in ('items_added', 'coupon_applied', 'payment_cancelled', 'service_charge_waived', 'service_charge_restored', 'table_transferred',
                                     'manual_discount', 'manual_discount_removed', 'item_cancelled')
         and exists (select 1 from public.order_events b where b.order_id = ev.order_id and b.kind = 'status_awaiting_payment' and b.created_at < ev.created_at)),
    -- 0645: changes made with an admin PIN (a generated bill changed, an order cancelled after its KOT)
    overrides as (select * from ev where kind = 'admin_override'),
    -- 0650: bills left open at Day end, and ended days reopened
    unsettled as (select * from ev where kind = 'day_end_unsettled'),
    reopened as (select x.* from public.rmoney_day_reopens x where x.organization_id = v_org and x.reopened_at >= w.t_from and x.reopened_at < w.t_to
                   and (x.location_id = any (v_locs) or v_all)),
    refunds as (
      select r.*, o.display_no, o.order_no from public.pos_refunds r left join public.orders o on o.id = r.order_id
       where r.organization_id = v_org and r.created_at >= w.t_from and r.created_at < w.t_to
         and (coalesce(r.location_id, o.location_id) = any (v_locs) or (coalesce(r.location_id, o.location_id) is null and v_all)))
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'cancelled', jsonb_build_object('bills', (select count(*) from cancelled), 'value_minor', (select coalesce(sum(value_minor), 0) from cancelled),
        'after_kot', (select count(*) from cancelled where kot_sent),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', c.id, 'bill', coalesce(c.display_no, c.order_no::text), 'at', c.updated_at, 'channel', c.channel,
                   'value_minor', c.value_minor, 'kot_sent', c.kot_sent, 'by', coalesce(public.money_person(v_org, nullif(c.by_user, '')::uuid), c.info->>'by'),
                   'reason', c.info->>'reason') order by c.updated_at desc), '[]'::jsonb) from cancelled c)),
      'unpaid', jsonb_build_object('bills', (select count(*) from unpaid), 'value_minor', (select coalesce(sum(total_minor), 0) from unpaid),
        'list', (select coalesce(jsonb_agg(public.rst_rep__bill(u, w.tz) order by u.created_at desc), '[]'::jsonb) from unpaid u)),
      'reprints', jsonb_build_object('count', (select count(*) from reprints),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', r.order_id, 'bill', coalesce(r.display_no, r.order_no::text), 'at', r.created_at, 'kind', r.kind,
                   'what', r.message, 'by', public.money_person(v_org, nullif(r.meta->>'by', '')::uuid)) order by r.created_at desc), '[]'::jsonb) from reprints r)),
      'after_bill', jsonb_build_object('count', (select count(*) from after_bill),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', a.order_id, 'bill', coalesce(a.display_no, a.order_no::text), 'at', a.created_at, 'kind', a.kind,
                   'what', a.message, 'by', public.money_person(v_org, nullif(a.meta->>'by', '')::uuid)) order by a.created_at desc), '[]'::jsonb) from after_bill a)),
      'refunds', jsonb_build_object('count', (select count(*) from refunds), 'amount_minor', (select coalesce(sum(amount_minor), 0) from refunds),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', r.order_id, 'bill', coalesce(r.display_no, r.order_no::text), 'at', r.created_at, 'kind', r.kind,
                   'method', r.method, 'amount_minor', r.amount_minor, 'reason', r.reason, 'by', public.money_person(v_org, r.created_by)) order by r.created_at desc), '[]'::jsonb)
                 from refunds r)),
      'overrides', jsonb_build_object('count', (select count(*) from overrides),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', x.order_id, 'bill', coalesce(x.display_no, x.order_no::text), 'at', x.created_at,
                   'action', x.meta->>'action', 'what', x.message, 'note', x.meta->>'note', 'by', public.money_person(v_org, nullif(x.meta->>'by', '')::uuid),
                   'approved_by', public.money_person(v_org, nullif(x.meta->>'approved_by', '')::uuid), 'total_minor', round(coalesce((x.meta->>'total')::numeric, 0) * 100))
                   order by x.created_at desc), '[]'::jsonb) from overrides x)),
      'day_end', jsonb_build_object(
        'unsettled', jsonb_build_object('count', (select count(*) from unsettled), 'due_minor', (select coalesce(sum((meta->>'due_minor')::bigint), 0) from unsettled),
          'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', u.order_id, 'bill', coalesce(u.display_no, u.order_no::text), 'at', u.created_at,
                     'day', u.meta->>'day', 'place', u.meta->>'place', 'due_minor', (u.meta->>'due_minor')::bigint, 'note', u.meta->>'note',
                     'by', public.money_person(v_org, nullif(u.meta->>'by', '')::uuid)) order by u.created_at desc), '[]'::jsonb) from unsettled u)),
        'reopened', jsonb_build_object('count', (select count(*) from reopened),
          'list', (select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'at', x.reopened_at, 'reason', x.reason, 'counted_minor', x.counted_minor,
                     'expected_minor', x.expected_minor, 'by', public.money_person(v_org, x.reopened_by)) order by x.reopened_at desc), '[]'::jsonb) from reopened x))),
      'not_recorded', jsonb_build_array('price_edit')));
end $function$;

CREATE OR REPLACE FUNCTION public.rst_home_insights(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.total, o.channel,
             case when o.channel = 'dine_in' then 'dine_in' when o.channel = 'pickup' then 'takeaway' else 'delivery' end as served
        from public.orders o
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
    ), li as (
      select i.menu_item_id, i.name, i.qty, i.unit_price from public.order_items i join o on o.id = i.order_id where i.status <> 'cancelled'
    ), dishes as materialized (
      select m.id, m.name, m.is_available, m.image_url, m.description,
             public.menu_can_make(v_org, m.id) as can_make,
             exists (select 1 from public.menu_item_recipes r where r.menu_item_id = m.id and r.organization_id = v_org) as has_recipe,
             (public.mb_recipe_json(v_org, m.id)->>'food_cost_pct')::numeric as food_pct
        from public.menu_items m where m.organization_id = v_org
    )
    select jsonb_build_object(
      'mix', jsonb_build_object(
        'orders', (select count(*) from o),
        'sales', (select coalesce(sum(total), 0) from o),
        'avg_bill', (select coalesce(round(avg(total), 2), 0) from o),
        'by', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label,
                  'orders', (select count(*) from o where o.served = k.key), 'sales', (select coalesce(sum(o.total), 0) from o where o.served = k.key)) order by k.sort)
               from (values ('dine_in', 'Dine in', 1), ('takeaway', 'Takeaway', 2), ('delivery', 'Delivery', 3)) k(key, label, sort))),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', x.method, 'amount', x.amount, 'count', x.n) order by x.amount desc), '[]')
                     from (select pm.method, sum(pm.amount) as amount, count(*) as n from public.payments pm
                            where pm.organization_id = v_org and pm.created_at >= v_since and pm.amount > 0
                              and (v_loc is null or exists (select 1 from public.orders x where x.id = pm.order_id and x.location_id = v_loc))
                            group by pm.method) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'sales', t.sales) order by t.qty desc, t.sales desc), '[]')
                from (select li.name, sum(li.qty) as qty, sum(li.qty * li.unit_price) as sales from li group by li.name order by 2 desc, 3 desc limit 5) t),
      'menu', jsonb_build_object(
        'dishes', (select count(*) from dishes),
        'low', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'can_make', d.can_make) order by d.can_make, d.name), '[]')
                  from (select * from dishes where can_make is not null and can_make < 10 order by can_make, name limit 5) d),
        'out', (select count(*) from dishes where not is_available or can_make = 0),
        'food_cost_avg', (select round(avg(food_pct), 1) from dishes where food_pct is not null),
        'high_cost', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'pct', round(d.food_pct, 1)) order by d.food_pct desc), '[]')
                        from (select * from dishes where food_pct > 45 order by food_pct desc limit 5) d),
        'no_recipe', (select count(*) from dishes where not has_recipe),
        'no_photo', (select count(*) from dishes where coalesce(btrim(image_url), '') = ''),
        'no_description', (select count(*) from dishes where coalesce(btrim(description), '') = '')),
      'ready', (select count(*) from public.order_items i join o on o.id = i.order_id where i.status = 'ready'),
      -- 0645: revenue leakage: changes made today with an admin PIN (the owner's and the managers' who may see the audit)
      'leakage', case when public.has_permission(v_org, 'pos_audit_log', 'read', null) then (
        with x as (select e.*, od.display_no from public.order_events e join public.orders od on od.id = e.order_id
                    where e.organization_id = v_org and e.kind = 'admin_override' and e.created_at >= v_since
                      and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id))
        select jsonb_build_object('admin_changes', (select count(*) from x),
          -- 0650: bills left open at Day end and ended days reopened, today
          'unsettled', (select count(*) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'unsettled_due_minor', (select coalesce(sum((e.meta->>'due_minor')::bigint), 0) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'reopened', (select count(*) from public.rmoney_day_reopens r where r.organization_id = v_org and r.reopened_at >= v_since
                         and (v_loc is null or r.location_id = v_loc)),
          'latest', (select coalesce(jsonb_agg(jsonb_build_object('bill', y.display_no, 'what', y.message, 'at', y.created_at,
                       'by', public.money_person(v_org, nullif(y.meta->>'by', '')::uuid), 'approved_by', public.money_person(v_org, nullif(y.meta->>'approved_by', '')::uuid))
                       order by y.created_at desc), '[]'::jsonb) from (select * from x order by created_at desc limit 3) y))) end
    )
  );
end $function$;

notify pgrst, 'reload schema';
