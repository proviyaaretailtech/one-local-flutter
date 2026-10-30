-- 0636: Restaurant reports V1 (founder, 30 Oct 2026, from "Vini POS Mini Restaurant Reporting Blueprint"): Sales summary, Item-wise sales,
-- Category-wise sales, Payment mode, Cashier & day closing, Discounts and the Leakage audit. Read-only: nothing is written, no existing
-- function or table changes.
--
-- One set of definitions for every report (so the numbers agree with each other):
--   * a sale is a bill with status paid or delivered; its day is the day it was paid (paid_at, else created_at) in the business's time zone
--   * gross = Σ subtotal (dishes with their add-ons, before discount and tax; = Σ qty × unit price of its dishes that were not cancelled)
--   * discounts = Σ discount; net sales = gross − discounts; service charge, GST, round off and the bill total as on the bill
--   * refunds = pos_refunds made in the period; collected = payments taken in the period (a payment "due" is credit, not money)
--   * average bill = net sales ÷ completed bills
-- Who and where: the caller's business only (current_org_id via money_require), the outlets the person may see (money_scope); owners,
-- admins and managers (money:read). The leakage audit also needs pos_audit_log:read. Dates: from/to (YYYY-MM-DD), one day by default,
-- at most 366 days. Every list row carries the bill id, so the app opens the bill.

