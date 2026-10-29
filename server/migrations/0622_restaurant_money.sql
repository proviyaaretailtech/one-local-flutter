-- 0622: restaurant Money in the store's design (founder, 29 Oct 2026: "keep money built like this for restaurant POS", rebuilt here rather
-- than merged). One ledger over what the restaurant already records — bill payments, refunds, expenses, cash entries, people given / got,
-- supplier invoice payments — plus its own manual entries, so the screens show:
--   * the wallet balance: the cash drawer, UPI and bank (card counts as bank), each = money in − money out + moves between them
--   * Money in / Money out lists by date and method; Add money / Pay money; Transfer to a contact (UPI app or card); move between accounts
--   * the day's cash register (opening, cash sales, other cash in, refunds, paid out, should be in the drawer) and Close day with the count
--   * dues: bills put on credit to collect, supplier invoices to pay
-- New: rmoney_entries, rmoney_contacts, rmoney_day_closes; rmoney_ledger(); rmoney_home, rmoney_entries_list, rmoney_record, rmoney_void,
-- rmoney_register, rmoney_close_day, rmoney_dues, rmoney_contacts_list, rmoney_contact_save. Safe to run again.

create table if not exists public.rmoney_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid references public.locations(id) on delete set null,
  entry_no text not null,
  direction text not null check (direction in ('in', 'out', 'move')),
  kind text not null check (char_length(kind) between 1 and 40),
  category text check (category is null or char_length(category) <= 60),
  method text check (method is null or method in ('cash', 'upi', 'gpay', 'phonepe', 'card', 'bank')),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 100000000000),
  party text check (party is null or char_length(party) <= 60),
  party_phone text check (party_phone is null or char_length(party_phone) <= 20),
  reference text check (reference is null or char_length(reference) <= 60),
  note text check (note is null or char_length(note) <= 300),
  from_account text check (from_account is null or from_account in ('cash', 'upi', 'bank')),
  to_account text check (to_account is null or to_account in ('cash', 'upi', 'bank')),
  entry_date date not null,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  void_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key text not null,
  unique (organization_id, idempotency_key),
  check ((direction = 'move') = (from_account is not null and to_account is not null and from_account <> to_account and method is null)),
  check (direction = 'move' or method is not null)
);
create index if not exists rmoney_entries_org_day on public.rmoney_entries (organization_id, entry_date);
alter table public.rmoney_entries enable row level security;
revoke all on public.rmoney_entries from anon, authenticated;

