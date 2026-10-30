-- 0606: takeaway dishes on a dine-in bill (founder, 27 Oct 2026). Guests eating at a table may also ask for some dishes to take away:
-- those go on the SAME table order (one bill) and each such line is marked takeaway, so the bill, the table's order and the kitchen
-- card say "Takeaway" (the kitchen packs it).
--   * order_items.is_takeaway (default false).
--   * tbl_order_add: a line may carry "takeaway": true. The lines of this call are marked after they are inserted (one row per line,
--     matched on dish and quantity among the rows this call added). Everything else is unchanged.
--   * tbl_order_view, rst_bill_order_json, kds_card_json, pos_order_view: each item also answers "takeaway".
-- The functions below are the live definitions with only those additions. Safe to run again.

begin;

alter table public.order_items add column if not exists is_takeaway boolean not null default false;

CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course)
    select o.id, mi.id, mi.name, (l->>'qty')::int, mi.price, nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat')
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org;
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.tbl_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
                'notes', i.notes) order by o.created_at, i.created_at, i.id), '[]'::jsonb)
                from public.order_items i join public.orders o on o.id = i.order_id
               where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) and i.status <> 'cancelled'),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at', e.created_at, 'message', e.message) order by e.created_at, e.id), '[]'::jsonb)
                   from (select ev.* from public.order_events ev join public.orders o on o.id = ev.order_id
                          where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by ev.created_at desc limit 30) e),
    'subtotal', (select coalesce(sum(o.subtotal), 0) from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'can', jsonb_build_object('add_items', v_place and (v_st is null or v_st in ('new', 'in_billing', 'sent_to_kitchen', 'ready')),
                              'send_kot', (v_update or v_place) and v_held, 'print_kot', false, 'change_table', v_manage and v_st is not null and (mg is null),
                              'merge_table', v_manage and v_st is not null and (mg is null), 'generate_bill', v_update and v_bill),
    'unavailable', jsonb_build_object('print_kot', 'Printing a KOT is not in this release.'));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone,
    'bill_generated', o.status = 'awaiting_payment',
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price,
                'line_total', i.unit_price * i.qty) order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'at', y.created_at,
                   'tendered', (select t.tendered from public.pos_cash_tenders t where t.payment_id = y.id)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'split', (select public.rst_split_json(s.id) from public.rst_bill_splits s where s.order_id = o.id and s.status in ('active', 'completed')
               order by s.created_at desc limit 1))
  from public.orders o where o.id = p_order;
$function$

;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$function$

;

CREATE OR REPLACE FUNCTION public.pos_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_res jsonb;
begin
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id()
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(v_o) - 'external_ref' - 'idempotency_key' - 'created_by',
    'table_label', (select t.label from public.dining_tables t where t.id = v_o.table_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty,
                'unit_price', i.unit_price, 'status', i.status, 'picked_qty', l.picked_qty, 'missing_qty', l.missing_qty) order by i.created_at, i.id), '[]'::jsonb)
              from public.order_items i left join public.pos_fulfilment_lines l on l.order_item_id = i.id where i.order_id = v_o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', y.method, 'amount', y.amount, 'tendered', c.tendered, 'created_at', y.created_at) order by y.created_at), '[]'::jsonb)
                 from public.payments y left join public.pos_cash_tenders c on c.payment_id = y.id where y.order_id = v_o.id),
    'paid', (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id),
    'fulfilment', (select to_jsonb(f) - 'organization_id' from public.pos_fulfilments f where f.order_id = v_o.id),
    'next_events', (select coalesce(jsonb_agg(t.event order by t.event), '[]'::jsonb) from public.order_transitions t join public.pos_fulfilments f on f.order_id = v_o.id
                    where t.entity = 'pos_fulfilments' and t.from_status = f.stage and t.event <> 'cancel'),
    'online', (select jsonb_build_object('id', x.id, 'status', x.status, 'payment_method', x.payment_method, 'payment_status', x.payment_status,
                 'address', x.delivery_address, 'cancel_reason', x.cancel_reason, 'rider_name', x.rider_name, 'eta_minutes', x.eta_minutes)
               from public.ol_orders x where x.pos_order_id = v_o.id limit 1),
    'refunded', (select coalesce(sum(r.amount), 0) from public.ol_refunds r join public.ol_orders x on x.id = r.order_id where x.pos_order_id = v_o.id and r.status = 'processed'),
    'cancel_reason', (select e.meta->>'reason' from public.order_events e where e.order_id = v_o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

;

commit;