-- ---------------------------------------------------------------------------------------------------------------- the period and the outlets
create or replace function public.rst_rep__window(p jsonb, out d_from date, out d_to date, out t_from timestamptz, out t_to timestamptz,
                                                  out pt_from timestamptz, out pt_to timestamptz, out tz text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date;
begin
  tz := public.money_tz();
  v_today := (now() at time zone tz)::date;
  begin
    d_from := coalesce(nullif(p->>'from', '')::date, v_today);
    d_to := coalesce(nullif(p->>'to', '')::date, d_from);
  exception when others then raise exception 'MONEY_BAD_REQUEST: choose the dates again';
  end;
  if d_to < d_from then raise exception 'MONEY_BAD_REQUEST: the end date is before the start date'; end if;
  if d_to - d_from > 365 then raise exception 'MONEY_BAD_REQUEST: choose at most one year'; end if;
  t_from := d_from::timestamp at time zone tz;
  t_to := (d_to + 1)::timestamp at time zone tz;
  -- the same number of days just before, for comparisons
  pt_from := (d_from - (d_to - d_from + 1))::timestamp at time zone tz;
  pt_to := t_from;
end $$;
revoke all on function public.rst_rep__window(jsonb) from public, anon, authenticated;

-- the completed bills of the period in the chosen outlets ([p_all]: no outlet chosen, so bills without an outlet count too)
create or replace function public.rst_rep__sales(p_org uuid, p_locs uuid[], p_all boolean, p_from timestamptz, p_to timestamptz)
returns setof public.orders
language sql stable security definer set search_path = public, pg_temp as $$
  select o.* from public.orders o
   where o.organization_id = p_org and o.status in ('paid', 'delivered')
     and coalesce(o.paid_at, o.created_at) >= p_from and coalesce(o.paid_at, o.created_at) < p_to
     and (o.location_id = any (p_locs) or (o.location_id is null and p_all));
$$;
revoke all on function public.rst_rep__sales(uuid, uuid[], boolean, timestamptz, timestamptz) from public, anon, authenticated;

-- a bill as a list row
create or replace function public.rst_rep__bill(o public.orders, p_tz text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('order_id', o.id, 'bill', coalesce(o.display_no, o.order_no::text), 'at', coalesce(o.paid_at, o.created_at),
    'day', (coalesce(o.paid_at, o.created_at) at time zone p_tz)::date, 'channel', o.channel, 'status', o.status,
    'table', (select t.label from public.dining_tables t where t.id = o.table_id), 'customer', nullif(o.customer_name, ''),
    'gross_minor', o.subtotal_minor, 'discount_minor', o.discount_minor, 'total_minor', o.total_minor,
    'cashier', coalesce(public.money_person(o.organization_id, (select x.created_by from public.payments x where x.order_id = o.id order by x.created_at limit 1)),
                        public.money_person(o.organization_id, o.created_by)));
$$;
revoke all on function public.rst_rep__bill(public.orders, text) from public, anon, authenticated;

-- the money figures of a set of bills
create or replace function public.rst_rep__totals(p_org uuid, p_locs uuid[], p_all boolean, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'bills', count(*), 'guests', coalesce(sum(o.guest_count), 0),
    'gross_minor', coalesce(sum(o.subtotal_minor), 0), 'discount_minor', coalesce(sum(o.discount_minor), 0),
    'net_minor', coalesce(sum(o.subtotal_minor - o.discount_minor), 0),
    'service_charge_minor', coalesce(sum(o.service_charge_minor), 0), 'gst_minor', coalesce(sum(o.gst_amount_minor), 0),
    'round_off_minor', coalesce(sum(o.round_off_minor), 0), 'total_minor', coalesce(sum(o.total_minor), 0),
    'average_minor', case when count(*) = 0 then 0 else round(sum(o.subtotal_minor - o.discount_minor)::numeric / count(*)) end)
  from public.rst_rep__sales(p_org, p_locs, p_all, p_from, p_to) o;
$$;
revoke all on function public.rst_rep__totals(uuid, uuid[], boolean, timestamptz, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------- 1. sales summary
create or replace function public.rst_report_sales(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
  v_now jsonb; v_prev jsonb; v_ref bigint; v_refn int; v_col bigint; v_cancel jsonb;
begin
  select * into w from public.rst_rep__window(p);
  v_now := public.rst_rep__totals(v_org, v_locs, v_all, w.t_from, w.t_to);
  v_prev := public.rst_rep__totals(v_org, v_locs, v_all, w.pt_from, w.pt_to);
  select coalesce(sum(r.amount_minor), 0), count(*) into v_ref, v_refn from public.pos_refunds r left join public.orders o on o.id = r.order_id
   where r.organization_id = v_org and r.created_at >= w.t_from and r.created_at < w.t_to
     and (coalesce(r.location_id, o.location_id) = any (v_locs) or (coalesce(r.location_id, o.location_id) is null and v_all));
  select coalesce(sum(x.amount_minor), 0) into v_col from public.payments x join public.orders o on o.id = x.order_id
   where x.organization_id = v_org and x.method <> 'due' and x.created_at >= w.t_from and x.created_at < w.t_to
     and (o.location_id = any (v_locs) or (o.location_id is null and v_all));
  select jsonb_build_object('bills', count(*), 'value_minor', coalesce(sum((select coalesce(sum(round(i.unit_price * i.qty * 100)), 0) from public.order_items i where i.order_id = o.id)), 0))
    into v_cancel from public.orders o
   where o.organization_id = v_org and o.status = 'cancelled' and o.updated_at >= w.t_from and o.updated_at < w.t_to
     and (o.location_id = any (v_locs) or (o.location_id is null and v_all));
  return jsonb_build_object('from', w.d_from, 'to', w.d_to,
    'totals', v_now || jsonb_build_object('refunds_minor', v_ref, 'refunds', v_refn, 'net_after_refunds_minor', (v_now->>'net_minor')::bigint - v_ref,
                                          'collected_minor', v_col),
    'previous', v_prev,
    'cancelled', v_cancel,
    'days', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'bills', coalesce(s.bills, 0), 'net_minor', coalesce(s.net, 0)) order by d.day), '[]'::jsonb)
               from generate_series(w.d_from, w.d_to, interval '1 day') d(day)
               left join (select (coalesce(o.paid_at, o.created_at) at time zone w.tz)::date dy, count(*) bills, sum(o.subtotal_minor - o.discount_minor) net
                            from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o group by 1) s on s.dy = d.day::date),
    'bills', (select coalesce(jsonb_agg(public.rst_rep__bill(o, w.tz) order by coalesce(o.paid_at, o.created_at) desc), '[]'::jsonb)
                from (select * from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) order by coalesce(paid_at, created_at) desc limit 300) o),
    'bills_shown_max', 300);
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 2. item-wise sales
-- [menu_item_id] given: also the bills with that dish. Dishes on the menu that sold nothing are listed with 0 (the slowest).
create or replace function public.rst_report_items(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_item uuid; v_rows jsonb; v_total bigint;
begin
  select * into w from public.rst_rep__window(p);
  begin v_item := nullif(p->>'menu_item_id', '')::uuid; exception when others then raise exception 'MONEY_BAD_REQUEST: not a valid dish'; end;
  with sold as (
    select i.menu_item_id, i.name, nullif(i.variant_name, '') variant, sum(i.qty) qty, sum(round(i.unit_price * i.qty * 100)) revenue, count(distinct i.order_id) bills
      from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o join public.order_items i on i.order_id = o.id
     where i.status <> 'cancelled'
     group by 1, 2, 3),
  unsold as (
    select m.id menu_item_id, m.name, null::text variant, 0::numeric qty, 0::numeric revenue, 0::bigint bills from public.menu_items m
     where m.organization_id = v_org and coalesce(m.is_available, true) and not exists (select 1 from sold s where s.menu_item_id = m.id)),
  allr as (select * from sold union all select * from unsold)
  select coalesce(sum(revenue), 0) into v_total from sold;
  with sold as (
    select i.menu_item_id, i.name, nullif(i.variant_name, '') variant, sum(i.qty) qty, sum(round(i.unit_price * i.qty * 100)) revenue, count(distinct i.order_id) bills
      from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o join public.order_items i on i.order_id = o.id
     where i.status <> 'cancelled'
     group by 1, 2, 3),
  unsold as (
    select m.id menu_item_id, m.name, null::text variant, 0::numeric qty, 0::numeric revenue, 0::bigint bills from public.menu_items m
     where m.organization_id = v_org and coalesce(m.is_available, true) and not exists (select 1 from sold s where s.menu_item_id = m.id)),
  allr as (select * from sold union all select * from unsold)
  select coalesce(jsonb_agg(jsonb_build_object('menu_item_id', a.menu_item_id, 'name', a.name, 'variant', a.variant, 'qty', a.qty, 'revenue_minor', a.revenue,
           'bills', a.bills, 'share_pct', case when v_total = 0 then 0 else round(a.revenue * 100.0 / v_total, 1) end,
           'category', (select c.name from public.menu_items m join public.menu_categories c on c.id = m.category_id where m.id = a.menu_item_id))
         order by a.revenue desc, a.qty desc, a.name), '[]'::jsonb) into v_rows from allr a;
  return jsonb_build_object('from', w.d_from, 'to', w.d_to, 'total_minor', v_total,
    'qty', (select coalesce(sum((x->>'qty')::numeric), 0) from jsonb_array_elements(v_rows) x),
    'items', v_rows,
    'top', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(v_rows) x where (x->>'qty')::numeric > 0 limit 5) t),
    'slowest', (select coalesce(jsonb_agg(x order by (x->>'qty')::numeric, (x->>'revenue_minor')::numeric, x->>'name'), '[]'::jsonb)
                  from (select x from jsonb_array_elements(v_rows) x order by (x->>'qty')::numeric, (x->>'revenue_minor')::numeric, x->>'name' limit 5) t),
    'bills', case when v_item is null then null else
               (select coalesce(jsonb_agg(public.rst_rep__bill(o, w.tz) order by coalesce(o.paid_at, o.created_at) desc), '[]'::jsonb)
                  from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o
                 where exists (select 1 from public.order_items i where i.order_id = o.id and i.menu_item_id = v_item and i.status <> 'cancelled')) end);
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 3. category-wise sales
-- A sub-category counts under its main category; a dish without a category (or deleted since) is "Uncategorised". Names as they are now.
create or replace function public.rst_report_categories(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_total bigint; v_rows jsonb;
begin
  select * into w from public.rst_rep__window(p);
  with lines as (
    select i.menu_item_id, i.name, i.qty, round(i.unit_price * i.qty * 100) revenue, i.order_id,
           coalesce(top.id, c.id) cat_id, coalesce(top.name, c.name, 'Uncategorised') cat
      from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o
      join public.order_items i on i.order_id = o.id and i.status <> 'cancelled'
      left join public.menu_items m on m.id = i.menu_item_id and m.organization_id = v_org
      left join public.menu_categories c on c.id = m.category_id and c.organization_id = v_org
      left join public.menu_categories top on top.id = c.parent_id and top.organization_id = v_org),
  cats as (
    select cat_id, cat, sum(qty) qty, sum(revenue) revenue, count(distinct order_id) bills,
           (select jsonb_agg(jsonb_build_object('menu_item_id', d.menu_item_id, 'name', d.name, 'qty', d.qty, 'revenue_minor', d.revenue) order by d.revenue desc, d.name)
              from (select l2.menu_item_id, l2.name, sum(l2.qty) qty, sum(l2.revenue) revenue from lines l2
                     where l2.cat_id is not distinct from l.cat_id and l2.cat = l.cat group by 1, 2) d) dishes
      from lines l group by cat_id, cat)
  select coalesce(sum(revenue), 0), coalesce(jsonb_agg(jsonb_build_object('category_id', cat_id, 'name', cat, 'qty', qty, 'revenue_minor', revenue, 'bills', bills,
           'dishes', dishes) order by revenue desc, cat), '[]'::jsonb)
    into v_total, v_rows from cats;
  return jsonb_build_object('from', w.d_from, 'to', w.d_to, 'total_minor', v_total,
    'categories', (select coalesce(jsonb_agg(x || jsonb_build_object('share_pct', case when v_total = 0 then 0 else round((x->>'revenue_minor')::numeric * 100 / v_total, 1) end)), '[]'::jsonb)
                     from jsonb_array_elements(v_rows) x),
    -- categories on the menu that sold nothing in the period
    'unsold', (select coalesce(jsonb_agg(c.name order by c.sort_order, c.name), '[]'::jsonb) from public.menu_categories c
                where c.organization_id = v_org and c.parent_id is null
                  and not exists (select 1 from jsonb_array_elements(v_rows) x where (x->>'category_id')::uuid = c.id)));
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 4. payment mode
create or replace function public.rst_report_payments(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
  v_bills bigint; v_paid bigint; v_credit bigint;
begin
  select * into w from public.rst_rep__window(p);
  -- reconciliation: what the period's completed bills came to, against what was taken for those same bills
  select coalesce(sum(o.total_minor), 0),
         coalesce(sum((select coalesce(sum(x.amount_minor), 0) from public.payments x where x.order_id = o.id and x.method <> 'due')), 0),
         coalesce(sum((select coalesce(sum(x.amount_minor), 0) from public.payments x where x.order_id = o.id and x.method = 'due')), 0)
    into v_bills, v_paid, v_credit
    from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to) o;
  return (
    with pay as (
      select x.*, o.channel, o.display_no, o.id oid from public.payments x join public.orders o on o.id = x.order_id
       where x.organization_id = v_org and x.created_at >= w.t_from and x.created_at < w.t_to
         and (o.location_id = any (v_locs) or (o.location_id is null and v_all))),
    ref as (
      select r.* from public.pos_refunds r left join public.orders o on o.id = r.order_id
       where r.organization_id = v_org and r.created_at >= w.t_from and r.created_at < w.t_to
         and (coalesce(r.location_id, o.location_id) = any (v_locs) or (coalesce(r.location_id, o.location_id) is null and v_all)))
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'collected_minor', (select coalesce(sum(amount_minor), 0) from pay where method <> 'due'),
      'payments', (select count(*) from pay),
      'methods', (select coalesce(jsonb_agg(jsonb_build_object('method', m.method, 'amount_minor', m.amt, 'count', m.n,
                    'refunds_minor', coalesce((select sum(r.amount_minor) from ref r where r.method = m.method), 0)) order by m.amt desc), '[]'::jsonb)
                    from (select method, sum(amount_minor) amt, count(*) n from pay group by 1
                          union all select r.method, 0, 0 from ref r where not exists (select 1 from pay where pay.method = r.method) group by 1) m),
      'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel, 'amount_minor', c.amt, 'bills', c.n) order by c.amt desc), '[]'::jsonb)
                     from (select channel, sum(amount_minor) amt, count(distinct oid) n from pay where method <> 'due' group by 1) c),
      'split', (select jsonb_build_object('bills', count(*), 'amount_minor', coalesce(sum(s.amt), 0),
                  'list', coalesce(jsonb_agg(jsonb_build_object('order_id', s.oid, 'bill', s.display_no, 'methods', s.methods, 'amount_minor', s.amt) order by s.amt desc), '[]'::jsonb))
                  from (select oid, display_no, string_agg(distinct method, ' + ') methods, sum(amount_minor) amt from pay group by 1, 2 having count(distinct method) > 1) s),
      'refunds', (select jsonb_build_object('amount_minor', coalesce(sum(amount_minor), 0), 'count', count(*)) from ref),
      'reconcile', jsonb_build_object('bills_minor', v_bills, 'paid_minor', v_paid, 'on_credit_minor', v_credit,
                                      'difference_minor', v_bills - v_paid - v_credit)));
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 5. cashier & day closing
-- Per person who took the payment (payments.created_by), and the cash register of each day (rmoney_register: opening, cash sales,
-- refunds, paid out, expected, counted, short or extra). The restaurant closes by day; it has no shifts.
create or replace function public.rst_report_cashiers(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_days jsonb := '[]'::jsonb; d date; r jsonb;
begin
  select * into w from public.rst_rep__window(p);
  -- the register of each day, newest first (at most 62 days)
  d := w.d_to;
  while d >= w.d_from and d > w.d_to - 62 loop
    r := public.rmoney_register(jsonb_build_object('day', d, 'location_id', v_locs[1]));
    v_days := v_days || jsonb_build_array(jsonb_build_object('day', d, 'opening_minor', r->'opening_minor', 'cash_sales_minor', r->'cash_sales_minor',
      'other_in_minor', r->'other_in_minor', 'refunds_minor', r->'refunds_minor', 'paid_out_minor', r->'paid_out_minor', 'expected_minor', r->'expected_minor',
      'counted_minor', r->'closed'->'counted_minor', 'difference_minor', r->'closed'->'difference_minor', 'closed_by', r->'closed'->'by'));
    d := d - 1;
  end loop;
  return (
    with pay as (
      select x.* from public.payments x join public.orders o on o.id = x.order_id
       where x.organization_id = v_org and x.created_at >= w.t_from and x.created_at < w.t_to
         and (o.location_id = any (v_locs) or (o.location_id is null and v_all)))
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'cashiers', (select coalesce(jsonb_agg(jsonb_build_object('user_id', c.created_by, 'name', coalesce(public.money_person(v_org, c.created_by), 'Not recorded'),
                     'bills', c.bills, 'amount_minor', c.amt,
                     'methods', (select jsonb_object_agg(m.method, m.amt) from (select method, sum(amount_minor) amt from pay p2
                                  where p2.created_by is not distinct from c.created_by group by 1) m)) order by c.amt desc), '[]'::jsonb)
                     from (select created_by, count(distinct order_id) bills, sum(amount_minor) amt from pay group by 1) c),
      'days', v_days, 'days_shown_max', 62, 'outlet_id', v_locs[1]));
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 6. discounts
-- Coupon discounts and service charge waived, per bill with who did it (from the bill's events) and the reason; free dishes (₹0 lines
-- that are not a combo's dish). The POS records no manual discount and no approver; the answer says so.
create or replace function public.rst_report_discounts(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
begin
  select * into w from public.rst_rep__window(p);
  return (
    with b as (select * from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to)),
    disc as (
      select o.*, round(coalesce(o.service_charge_waived_amount, 0) * 100) waived_minor,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'coupon_applied' order by e.created_at desc limit 1) coupon_by,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'service_charge_waived' order by e.created_at desc limit 1) waive_by
        from b o where o.discount_minor > 0 or coalesce(o.service_charge_waived, false)),
    free as (
      select o.id oid, coalesce(o.display_no, o.order_no::text) bill, i.name, i.qty from b o join public.order_items i on i.order_id = o.id
       where i.status <> 'cancelled' and i.unit_price = 0 and coalesce(i.notes, '') not like 'Combo: %')
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'totals', jsonb_build_object(
        'discount_minor', (select coalesce(sum(discount_minor), 0) from disc), 'waived_minor', (select coalesce(sum(waived_minor), 0) from disc),
        'bills', (select count(*) from disc), 'all_bills', (select count(*) from b), 'gross_minor', (select coalesce(sum(subtotal_minor), 0) from b),
        'free_dishes', (select coalesce(sum(qty), 0) from free)),
      'coupons', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'bills', c.n, 'amount_minor', c.amt) order by c.amt desc), '[]'::jsonb)
                    from (select coupon_code code, count(*) n, sum(discount_minor) amt from disc where discount_minor > 0 group by 1) c),
      'bills', (select coalesce(jsonb_agg(jsonb_build_object('order_id', d.id, 'bill', coalesce(d.display_no, d.order_no::text), 'at', coalesce(d.paid_at, d.created_at),
                  'gross_minor', d.subtotal_minor, 'discount_minor', d.discount_minor, 'coupon', d.coupon_code,
                  'coupon_by', public.money_person(v_org, nullif(d.coupon_by, '')::uuid),
                  'waived_minor', d.waived_minor, 'waive_reason', nullif(d.waive_reason, ''), 'waived_by', public.money_person(v_org, nullif(d.waive_by, '')::uuid))
                  order by coalesce(d.paid_at, d.created_at) desc), '[]'::jsonb) from disc d),
      'free', (select coalesce(jsonb_agg(jsonb_build_object('order_id', f.oid, 'bill', f.bill, 'name', f.name, 'qty', f.qty)), '[]'::jsonb) from free f),
      'not_recorded', jsonb_build_array('manual_discount', 'approver')));
