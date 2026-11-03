-- ==========================================================================================================================
-- HOSTED: 0640 Cancel a dish / KOT item, refund and void a restaurant bill (2 Nov 2026), PART 2 of 2. Run after 23a.
-- One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Part 2: payment details (rst_order_adjust), the Cancellations & refunds report, the kitchen alert for item cancels (kds_cancelled),
-- the table order view and the KOT view showing cancelled dishes.
-- ==========================================================================================================================
begin;
-- ---------------------------------------------------------------- one order: payment details, refunds, cancelled items, requests

create or replace function public.rst_adj__view(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'channel', o.channel, 'paid_at', o.paid_at,
    'table_label', (select t.label from public.dining_tables t where t.id = o.table_id),
    'subtotal', o.subtotal, 'discount', o.discount, 'gst_amount', o.gst_amount, 'service_charge', o.service_charge, 'round_off', o.round_off,
    'money', public.rst_adj__money(o.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'variant', i.variant_name, 'unit_price', i.unit_price,
                'qty', case when i.status = 'cancelled' then 0 else i.qty end, 'cancelled_qty', i.cancelled_qty,
                'ordered_qty', case when i.status = 'cancelled' then i.cancelled_qty else i.qty + i.cancelled_qty end,
                'status', i.status, 'sent', i.kot_ticket_id is not null, 'kot_no', k.kot_no, 'kot_status', k.status,
                'needs_manager', i.status in ('preparing', 'ready', 'delivered') or o.status = 'awaiting_payment') order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i left join public.kot_tickets k on k.id = i.kot_ticket_id where i.order_id = o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'reference', y.reference, 'at', y.created_at,
                   'by', public.money_person(o.organization_id, y.created_by)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'refunds', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'amount', r.amount, 'method', r.method, 'kind', r.kind, 'reason', r.reason,
                  'reference', r.idempotency_key, 'at', r.created_at, 'by', public.money_person(o.organization_id, r.created_by),
                  'asked_by', (select public.money_person(o.organization_id, (a.meta->>'asked_by')::uuid) from public.order_events a
                                where a.order_id = o.id and a.kind = 'adjust_approved' and 'request:' || (a.meta->>'request_id') in (r.idempotency_key, substr(r.idempotency_key, 6)) limit 1))
                  order by r.created_at, r.id), '[]'::jsonb)
                  from public.pos_refunds r where r.order_id = o.id),
    'cancelled_items', (select coalesce(jsonb_agg(jsonb_build_object('item_id', e.meta->>'item_id', 'name', e.meta->>'name', 'variant', e.meta->>'variant',
                          'qty', (e.meta->>'qty')::int, 'value', (e.meta->>'value')::numeric, 'kot_no', e.meta->>'kot_no', 'was', e.meta->>'item_status',
                          'reason', e.meta->>'reason', 'at', e.created_at, 'by', public.money_person(o.organization_id, (e.meta->>'by')::uuid),
                          'approved_by', case when e.meta->>'approved_by' is not null then public.money_person(o.organization_id, (e.meta->>'approved_by')::uuid) end)
                          order by e.created_at, e.id), '[]'::jsonb)
                          from public.order_events e where e.order_id = o.id and e.kind = 'item_cancelled'),
    'void', (select jsonb_build_object('reason', e.meta->>'reason', 'at', e.created_at, 'by', public.money_person(o.organization_id, (e.meta->>'by')::uuid),
               'approved_by', case when e.meta->>'approved_by' is not null then public.money_person(o.organization_id, (e.meta->>'approved_by')::uuid) end,
               'refunded', (e.meta->>'refund_amount')::numeric)
               from public.order_events e where e.order_id = o.id and e.kind = 'bill_voided' order by e.created_at desc limit 1),
    'requests', (select coalesce(jsonb_agg(public.rst_adj__request_json(r) order by r.created_at desc), '[]'::jsonb) from public.rst_adj__open_requests(o.id) r),
    'can', jsonb_build_object(
      'cancel_items', o.status not in ('paid', 'cancelled') and o.paid_at is null and o.channel not in ('online', 'swiggy', 'zomato')
                      and not exists (select 1 from public.payments y where y.order_id = o.id)
                      and (public.has_permission(o.organization_id, 'order', 'update_status', o.location_id) or public.has_permission(o.organization_id, 'order', 'place', o.location_id)),
      'refund', o.status <> 'cancelled' and o.channel <> 'online' and (public.rst_adj__mgr() or public.rst_can_pay())
                and (public.rst_adj__money(o.id)->>'refundable')::numeric > 0,
      'void', o.status <> 'cancelled' and o.channel not in ('online', 'swiggy', 'zomato') and (public.rst_adj__mgr() or public.rst_can_pay()),
      'is_manager', public.rst_adj__mgr(), 'is_owner', public.rst_adj__owner()),
    'unavailable', jsonb_build_object(
      'cancel_items', case when o.status = 'cancelled' then 'This order is cancelled.'
                           when o.status = 'paid' or o.paid_at is not null or exists (select 1 from public.payments y where y.order_id = o.id) then 'Money was taken on this bill; give a refund instead.'
                           when o.channel in ('online', 'swiggy', 'zomato') then 'App and aggregator orders are changed on their own platform.' end,
      'refund', case when o.status = 'cancelled' then 'This bill is void.' when o.channel = 'online' then 'Online orders are refunded through the online refund flow.'
                     when (public.rst_adj__money(o.id)->>'paid')::numeric <= 0 then 'No money was taken on this bill.'
                     when (public.rst_adj__money(o.id)->>'refundable')::numeric <= 0 then 'Everything paid on this bill was already refunded.'
                     when not (public.rst_adj__mgr() or public.rst_can_pay()) then 'Your role cannot refund bills.' end,
      'void', case when o.status = 'cancelled' then 'This bill is already void.' when not (public.rst_adj__mgr() or public.rst_can_pay()) then 'Your role cannot void bills.' end))
  from public.orders o where o.id = p_order;