create table if not exists public.rmoney_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  phone text not null default '' check (char_length(phone) <= 20),
  upi_id text not null default '' check (upi_id = '' or upi_id ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z0-9.-]{2,64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists rmoney_contacts_name on public.rmoney_contacts (organization_id, lower(name));
alter table public.rmoney_contacts enable row level security;
revoke all on public.rmoney_contacts from anon, authenticated;

create table if not exists public.rmoney_day_closes (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  expected_minor bigint not null,
  counted_minor bigint not null check (counted_minor >= 0),
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key (organization_id, location_id, day)
);
alter table public.rmoney_day_closes enable row level security;
revoke all on public.rmoney_day_closes from anon, authenticated;

-- which of the three accounts a method lands in; other ways (aggregator, OneLocal app, wallet, credit) are not the restaurant's money in hand
create or replace function public.rmoney_account(p_method text) returns text
language sql immutable as $$
  select case when p_method = 'cash' then 'cash' when p_method in ('upi', 'gpay', 'phonepe') then 'upi' when p_method in ('card', 'bank') then 'bank' end
$$;

-- every money row of the outlets in p_locs (voided rows left out); moves between accounts come as two rows, one out of the source and one in
-- to the target, with kind 'transfer' (the lists skip them)
create or replace function public.rmoney_ledger(p_org uuid, p_locs uuid[])
returns table (id uuid, source text, kind text, title text, direction text, method text, account text, amount_minor bigint, day date, at timestamptz,
               party text, note text, reference text, voidable boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  with tz as (select public.money_tz() as z)
  select x.id, 'sale', 'sales', 'Sales · ' || coalesce(o.display_no, 'ORD-' || o.order_no), 'in', case when x.method = 'other' then 'online' else x.method end,
         public.rmoney_account(x.method), x.amount_minor, (x.created_at at time zone (select z from tz))::date, x.created_at,
         nullif(btrim(coalesce(o.customer_name, '')), ''), null, o.display_no, false
    from public.payments x join public.orders o on o.id = x.order_id
   where x.organization_id = p_org and (o.location_id = any (p_locs) or o.location_id is null) and x.method <> 'due'
  union all
  select r.id, 'refund', 'refund', 'Refund · ' || coalesce(o.display_no, '') , 'out', r.method, public.rmoney_account(r.method), r.amount_minor,
         (r.created_at at time zone (select z from tz))::date, r.created_at, nullif(btrim(coalesce(o.customer_name, '')), ''), r.reason, o.display_no, false
    from public.pos_refunds r join public.orders o on o.id = r.order_id
   where r.organization_id = p_org and (coalesce(r.location_id, o.location_id) = any (p_locs) or coalesce(r.location_id, o.location_id) is null)
  union all
  select e.id, 'expense', 'expense', e.title, 'out', e.method, public.rmoney_account(e.method), e.amount_minor, e.expense_date, e.created_at, null, e.note, e.expense_no, false
    from public.money_expenses e where e.organization_id = p_org and e.location_id = any (p_locs) and e.status <> 'voided'
  union all
  select c.id, 'cash', case c.direction when 'in' then 'other_in' else 'other_out' end, c.title, c.direction, 'cash', 'cash', c.amount_minor, c.entry_date, c.created_at,
         null, c.note, c.entry_no, false
    from public.money_cash_entries c where c.organization_id = p_org and c.location_id = any (p_locs) and c.source = 'manual' and c.status = 'posted'
  union all
  select y.id, 'party', case y.direction when 'gave' then 'other_out' else 'other_in' end,
         case y.direction when 'gave' then 'Given to ' else 'Received from ' end || y.party_name, case y.direction when 'gave' then 'out' else 'in' end,
         y.method, public.rmoney_account(y.method), y.amount_minor, y.entry_date, y.created_at, y.party_name, y.note, y.entry_no, false
    from public.money_party_entries y where y.organization_id = p_org and y.location_id = any (p_locs)
  union all
  select s.id, 'supplier', 'supplier_payment', 'Supplier payment · ' || i.supplier_name, 'out', s.method, public.rmoney_account(s.method), s.amount_minor, s.paid_on,
         s.created_at, i.supplier_name, s.note, i.invoice_no, false
    from public.supplier_invoice_payments s join public.supplier_invoices i on i.id = s.invoice_id
   where s.organization_id = p_org and (i.location_id = any (p_locs) or i.location_id is null)
  union all
  select m.id, 'manual', m.kind, coalesce(nullif(m.category, ''), m.kind), m.direction, m.method, public.rmoney_account(m.method), m.amount_minor, m.entry_date,
         m.created_at, m.party, m.note, m.reference, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction <> 'move'
  union all
  select m.id, 'manual', 'transfer', 'Account transfer', 'out', null, m.from_account, m.amount_minor, m.entry_date, m.created_at, null, m.note, m.entry_no, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction = 'move'
  union all
  select m.id, 'manual', 'transfer', 'Account transfer', 'in', null, m.to_account, m.amount_minor, m.entry_date, m.created_at, null, m.note, m.entry_no, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction = 'move'
$$;
revoke all on function public.rmoney_ledger(uuid, uuid[]) from public, anon, authenticated;

create or replace function public.rmoney_home(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_acc jsonb;
begin
  select jsonb_agg(jsonb_build_object('key', a.k, 'name', a.n, 'balance_minor', coalesce(b.bal, 0)) order by a.o) into v_acc
    from (values ('cash', 'Cash drawer', 1), ('upi', 'UPI', 2), ('bank', 'Bank', 3)) a(k, n, o)
    left join (select l.account, sum(case l.direction when 'in' then l.amount_minor else -l.amount_minor end) bal
                 from public.rmoney_ledger(v_org, v_locs) l where l.account is not null group by l.account) b on b.account = a.k;
  return jsonb_build_object('accounts', v_acc, 'total_minor', (select coalesce(sum((x->>'balance_minor')::bigint), 0) from jsonb_array_elements(v_acc) x),
    'can_record', public.has_permission(v_org, 'money', 'record', null), 'can_void', public.has_permission(v_org, 'money', 'approve', null),
    'today', (now() at time zone public.money_tz())::date, 'snapshot_at', now());
end $$;

-- Money in or Money out between two days, by method (all | cash | upi | card)
create or replace function public.rmoney_entries_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_dir text := coalesce(nullif(p->>'direction', ''), 'in'); v_method text := coalesce(nullif(p->>'method', ''), 'all');
  v_to date := coalesce(nullif(p->>'to', '')::date, (now() at time zone v_tz)::date); v_from date := coalesce(nullif(p->>'from', '')::date, v_to);
  v_rows jsonb; v_total bigint; v_n int;
begin
  if v_dir not in ('in', 'out') then raise exception 'MONEY_BAD_REQUEST: choose money in or money out'; end if;
  if v_method not in ('all', 'cash', 'upi', 'card') then raise exception 'MONEY_BAD_REQUEST: unknown payment method'; end if;
  if v_from > v_to or v_to - v_from > 366 then raise exception 'MONEY_BAD_REQUEST: choose up to a year'; end if;
  with f as (
    select l.* from public.rmoney_ledger(v_org, v_locs) l
     where l.direction = v_dir and l.kind <> 'transfer' and l.day between v_from and v_to
       and (v_method = 'all' or (v_method = 'cash' and l.method = 'cash') or (v_method = 'upi' and l.method in ('upi', 'gpay', 'phonepe'))
            or (v_method = 'card' and l.method = 'card')))
  select coalesce(sum(amount_minor), 0), count(*),
         coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'source', g.source, 'kind', g.kind, 'title', g.title, 'direction', g.direction, 'method', g.method,
                    'amount_minor', g.amount_minor, 'day', g.day, 'at', g.at, 'party', g.party, 'note', g.note, 'reference', g.reference, 'voidable', g.voidable)
                    order by g.at desc, g.id) from (select * from f order by at desc, id limit 300) g), '[]'::jsonb)
    into v_total, v_n, v_rows from f;
  return jsonb_build_object('from', v_from, 'to', v_to, 'direction', v_dir, 'method', v_method, 'total_minor', v_total, 'count', v_n, 'rows', v_rows,
    'can_record', public.has_permission(v_org, 'money', 'record', null), 'can_void', public.has_permission(v_org, 'money', 'approve', null), 'snapshot_at', now());