end $$;

-- ---------------------------------------------------------------------------------------------------------------- 7. leakage audit
-- Cancelled bills (value, kitchen tickets already sent, who and why), bills generated but not paid by the end of their day, reprints,
-- changes after the bill was generated, and refunds with their reason. Single-dish voids and price edits do not exist in the POS.
create or replace function public.rst_report_audit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
      select o.* from mine o where o.status = 'awaiting_payment' and o.created_at >= w.t_from and o.created_at < least(w.t_to, v_today_start)),
    ev as (
      select e.*, o.display_no, o.order_no from public.order_events e join mine o on o.id = e.order_id
       where e.created_at >= w.t_from and e.created_at < w.t_to),
    reprints as (select * from ev where kind like 'receipt\_%' or kind = 'kot_reprinted'),
    after_bill as (
      select * from ev where kind in ('items_added', 'coupon_applied', 'payment_cancelled', 'service_charge_waived', 'service_charge_restored', 'table_transferred')
         and exists (select 1 from public.order_events b where b.order_id = ev.order_id and b.kind = 'status_awaiting_payment' and b.created_at < ev.created_at)),
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
      'not_recorded', jsonb_build_array('item_void', 'price_edit')));
end $$;

revoke all on function public.rst_report_sales(jsonb), public.rst_report_items(jsonb), public.rst_report_categories(jsonb), public.rst_report_payments(jsonb),
  public.rst_report_cashiers(jsonb), public.rst_report_discounts(jsonb), public.rst_report_audit(jsonb) from public, anon;
grant execute on function public.rst_report_sales(jsonb), public.rst_report_items(jsonb), public.rst_report_categories(jsonb), public.rst_report_payments(jsonb),
  public.rst_report_cashiers(jsonb), public.rst_report_discounts(jsonb), public.rst_report_audit(jsonb) to authenticated, service_role;
