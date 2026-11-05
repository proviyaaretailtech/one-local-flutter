-- ==========================================================================================================================
-- HOSTED: 0653 Five restaurant fixes (3 Nov 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Restaurant functions only. (1) A bill refunded and then cancelled is not subtracted twice in Sales. (2) Item-wise and category-wise sales
-- add up to gross sales when menu prices include tax. (3) Cash entries, Day end and reopening are for the outlet chosen (several outlets).
-- (4) A discount code comes off when the bill falls below its minimum order. (5) Two cash-outs at the same moment are checked one by one.
-- ==========================================================================================================================
begin;
-- 0653: five restaurant fixes (founder, 3 Nov 2026: "A bill refunded and then cancelled may be subtracted twice in Sales. Item and category
-- revenue may not match gross sales when menu prices include tax. Close day with several outlets books everything into the first outlet.
-- A coupon's % stays fixed after more dishes are added. Two cash-outs at the same moment can both pass the drawer check").
--   1. rst_report_sales and rst_dashboard: a refund is taken off Sales only while its bill is still in Sales; a bill refunded and then
--      cancelled has already left Sales (its refunds stay in Cancellations & refunds).
--   2. rst_rep__lines: each bill's stored subtotal (before tax, before the discount: what gross sales adds up) shared over its dishes by
--      price, the last paisa on its largest line; rst_report_items and rst_report_categories use it, so they add up to gross sales also
--      when menu prices include tax.
--   3. rmoney__outlet: the outlet a cash entry, a Day end or a reopen is for: the one chosen (location_id), or the business's only outlet;
--      with several and none chosen it asks for one. rmoney_record, rmoney_close_day, rmoney_reopen_day and rmoney_register use it (the
--      register lists each outlet's day when none is chosen) instead of the first outlet.
--   4. tbl_order_reprice: a discount code whose minimum order the bill no longer reaches is taken off, and the bill says so (the % already
--      follows the dishes since 0644).
--   5. rmoney__cash_lock: cash out, a move out of cash, removing a cash entry, a cash refund or void (rst_adj__cash_left) and Day end take
--      the outlet's drawer lock before they check the drawer, so two at the same moment are checked one after the other.
-- Restaurant functions only. Safe to run again.

create or replace function public.rmoney__outlet(p_org uuid, p jsonb) returns uuid
  language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $f$
declare v_loc uuid := nullif(p->>'location_id', '')::uuid; v_ids uuid[];
begin
  if v_loc is not null then
    if not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = p_org) or not public.location_is_allowed(p_org, v_loc) then
      raise exception 'MONEY_NOT_FOUND: location not found'; end if;
    return v_loc;
  end if;
  select array_agg(l.id order by l.created_at) into v_ids from public.locations l
   where l.organization_id = p_org and l.status = 'active' and public.location_is_allowed(p_org, l.id);
  if coalesce(cardinality(v_ids), 0) = 0 then raise exception 'MONEY_NOT_FOUND: no outlet to record this in'; end if;
  if cardinality(v_ids) > 1 then raise exception 'MONEY_CHOOSE_OUTLET: choose the outlet at the top of the screen first'; end if;
  return v_ids[1];
end $f$;
revoke all on function public.rmoney__outlet(uuid, jsonb) from public, anon, authenticated;

create or replace function public.rmoney__cash_lock(p_loc uuid) returns void
  language sql volatile set search_path to 'public', 'pg_temp' as $f$
  select pg_advisory_xact_lock(hashtext('rmoney_cash:' || coalesce(p_loc::text, '-')));
$f$;
revoke all on function public.rmoney__cash_lock(uuid) from public, anon, authenticated;

create or replace function public.rst_rep__lines(p_org uuid, p_locs uuid[], p_all boolean, p_from timestamptz, p_to timestamptz)
  returns table (order_id uuid, line_id uuid, menu_item_id uuid, name text, variant text, qty numeric, revenue_minor bigint)
  language sql stable security definer set search_path to 'public', 'pg_temp' as $f$
  with l as (
    select o.id oid, o.subtotal_minor g, i.id lid, i.menu_item_id mid, i.name nm, nullif(i.variant_name, '') vr, i.qty q, i.unit_price * i.qty v
      from public.rst_rep__sales(p_org, p_locs, p_all, p_from, p_to) o join public.order_items i on i.order_id = o.id and i.status <> 'cancelled'),
  s as (
    select l.*, row_number() over (partition by oid order by v desc, lid) rn,
           case when sum(v) over (partition by oid) = 0 then 0 else floor(g * v / sum(v) over (partition by oid)) end base
      from l),
  t as (select s.*, sum(base) over (partition by oid) tb from s)
  select oid, lid, mid, nm, vr, q, (base + case when rn = 1 then g - tb else 0 end)::bigint from t;
$f$;
revoke all on function public.rst_rep__lines(uuid, uuid[], boolean, timestamptz, timestamptz) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rst_report_sales(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
  v_now jsonb; v_prev jsonb; v_ref bigint; v_refn int; v_col bigint; v_cancel jsonb;
begin
  select * into w from public.rst_rep__window(p);
  v_now := public.rst_rep__totals(v_org, v_locs, v_all, w.t_from, w.t_to);
  v_prev := public.rst_rep__totals(v_org, v_locs, v_all, w.pt_from, w.pt_to);
  select coalesce(sum(r.amount_minor), 0), count(*) into v_ref, v_refn from public.pos_refunds r left join public.orders o on o.id = r.order_id
   where r.organization_id = v_org and r.created_at >= w.t_from and r.created_at < w.t_to
     -- 0653: a bill refunded and then cancelled is already out of Sales; its refunds are not taken off again
     and (o.id is null or o.status <> 'cancelled')
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
end $function$;

CREATE OR REPLACE FUNCTION public.rst_dashboard(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_lname text; v_today date; v_from timestamptz; v_to timestamptz;
  v_kot jsonb; v_tables jsonb; v_low jsonb; v_sales numeric; v_refunds numeric; v_paid int; v_live int; v_total int; v_ol jsonb; v_last7 jsonb; v_domain text; v_new int; v_items jsonb; v_prev7 jsonb; v_open int;
  v_res jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'RST_FORBIDDEN: sign in to a business first'; end if;
  if not (public.has_permission(v_org, 'order', 'place') or public.has_permission(v_org, 'order', 'update_status') or public.has_permission(v_org, 'dining_tables', 'manage')) then
    raise exception 'RST_FORBIDDEN: your role cannot see the restaurant dashboard'; end if;
  if v_loc is null then
    select l.id into v_loc from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)
      order by (l.code = 'MAIN') desc, l.created_at limit 1;
  end if;
  select timezone, name into v_tz, v_lname from public.locations where id = v_loc and organization_id = v_org;
  if v_tz is null or not public.location_is_allowed(v_org, v_loc) then raise exception 'RST_NOT_FOUND: store not found'; end if;
  select business_domain into v_domain from public.organizations where id = v_org;
  v_today := (now() at time zone v_tz)::date;
  v_from := v_today::timestamp at time zone v_tz; v_to := (v_today + 1)::timestamp at time zone v_tz;

  -- kitchen display counts (null when the role may not see the kitchen)
  begin
    v_kot := public.kds_queue(jsonb_build_object('location_id', v_loc));
    v_kot := (v_kot->'counts') || jsonb_build_object('delayed', (v_kot->'stats'->>'delayed')::int, 'critical', coalesce((v_kot->'stats'->>'queue_critical')::int, 0));
  exception when others then v_kot := null; end;
  -- tables strip, same states as the floor (0404)
  begin
    select jsonb_build_object('all', count(*), 'available', count(*) filter (where s.status = 'available'), 'occupied', count(*) filter (where s.status = 'occupied'),
             'reserved', count(*) filter (where s.status = 'reserved'), 'cleaning', count(*) filter (where s.status = 'cleaning'))
      into v_tables from public.tbl_states(v_org, v_loc) s;
  exception when others then v_tables := null; end;
  -- ingredients below their reorder level (null when the role may not read stock)
  begin
    v_items := public.backoffice_low_stock(jsonb_build_object('location_id', v_loc));
    v_low := v_items->'counts';
    select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'unit', e->>'unit', 'available', e->'available', 'reorder_level', e->'reorder_level', 'level', e->>'level')), '[]'::jsonb)
      into v_items from (select e from jsonb_array_elements(v_items->'items') with ordinality t(e, i) order by i limit 3) x;
  exception when others then v_low := null; v_items := null; end;

  -- orders at this outlet (an order with no outlet belongs to the main one)
  with mine as (select o.* from public.orders o where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc)
  select count(*) filter (where public.tbl_order_open(m.status, m.paid_at)), count(*) filter (where public.tbl_order_open(m.status, m.paid_at) and m.status = 'new'),
         count(*) filter (where m.created_at >= v_from and m.created_at < v_to and m.status <> 'cancelled')
    into v_live, v_new, v_total from mine m;
  with mine as (select o.id, o.total, coalesce(o.paid_at, o.updated_at) at from public.orders o
                 where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null)))
  select coalesce(sum(m.total) filter (where m.at >= v_from and m.at < v_to), 0), count(*) filter (where m.at >= v_from and m.at < v_to) into v_sales, v_paid from mine m;
  select coalesce(sum(r.amount), 0) into v_refunds from public.pos_refunds r join public.orders o on o.id = r.order_id
   where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and r.created_at >= v_from and r.created_at < v_to
     and o.status <> 'cancelled'; -- 0653: a cancelled bill is already out of the day's sales

  -- One Local online orders: the record has a business but no outlet, so these are business-wide
  select jsonb_build_object('scope', 'business', 'today', count(*) filter (where c.created_at >= v_from and c.created_at < v_to and c.status <> 'cancelled'),
           'open', count(*) filter (where c.status not in ('delivered', 'cancelled')),
           'sales_today', coalesce(sum(c.total) filter (where c.created_at >= v_from and c.created_at < v_to and c.status <> 'cancelled'), 0))
    into v_ol from public.ol_orders c where c.organization_id = v_org;

  -- last 7 local days, oldest first, a day with nothing is zero
  select jsonb_agg(jsonb_build_object('date', d.dt, 'label', to_char(d.dt, 'Dy'), 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.n, 0)) order by d.dt) into v_last7
    from (select v_today - 6 + k as dt from generate_series(0, 6) k) d
    left join (select (coalesce(o.paid_at, o.updated_at) at time zone v_tz)::date as dt, sum(o.total) sales, count(*) n from public.orders o
                where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
                  and coalesce(o.paid_at, o.updated_at) >= (v_today - 6)::timestamp at time zone v_tz group by 1) x on x.dt = d.dt;

  -- the 7 local days before those, for the % change (same rule as last7)
  select jsonb_build_object('sales', coalesce(sum(o.total), 0), 'orders', count(*)) into v_prev7 from public.orders o
   where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
     and coalesce(o.paid_at, o.updated_at) >= (v_today - 13)::timestamp at time zone v_tz and coalesce(o.paid_at, o.updated_at) < (v_today - 6)::timestamp at time zone v_tz;
  -- open = this outlet is taking One Local orders (outlet_channels, 0520); no row = not open
  select count(*) filter (where c.accepting) into v_open from public.outlet_channels c where c.location_id = v_loc;

  v_res := jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org), 'is_restaurant', v_domain = 'Restaurant',
    'location', jsonb_build_object('id', v_loc, 'name', v_lname),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'date', v_today, 'date_label', trim(to_char(v_today, 'FMDay, FMDD FMMonth YYYY')),
    'orders', jsonb_build_object('live', v_live, 'new', v_new, 'in_progress', v_live - v_new, 'today', v_total),
    'ingredients_items', v_items, 'prev7', v_prev7, 'channel', jsonb_build_object('open_outlets', v_open, 'outlets', 1),
    'kot', v_kot, 'tables', v_tables, 'ingredients_low', v_low,
    'sales', jsonb_build_object('today', v_sales - v_refunds, 'gross', v_sales, 'refunds', v_refunds, 'paid_bills', v_paid),
    'onelocal', v_ol, 'last7', v_last7,
    'not_reported', jsonb_build_array('complaints', 'reviews'));
  -- 0652: a kitchen or captain login (no money:read, no payment:record) gets no sales, payments or refunds
  if not public.rst__sees_money(v_org) then v_res := public.rst__strip_money(v_res) || jsonb_build_object('money_hidden', true); end if;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.rst_report_items(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_item uuid; v_rows jsonb; v_total bigint;
begin
  select * into w from public.rst_rep__window(p);
  begin v_item := nullif(p->>'menu_item_id', '')::uuid; exception when others then raise exception 'MONEY_BAD_REQUEST: not a valid dish'; end;
  with sold as (
    -- 0653: the bill's subtotal shared over its dishes (adds up to gross sales, also with prices that include tax)
    select i.menu_item_id, i.name, i.variant, sum(i.qty) qty, sum(i.revenue_minor) revenue, count(distinct i.order_id) bills
      from public.rst_rep__lines(v_org, v_locs, v_all, w.t_from, w.t_to) i
     group by 1, 2, 3),
  unsold as (
    select m.id menu_item_id, m.name, null::text variant, 0::numeric qty, 0::numeric revenue, 0::bigint bills from public.menu_items m
     where m.organization_id = v_org and coalesce(m.is_available, true) and not exists (select 1 from sold s where s.menu_item_id = m.id)),
  allr as (select * from sold union all select * from unsold)
  select coalesce(sum(revenue), 0) into v_total from sold;
  with sold as (
    -- 0653: the bill's subtotal shared over its dishes (adds up to gross sales, also with prices that include tax)
    select i.menu_item_id, i.name, i.variant, sum(i.qty) qty, sum(i.revenue_minor) revenue, count(distinct i.order_id) bills
      from public.rst_rep__lines(v_org, v_locs, v_all, w.t_from, w.t_to) i
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
end $function$;

CREATE OR REPLACE FUNCTION public.rst_report_categories(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_total bigint; v_rows jsonb;
begin
  select * into w from public.rst_rep__window(p);
  with lines as (
    -- 0653: the bill's subtotal shared over its dishes (adds up to gross sales, also with prices that include tax)
    select i.menu_item_id, i.name, i.qty, i.revenue_minor revenue, i.order_id,
           coalesce(top.id, c.id) cat_id, coalesce(top.name, c.name, 'Uncategorised') cat
      from public.rst_rep__lines(v_org, v_locs, v_all, w.t_from, w.t_to) i
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
end $function$;

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
  v_locs := array[public.rmoney__outlet(v_org, p)]; -- 0653: one outlet (the one chosen, or the only one)
  perform public.rmoney__cash_lock(v_locs[1]); -- 0653: one cash entry at a time per drawer
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
  v_locs := array[public.rmoney__outlet(v_org, p)]; -- 0653: one outlet (the one chosen, or the only one)
  perform public.rmoney__cash_lock(v_locs[1]); -- 0653: no cash entry slips in while the day is counted
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

CREATE OR REPLACE FUNCTION public.rmoney_reopen_day(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'approve'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  c public.rmoney_day_closes%rowtype;
begin
  v_locs := array[public.rmoney__outlet(v_org, p)]; -- 0653: one outlet (the one chosen, or the only one)
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
end $function$;

CREATE OR REPLACE FUNCTION public.rmoney_register(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); r record; c public.rmoney_day_closes;
begin
  -- 0653: several outlets and none chosen: each outlet's day, to choose one (its drawer, its Day end)
  if nullif(p->>'location_id', '') is null and (select count(*) from public.locations l where l.organization_id = v_org and l.status = 'active'
                                                   and public.location_is_allowed(v_org, l.id)) > 1 then
    return jsonb_build_object('day', v_day, 'choose_outlet', true, 'can_close', false,
      'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name,
                    'ended', exists (select 1 from public.rmoney_day_closes dc where dc.organization_id = v_org and dc.location_id = l.id and dc.day = v_day),
                    'open_bills', (public.rmoney__open_bills(v_org, array[l.id])->>'count')::int) order by l.created_at), '[]'::jsonb)
                    from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)));
  end if;
  v_locs := array[public.rmoney__outlet(v_org, p)];
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
    -- 0653: which outlet this drawer is, and whether there are others to switch to
    'location_name', (select l.name from public.locations l where l.id = v_locs[1]),
    'outlet_count', (select count(*) from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
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
  perform public.rmoney__cash_lock(e.location_id); -- 0653: one cash change at a time per drawer
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

CREATE OR REPLACE FUNCTION public.rst_adj__cash_left(o orders, p_amount numeric, p_method text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_cash bigint;
begin
  if p_method is distinct from 'cash' or coalesce(p_amount, 0) <= 0 then return; end if;
  perform public.rmoney__cash_lock(o.location_id); -- 0653: two cash refunds at the same moment are checked one after the other
  v_cash := public.rmoney_cash_now(o.organization_id, array[o.location_id]);
  if round(p_amount * 100) > v_cash then
    raise exception 'POS_NOT_ENOUGH_CASH: only % is in the cash drawer; give it back by UPI or card, or add cash to the drawer first',
      public.notice_money(greatest(v_cash, 0) / 100.0, 'INR');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.tbl_order_reprice(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; v_sub numeric(10,2); v_disc numeric(10,2); v_cap numeric; t jsonb; v_min numeric;
begin
  select * into o from public.orders where id = p_order;
  select coalesce(sum(i.unit_price * i.qty), 0) into v_sub from public.order_items i where i.order_id = p_order and i.status <> 'cancelled';
  if o.discount_pct is not null then
    v_disc := round(v_sub * o.discount_pct / 100, 2);
    if o.coupon_code is not null then
      select c.max_discount into v_cap from public.sell_coupons c where c.organization_id = o.organization_id and upper(c.code) = upper(o.coupon_code) limit 1;
      if v_cap is not null then v_disc := least(v_disc, v_cap); end if;
    end if;
  else
    v_disc := coalesce(o.discount, 0);
  end if;
  v_disc := least(v_disc, v_sub);
  -- 0653: a discount code whose minimum order the bill no longer reaches comes off, and the bill says so
  if o.coupon_code is not null then
    select c.min_order into v_min from public.sell_coupons c where c.organization_id = o.organization_id and upper(c.code) = upper(o.coupon_code) limit 1;
    if v_min is not null and v_sub < v_min then
      v_disc := 0;
      update public.orders set coupon_code = null, discount_pct = null where id = p_order;
      insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
      values (o.organization_id, o.id, 'coupon_removed', 'Discount code ' || o.coupon_code || ' taken off: the bill is below its minimum of '
              || trim(to_char(v_min, 'FM9999990.00')), 'pos', jsonb_build_object('code', o.coupon_code, 'min_order', v_min, 'subtotal', v_sub));
    end if;
  end if;
  t := public.pos_tax_bill(o.organization_id, v_sub, v_disc, o.service_charge_waived);
  update public.orders set subtotal = (t->>'subtotal')::numeric, discount = v_disc, gst_pct = (t->>'gst_pct')::numeric, gst_amount = (t->>'gst_amount')::numeric,
         service_charge = (t->>'service_charge')::numeric, service_charge_gst = (t->>'service_charge_gst')::numeric,
         service_charge_waived_amount = case when o.service_charge_waived then (t->>'service_charge_full')::numeric else service_charge_waived_amount end,
         round_off = (t->>'round_off')::numeric, total = (t->>'total')::numeric, updated_at = now()
   where id = p_order;
end $function$;

notify pgrst, 'reload schema';
commit;