end $$;

-- Add money, Pay money, Transfer to a contact, move between accounts, collect a due
create or replace function public.rmoney_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); v_key text := public.money_key(p); v_locs uuid[] := public.money_scope(v_org, p);
  v_dir text := coalesce(p->>'direction', ''); v_kind text := nullif(btrim(coalesce(p->>'kind', '')), '');
  v_method text := nullif(p->>'method', ''); v_amt bigint := public.money_amount(p, false); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'entry_date', '')::date, (now() at time zone v_tz)::date);
  v_party text := nullif(btrim(coalesce(p->>'party', '')), ''); v_phone text := nullif(btrim(coalesce(p->>'party_phone', '')), '');
  v_from text := nullif(p->>'from_account', ''); v_to text := nullif(p->>'to_account', ''); e public.rmoney_entries;
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
    if v_kind is null then raise exception 'MONEY_BAD_REQUEST: choose what it is for'; end if;
    v_from := null; v_to := null;
  end if;
  if v_kind = 'due_received' and v_party is null then raise exception 'MONEY_BAD_REQUEST: say who paid the due'; end if;
  insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, party, party_phone, reference, note,
                                     from_account, to_account, entry_date, created_by, idempotency_key)
  values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), v_dir, v_kind,
          nullif(left(btrim(coalesce(p->>'category', '')), 60), ''), v_method, v_amt, left(v_party, 60), left(v_phone, 20),
          nullif(left(btrim(coalesce(p->>'reference', '')), 60), ''), nullif(left(btrim(coalesce(p->>'note', '')), 300), ''), v_from, v_to, v_day, auth.uid(), v_key)
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
  update public.rmoney_entries set status = 'voided', void_reason = left(v_reason, 200) where id = e.id returning * into e;
  return to_jsonb(e);