$$;
revoke all on function public.rst_adj__view(uuid) from public, anon, authenticated;

create or replace function public.rst_order_adjust(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_o public.orders%rowtype; v_id uuid;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  begin v_id := nullif(p->>'order_id', '')::uuid; exception when others then raise exception 'POS_BAD_REQUEST: not a valid order'; end;
  select * into v_o from public.orders where id = v_id;
  if not found or v_o.organization_id is distinct from public.current_org_id() or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then
    raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not (public.rst_adj__mgr() or public.rst_can_pay() or public.has_permission(v_o.organization_id, 'order', 'update_status', v_o.location_id)
          or public.has_permission(v_o.organization_id, 'order', 'place', v_o.location_id)) then
    raise exception 'POS_FORBIDDEN: your role cannot see this bill'; end if;
  return public.rst_adj__view(v_id);
end $$;

-- ---------------------------------------------------------------- report

-- Cancellations and refunds between two days ({from, to, location_id}): dishes cancelled (sent to the kitchen or not), bills voided, refunds
create or replace function public.rst_report_cancellations(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
begin
  select * into w from public.rst_rep__window(p);
  return (
    with mine as (select o.* from public.orders o where o.organization_id = v_org and (o.location_id = any (v_locs) or (o.location_id is null and v_all))),
    items as (select e.*, o.display_no from public.order_events e join mine o on o.id = e.order_id
               where e.kind = 'item_cancelled' and e.created_at >= w.t_from and e.created_at < w.t_to),
    voids as (select e.*, o.display_no from public.order_events e join mine o on o.id = e.order_id
               where e.kind = 'bill_voided' and e.created_at >= w.t_from and e.created_at < w.t_to),
    refunds as (select r.*, o.display_no from public.pos_refunds r join mine o on o.id = r.order_id where r.created_at >= w.t_from and r.created_at < w.t_to),
    asks as (select e.* from public.order_events e join mine o on o.id = e.order_id
              where e.kind in ('adjust_requested', 'adjust_rejected') and e.created_at >= w.t_from and e.created_at < w.t_to)
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'items', jsonb_build_object('count', (select coalesce(sum((meta->>'qty')::int), 0) from items),
                 'value_minor', (select coalesce(sum(round((meta->>'value')::numeric * 100)), 0) from items),
                 'after_kot', (select coalesce(sum((meta->>'qty')::int), 0) from items where (meta->>'sent')::boolean),
                 'list', (select coalesce(jsonb_agg(jsonb_build_object('display_no', i.display_no, 'order_id', i.order_id, 'name', i.meta->>'name', 'qty', (i.meta->>'qty')::int,
                            'value', (i.meta->>'value')::numeric, 'kot_no', i.meta->>'kot_no', 'was', i.meta->>'item_status', 'reason', i.meta->>'reason', 'at', i.created_at,
                            'by', public.money_person(v_org, (i.meta->>'by')::uuid),
                            'approved_by', case when i.meta->>'approved_by' is not null then public.money_person(v_org, (i.meta->>'approved_by')::uuid) end)
                            order by i.created_at desc), '[]'::jsonb) from items i)),
      'voids', jsonb_build_object('count', (select count(*) from voids), 'value_minor', (select coalesce(sum(round((meta->>'total')::numeric * 100)), 0) from voids),
                 'list', (select coalesce(jsonb_agg(jsonb_build_object('display_no', v.display_no, 'order_id', v.order_id, 'total', (v.meta->>'total')::numeric,
                            'refunded', (v.meta->>'refund_amount')::numeric, 'reason', v.meta->>'reason', 'at', v.created_at,
                            'by', public.money_person(v_org, (v.meta->>'by')::uuid),
                            'approved_by', case when v.meta->>'approved_by' is not null then public.money_person(v_org, (v.meta->>'approved_by')::uuid) end)
                            order by v.created_at desc), '[]'::jsonb) from voids v)),
      'refunds', jsonb_build_object('count', (select count(*) from refunds), 'amount_minor', (select coalesce(sum(amount_minor), 0) from refunds),
                 'list', (select coalesce(jsonb_agg(jsonb_build_object('display_no', r.display_no, 'order_id', r.order_id, 'amount', r.amount, 'method', r.method,
                            'kind', r.kind, 'reason', r.reason, 'at', r.created_at, 'by', public.money_person(v_org, r.created_by)) order by r.created_at desc), '[]'::jsonb) from refunds r)),
      'requests', jsonb_build_object('asked', (select count(*) from asks where kind = 'adjust_requested'), 'rejected', (select count(*) from asks where kind = 'adjust_rejected'))));
end $$;

-- ---------------------------------------------------------------- the kitchen hears an item cancel

-- 0621's cancelled orders, plus dishes cancelled after their KOT went (each with alert_id, so the alarm sounds once per cancel)
create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) from (
    select o.updated_at as at, jsonb_build_object(
             'alert_id', o.id, 'partial', false,
             'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
             'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
             'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
             'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                         from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
           || public.order_cancel_info(o.id) as j
      from public.orders o
     where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
       and (p_loc is null or o.location_id = p_loc)
       and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    union all
    select e.created_at, jsonb_build_object(
             'alert_id', 'item:' || e.id, 'partial', true,
             'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', e.created_at,
             'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
             'kots', jsonb_build_array((e.meta->>'kot_no')::bigint),
             'items', jsonb_build_array(jsonb_build_object('name', e.meta->>'name', 'qty', (e.meta->>'qty')::int, 'variant', e.meta->>'variant')),
             'by', coalesce(public.money_person(o.organization_id, (e.meta->>'by')::uuid), 'Restaurant'), 'reason', e.meta->>'reason')
      from public.order_events e join public.orders o on o.id = e.order_id
     where e.organization_id = p_org and e.kind = 'item_cancelled' and (e.meta->>'sent')::boolean and e.created_at > now() - interval '60 minutes'
       and o.status <> 'cancelled' and (p_loc is null or o.location_id = p_loc)) x;
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

-- ---------------------------------------------------------------- grants

do $$ declare f text; begin
  foreach f in array array['rst_items_cancel(jsonb)', 'rst_bill_refund(jsonb)', 'rst_bill_void(jsonb)', 'rst_requests_list(jsonb)',
                           'rst_request_decide(jsonb)', 'rst_order_adjust(jsonb)', 'rst_report_cancellations(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- order detail and KOT view show item cancels

-- tbl_order_view (0606): each line's KOT, what was cancelled of it and whether a manager decides; the table's cancelled dishes; can.cancel_items
CREATE OR REPLACE FUNCTION public.tbl_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype; mg jsonb; v_main uuid; v_grp uuid[]; v_st text; v_area text;
  v_update boolean; v_manage boolean; v_held boolean; v_bill boolean; v_place boolean;
begin
  t := public.tbl_get(v_org, v_loc, (p->>'table_id')::uuid);
  mg := public.tbl_merge_json(v_org, t.id);
  v_main := coalesce((mg->>'primary_table_id')::uuid, t.id);
  v_grp := public.tbl_group(v_org, t.id);
  select a.name into v_area from public.dining_areas a where a.id = t.area_id;
  v_update := public.has_permission(v_org, 'order', 'update_status', v_loc);
  v_place := public.has_permission(v_org, 'order', 'place', v_loc);
  v_manage := public.tbl_can_manage(v_org, v_loc);
  select o.status into v_st from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by o.created_at desc limit 1;
  -- 0485: dishes held (not yet sent) on an order the kitchen can still take
  select exists (select 1 from public.orders o join public.order_items i on i.order_id = o.id where o.organization_id = v_org and o.table_id = any(v_grp)
                  and o.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready') and i.kot_ticket_id is null and i.status = 'pending') into v_held;
  select exists (select 1 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and o.status in ('in_billing', 'sent_to_kitchen', 'ready', 'delivered') and public.tbl_order_open(o.status, o.paid_at)) into v_bill;
  return jsonb_build_object('table', jsonb_build_object('id', t.id, 'label', t.label, 'seats', coalesce((mg->>'combined_seats')::int, t.seats), 'area_name', v_area, 'main_table_id', v_main),
    'status', case when v_st is null then null else jsonb_build_object('key', v_st, 'label', case v_st
        when 'sent_to_kitchen' then 'ACTIVE IN KITCHEN' when 'new' then 'NOT SENT TO KITCHEN' when 'in_billing' then 'NOT SENT TO KITCHEN'
        when 'ready' then 'READY TO SERVE' when 'delivered' then 'SERVED' when 'awaiting_payment' then 'AWAITING PAYMENT' else upper(v_st) end) end,
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'total', o.total, 'subtotal', o.subtotal) order by o.created_at), '[]'::jsonb)
                 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price, 'line_total', i.unit_price * i.qty,
                'status', i.status, 'sent', i.kot_ticket_id is not null,
                'status_label', case when i.kot_ticket_id is null and i.status = 'pending' then 'Not sent' else case i.status when 'pending' then 'Pending' when 'preparing' then 'Preparing' when 'ready' then 'Ready' when 'delivered' then 'Served' else initcap(i.status) end end,
                'notes', i.notes, 'order_id', o.id, 'cancelled_qty', i.cancelled_qty, 'kot_no', (select k.kot_no from public.kot_tickets k where k.id = i.kot_ticket_id),
                'needs_manager', i.status in ('preparing', 'ready', 'delivered') or o.status = 'awaiting_payment') order by o.created_at, i.created_at, i.id), '[]'::jsonb)
                from public.order_items i join public.orders o on o.id = i.order_id
               where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) and i.status <> 'cancelled'),
    'cancelled_items', (select coalesce(jsonb_agg(jsonb_build_object('order_id', e.order_id, 'item_id', e.meta->>'item_id', 'name', e.meta->>'name', 'variant', e.meta->>'variant',
                          'qty', (e.meta->>'qty')::int, 'kot_no', e.meta->>'kot_no', 'reason', e.meta->>'reason', 'at', e.created_at,
                          'by', public.money_person(v_org, (e.meta->>'by')::uuid)) order by e.created_at, e.id), '[]'::jsonb)
                          from public.order_events e join public.orders o on o.id = e.order_id
                         where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) and e.kind = 'item_cancelled'),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at', e.created_at, 'message', e.message) order by e.created_at, e.id), '[]'::jsonb)
                   from (select ev.* from public.order_events ev join public.orders o on o.id = ev.order_id
                          where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by ev.created_at desc limit 30) e),
    'subtotal', (select coalesce(sum(o.subtotal), 0) from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'can', jsonb_build_object('add_items', v_place and (v_st is null or v_st in ('new', 'in_billing', 'sent_to_kitchen', 'ready')),
                              'send_kot', (v_update or v_place) and v_held, 'print_kot', false, 'change_table', v_manage and v_st is not null and (mg is null),
                              'merge_table', v_manage and v_st is not null and (mg is null), 'generate_bill', v_update and v_bill,
                              'cancel_items', (v_update or v_place) and v_st is not null and v_st not in ('paid', 'cancelled')),
    'unavailable', jsonb_build_object('print_kot', 'Printing a KOT is not in this release.'));
