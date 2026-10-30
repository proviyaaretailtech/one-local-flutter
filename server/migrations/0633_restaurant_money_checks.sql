-- 0633: Restaurant Money, the whole flow checked (founder, 30 Oct 2026: "check overall flow for money"). Bills, expenses, owner money and
-- account moves already landed in the right account; four things did not hold:
--   1. purchase bills (pur_bills, made by Received and saved on the purchase-bill screen) never showed in Dues to pay, and could not be paid
--      from Money: dues now list the saved bills next to supplier invoices, and paying one records the money going out and marks the bill
--      paid / partly paid, the same as the store's Money (smoney_record); voiding that payment takes it off the bill again;
--   2. the cash drawer could go below zero (a move of ₹200 out of a drawer holding ₹108): cash out and moves out of cash are refused
--      beyond what is in the drawer;
--   3. a closed day could still change: no cash entry dated on a closed day, and none of its cash entries can be voided;
--   4. (follows from 2) Close day no longer meets a drawer below zero from Money's own entries.

alter table public.rmoney_entries add column if not exists bill_receipt_id uuid;

-- what is in the cash drawer now (everything Money counts in cash, voided rows left out)
create or replace function public.rmoney_cash_now(p_org uuid, p_locs uuid[]) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(case l.direction when 'in' then l.amount_minor else -l.amount_minor end), 0)::bigint
    from public.rmoney_ledger(p_org, p_locs) l where l.account = 'cash'
$$;
revoke all on function public.rmoney_cash_now(uuid, uuid[]) from public, anon, authenticated;

create or replace function public.rmoney_day_closed(p_org uuid, p_loc uuid, p_day date) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.rmoney_day_closes where organization_id = p_org and location_id = p_loc and day = p_day)
$$;
revoke all on function public.rmoney_day_closed(uuid, uuid, date) from public, anon, authenticated;

create or replace function public.rmoney_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
    raise exception 'MONEY_DAY_CLOSED: the cash for % is closed; record it on today', to_char(v_day, 'DD Mon');
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
end $$;

create or replace function public.rmoney_void(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'approve'); e public.rmoney_entries; v_reason text := btrim(coalesce(p->>'reason', ''));
begin
  if v_reason = '' then raise exception 'MONEY_BAD_REQUEST: say why it is removed'; end if;
  select * into e from public.rmoney_entries where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'MONEY_NOT_FOUND: entry not found (only entries made here can be removed)'; end if;
  if e.kind = 'cash_difference' then raise exception 'MONEY_BAD_REQUEST: a day close cannot be undone'; end if;
  if e.status = 'voided' then return to_jsonb(e); end if;
  -- 3. a closed day keeps its cash count
  if (e.method = 'cash' or 'cash' in (e.from_account, e.to_account)) and public.rmoney_day_closed(v_org, e.location_id, e.entry_date) then
    raise exception 'MONEY_DAY_CLOSED: the cash for % is closed; this entry stays', to_char(e.entry_date, 'DD Mon');
  end if;
  -- a cash move into the drawer cannot be taken back once that cash has gone out again
  if e.direction = 'move' and e.to_account = 'cash' and e.amount_minor > public.rmoney_cash_now(v_org, array[e.location_id]) then
    raise exception 'MONEY_NOT_ENOUGH_CASH: that cash has left the drawer already';
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
end $$;

-- dues: bills put on credit (to collect), supplier invoices and saved purchase bills (to pay)
create or replace function public.rmoney_dues(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_in jsonb; v_out jsonb; v_bills jsonb := '[]';
begin
  -- saved purchase bills still to pay (pur_bills exists where Received does)
  if to_regclass('public.pur_bills') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('kind', 'purchase_bill', 'bill_receipt_id', b.receipt_document_id, 'reference', nullif(b.invoice_no, ''),
               'name', b.supplier_name, 'amount_minor', b.total_minor, 'paid_minor', b.paid_minor + b.credit_minor,
               'left_minor', b.total_minor - b.paid_minor - b.credit_minor, 'due_date', null) order by b.created_at), '[]'::jsonb)
        from public.pur_bills b
       where b.organization_id = $1 and (b.location_id is null or b.location_id = any ($2)) and b.saved and b.payment_status <> 'paid'
         and b.total_minor - b.paid_minor - b.credit_minor > 0 $q$ into v_bills using v_org, v_locs;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('order_id', d.order_id, 'reference', d.no, 'name', d.name, 'phone', d.phone, 'amount_minor', d.amt,
           'paid_minor', d.got, 'left_minor', d.amt - d.got, 'at', d.at) order by d.at), '[]'::jsonb) into v_in
    from (select o.id order_id, o.display_no no, coalesce(nullif(btrim(o.customer_name), ''), 'Customer') name, o.customer_phone phone, sum(x.amount_minor) amt,
                 min(x.created_at) at,
                 coalesce((select sum(m.amount_minor) from public.rmoney_entries m where m.organization_id = v_org and m.kind = 'due_received'
                            and m.status = 'posted' and m.reference = o.display_no), 0) got
            from public.payments x join public.orders o on o.id = x.order_id
           where x.organization_id = v_org and x.method = 'due' and (o.location_id = any (v_locs) or o.location_id is null)
           group by o.id) d where d.amt > d.got;
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'invoice', 'invoice_id', i.id, 'reference', i.invoice_no, 'name', i.supplier_name, 'amount_minor', i.total_minor,
           'paid_minor', i.paid, 'left_minor', i.total_minor - i.paid, 'due_date', i.due_date) order by i.due_date nulls last, i.invoice_date), '[]'::jsonb) into v_out
    from (select s.*, coalesce((select sum(y.amount_minor) from public.supplier_invoice_payments y where y.invoice_id = s.id), 0) paid
            from public.supplier_invoices s where s.organization_id = v_org and (s.location_id = any (v_locs) or s.location_id is null)) i
   where i.total_minor > i.paid;
  v_out := v_out || v_bills;
  return jsonb_build_object('to_collect', v_in, 'to_pay', v_out,
    'collect_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_in) x),
    'pay_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_out) x));
end $$;