end $$;

-- the cash drawer for a day: opening (everything before it), cash sales, other cash in, cash refunds, cash paid out, what should be in it
create or replace function public.rmoney_register(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
  return jsonb_build_object('day', v_day, 'opening_minor', r.opening, 'cash_sales_minor', r.sales, 'other_in_minor', r.other_in, 'refunds_minor', r.refunds,
    'paid_out_minor', r.paid_out, 'expected_minor', r.opening + r.sales + r.other_in - r.refunds - r.paid_out,
    'closed', case when c.day is null then null else jsonb_build_object('counted_minor', c.counted_minor, 'expected_minor', c.expected_minor,
               'difference_minor', c.counted_minor - c.expected_minor, 'at', c.created_at, 'by', public.money_person(v_org, c.created_by)) end,
    'can_close', public.has_permission(v_org, 'money', 'record', null) and c.day is null);
end $$;

-- Close day: the counted cash; a difference is booked as cash in (extra) or out (short), so tomorrow opens with what is really there
create or replace function public.rmoney_close_day(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); v_counted bigint := nullif(p->>'counted_minor', '')::bigint;
  v_reg jsonb; v_exp bigint; v_diff bigint;
begin
  if v_counted is null or v_counted < 0 then raise exception 'MONEY_BAD_REQUEST: enter the cash you counted'; end if;
  if v_day > (now() at time zone v_tz)::date then raise exception 'MONEY_BAD_REQUEST: that day has not come yet'; end if;
  if exists (select 1 from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day) then
    raise exception 'MONEY_BAD_REQUEST: this day is already closed'; end if;
  v_reg := public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
  v_exp := (v_reg->>'expected_minor')::bigint; v_diff := v_counted - v_exp;
  insert into public.rmoney_day_closes (organization_id, location_id, day, expected_minor, counted_minor, created_by) values (v_org, v_locs[1], v_day, v_exp, v_counted, auth.uid());
  if v_diff <> 0 then
    insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, note, entry_date, created_by, idempotency_key)
    values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), case when v_diff > 0 then 'in' else 'out' end, 'cash_difference',
            case when v_diff > 0 then 'Extra cash at close' else 'Cash short at close' end, 'cash', abs(v_diff), null, v_day, auth.uid(), 'close:' || v_locs[1] || ':' || v_day);
  end if;
  return public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
end $$;