end $$

;

-- rst_kot_orders (0621): each order's dishes cancelled after the KOT went, with how many, why and who (the KOT history)
CREATE OR REPLACE FUNCTION public.rst_kot_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_st text := coalesce(nullif(p->>'status', ''), 'all'); v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_st not in ('all', 'preparing', 'ready', 'completed', 'cancelled') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.updated_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             -- a cancelled order counts the dishes the kitchen had (all of them are cancelled now)
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status <> 'cancelled' or (o.status = 'cancelled' and i.kot_ticket_id is not null))) as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.status = 'cancelled' then 'cancelled'
                  when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage,
             o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes' as fresh_cancel
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed'),
                                   'cancelled', (select count(*) from s where stage = 'cancelled')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'cancel', case when s.stage = 'cancelled' then public.order_cancel_info(s.id) || jsonb_build_object('at', s.updated_at, 'recent', s.fresh_cancel) end,
          'dishes', case when s.stage = 'cancelled' then (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty) order by i.created_at), '[]')
                                                          from public.order_items i where i.order_id = s.id and i.kot_ticket_id is not null) end,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status <> 'cancelled' or s.stage = 'cancelled')),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1),
          'item_cancels', (select coalesce(jsonb_agg(jsonb_build_object('name', e.meta->>'name', 'variant', e.meta->>'variant', 'qty', (e.meta->>'qty')::int, 'kot_no', e.meta->>'kot_no',
                             'reason', e.meta->>'reason', 'at', e.created_at, 'by', public.money_person(v_org, (e.meta->>'by')::uuid),
                             'recent', e.created_at > now() - interval '60 minutes') order by e.created_at), '[]')
                             from public.order_events e where e.order_id = s.id and e.kind = 'item_cancelled' and (e.meta->>'sent')::boolean)
        ) order by case when s.fresh_cancel then -1 else case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 when 'completed' then 3 else 4 end end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$

;

notify pgrst, 'reload schema';
commit;