-- dues: bills put on credit (to collect, less what was collected) and supplier invoices (to pay, less what was paid)
create or replace function public.rmoney_dues(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_in jsonb; v_out jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('order_id', d.order_id, 'reference', d.no, 'name', d.name, 'phone', d.phone, 'amount_minor', d.amt,
           'paid_minor', d.got, 'left_minor', d.amt - d.got, 'at', d.at) order by d.at), '[]'::jsonb) into v_in
    from (select o.id order_id, o.display_no no, coalesce(nullif(btrim(o.customer_name), ''), 'Customer') name, o.customer_phone phone, sum(x.amount_minor) amt,
                 min(x.created_at) at,
                 coalesce((select sum(m.amount_minor) from public.rmoney_entries m where m.organization_id = v_org and m.kind = 'due_received'
                            and m.status = 'posted' and m.reference = o.display_no), 0) got
            from public.payments x join public.orders o on o.id = x.order_id
           where x.organization_id = v_org and x.method = 'due' and (o.location_id = any (v_locs) or o.location_id is null)
           group by o.id) d where d.amt > d.got;
  select coalesce(jsonb_agg(jsonb_build_object('invoice_id', i.id, 'reference', i.invoice_no, 'name', i.supplier_name, 'amount_minor', i.total_minor,
           'paid_minor', i.paid, 'left_minor', i.total_minor - i.paid, 'due_date', i.due_date) order by i.due_date nulls last, i.invoice_date), '[]'::jsonb) into v_out
    from (select s.*, coalesce((select sum(y.amount_minor) from public.supplier_invoice_payments y where y.invoice_id = s.id), 0) paid
            from public.supplier_invoices s where s.organization_id = v_org and (s.location_id = any (v_locs) or s.location_id is null)) i
   where i.total_minor > i.paid;
  return jsonb_build_object('to_collect', v_in, 'to_pay', v_out,
    'collect_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_in) x),
    'pay_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_out) x));
end $$;

-- contacts to pay: saved ones (with a UPI ID) first, then people money was recorded with who are not saved yet
create or replace function public.rmoney_contacts_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_q text := nullif(lower(btrim(coalesce(p->>'q', ''))), '');
begin
  return jsonb_build_object(
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'upi_id', c.upi_id) order by lower(c.name)), '[]'::jsonb)
                from public.rmoney_contacts c where c.organization_id = v_org and (v_q is null or position(v_q in lower(c.name || ' ' || c.phone || ' ' || c.upi_id)) > 0)),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('name', r.n, 'phone', coalesce(r.ph, '')) order by lower(r.n)), '[]'::jsonb) from (
                 select distinct on (lower(n)) n, ph from (
                   select m.party n, m.party_phone ph from public.rmoney_entries m where m.organization_id = v_org and m.party is not null
                   union all select s.name, s.phone from public.pos_suppliers s where s.organization_id = v_org) z
                  where (v_q is null or position(v_q in lower(n)) > 0)
                    and not exists (select 1 from public.rmoney_contacts c where c.organization_id = v_org and lower(c.name) = lower(z.n))) r));
end $$;

create or replace function public.rmoney_contact_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); c public.rmoney_contacts; v_id uuid := nullif(p->>'id', '')::uuid;
  v_name text := btrim(coalesce(p->>'name', '')); v_phone text := btrim(coalesce(p->>'phone', '')); v_upi text := lower(btrim(coalesce(p->>'upi_id', '')));
begin
  if v_name = '' or char_length(v_name) > 60 then raise exception 'MONEY_BAD_REQUEST: enter a name'; end if;
  if v_upi <> '' and v_upi !~ '^[a-z0-9._-]{2,200}@[a-z0-9.-]{2,64}$' then raise exception 'MONEY_BAD_REQUEST: that UPI ID does not look right (like name@bank)'; end if;
  if v_id is null then
    insert into public.rmoney_contacts (organization_id, name, phone, upi_id) values (v_org, v_name, left(v_phone, 20), v_upi)
    on conflict (organization_id, lower(name)) do update set phone = excluded.phone, upi_id = excluded.upi_id, updated_at = now() returning * into c;
  else
    update public.rmoney_contacts set name = v_name, phone = left(v_phone, 20), upi_id = v_upi, updated_at = now() where id = v_id and organization_id = v_org returning * into c;
    if not found then raise exception 'MONEY_NOT_FOUND: contact not found'; end if;
  end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'upi_id', c.upi_id);
end $$;

revoke all on function public.rmoney_home(jsonb), public.rmoney_entries_list(jsonb), public.rmoney_record(jsonb), public.rmoney_void(jsonb),
  public.rmoney_register(jsonb), public.rmoney_close_day(jsonb), public.rmoney_dues(jsonb), public.rmoney_contacts_list(jsonb), public.rmoney_contact_save(jsonb) from public, anon;
grant execute on function public.rmoney_home(jsonb), public.rmoney_entries_list(jsonb), public.rmoney_record(jsonb), public.rmoney_void(jsonb),
  public.rmoney_register(jsonb), public.rmoney_close_day(jsonb), public.rmoney_dues(jsonb), public.rmoney_contacts_list(jsonb), public.rmoney_contact_save(jsonb) to authenticated;
