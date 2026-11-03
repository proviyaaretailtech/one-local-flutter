-- 0643: a held takeaway or delivery order can be found and sent to the kitchen (founder, 3 Nov 2026: "A held takeaway or delivery order
-- gets stuck. The message says 'send it from Orders', but it never appears there and can't be sent to the kitchen.").
-- Hold on the floor (pos_counter_order with send false) left an order in billing with no table and no KOT, but no hold row: Orders → Hold
-- lists only orders with a hold row (pos_hold_list), and Orders → Live leaves out an unpaid counter draft, so it showed nowhere; and
-- nothing could send a held order's dishes to the kitchen.
--   * pos_counter_order: a held order gets its hold row (as pos_hold_place does), so it shows under Orders → Hold.
--   * rst_hold_send: sends a held order's dishes to the kitchen (a KOT, the order moves to the kitchen and to Orders → Live, the hold is
--     marked resumed). The same people who may place orders.
--   * orders already stuck this way (in billing, unpaid, no table, dishes never sent, no hold row) get their hold row now.
-- Safe to run again.

CREATE OR REPLACE FUNCTION public.pos_counter_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id();
  v_type text := coalesce(nullif(p->>'service_type', ''), 'pickup'); v_send boolean; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  v_name text := nullif(btrim(coalesce(p->>'customer_name', '')), ''); v_phone text := nullif(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), '');
  v_addr text := nullif(btrim(coalesce(p->>'address', '')), ''); v_notes text := nullif(btrim(coalesce(p->>'notes', '')), '');
  v_res jsonb; v_id uuid; v_kot jsonb;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an Idempotency-Key is needed so a retry never places the order twice'; end if;
  if v_type not in ('pickup', 'delivery') then raise exception 'POS_BAD_REQUEST: choose Takeaway or Delivery'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'POS_BAD_REQUEST: send is true or false'; end;
  if v_type = 'delivery' then
    if v_phone is null or char_length(v_phone) < 10 then raise exception 'POS_BAD_REQUEST: enter the customer''s phone number for a delivery'; end if;
    if v_addr is null then raise exception 'POS_BAD_REQUEST: enter the delivery address'; end if;
  end if;
  if char_length(coalesce(v_addr, '')) > 300 then raise exception 'POS_BAD_REQUEST: the address can be up to 300 characters'; end if;

  v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', v_type, 'placed_by', 'pos', 'fire_kot', false,
    'idempotency_key', v_key, 'lines', p->'lines', 'customer_name', v_name, 'customer_phone', v_phone,
    'notes', nullif(concat_ws(' · ', case when v_addr is not null then 'Deliver to: ' || v_addr end, v_notes), '')));
  v_id := (v_res->>'id')::uuid;
  if coalesce((v_res->>'replayed')::boolean, false) then return jsonb_build_object('order_id', v_id, 'replayed', true, 'order', v_res); end if;
  if v_loc is not null then update public.orders set location_id = v_loc where id = v_id; end if;
  if v_send then
    v_kot := public.tbl_kot_fire(v_id);
  else
    -- 0643: held: a hold row, so it is listed under Orders → Hold and can be sent from there
    insert into public.pos_order_holds (order_id, organization_id, location_id, reason, held_by)
    select o.id, o.organization_id, o.location_id, case when v_type = 'delivery' then 'Delivery held at the counter' else 'Takeaway held at the counter' end, auth.uid()
      from public.orders o where o.id = v_id
    on conflict (order_id) do nothing;
  end if;
  return jsonb_build_object('order_id', v_id, 'replayed', false, 'held', not v_send, 'service_type', v_type, 'kot', v_kot,
    'order', jsonb_build_object('display_no', v_res->>'display_no', 'total', (v_res->>'total')::numeric, 'status', case when v_send then 'sent_to_kitchen' else 'in_billing' end));
end $$

;

-- Send a held order to the kitchen: {order_id, idempotency_key}
create or replace function public.rst_hold_send(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; v_kot jsonb; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_begin jsonb; v_scope text; v_res jsonb;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  begin
    select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid for update;
  exception when others then raise exception 'POS_BAD_REQUEST: not a valid order'; end;
  if not found or o.organization_id is distinct from public.current_org_id() or not public.location_is_allowed(o.organization_id, o.location_id) then
    raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not (public.has_permission(o.organization_id, 'order', 'place', o.location_id) or public.has_permission(o.organization_id, 'order', 'update_status', o.location_id)) then
    raise exception 'POS_FORBIDDEN: your role cannot send orders to the kitchen'; end if;
  if v_key is not null then
    if char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: the idempotency key is too long'; end if;
    v_scope := 'rst_hold_send:' || o.id;
    v_begin := public.idempotency_begin(v_scope, v_key, md5((p - 'idempotency_key')::text));
    if v_begin->>'state' = 'replay' then return (v_begin->'response') || jsonb_build_object('replayed', true); end if;
  end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  if o.paid_at is not null or o.status not in ('new', 'in_billing') then raise exception 'POS_WRONG_STATE: this order is already with the kitchen'; end if;
  if not exists (select 1 from public.order_items i where i.order_id = o.id and i.kot_ticket_id is null and i.status = 'pending') then
    raise exception 'POS_WRONG_STATE: this order has no dishes to send'; end if;
  v_kot := public.tbl_kot_fire(o.id);
  update public.pos_order_holds set resumed_at = now(), resume_count = resume_count + 1, updated_at = now() where order_id = o.id;
  v_res := jsonb_build_object('order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'kot', v_kot, 'status', 'sent_to_kitchen');
  if v_key is not null then perform public.idempotency_complete(v_scope, v_key, v_res); end if;
  return v_res || jsonb_build_object('replayed', false);
end $$;
revoke all on function public.rst_hold_send(jsonb) from public, anon;
grant execute on function public.rst_hold_send(jsonb) to authenticated, service_role;

-- orders already stuck: held on the floor before this, with no hold row
insert into public.pos_order_holds (order_id, organization_id, location_id, reason, held_by)
select o.id, o.organization_id, o.location_id, case when o.channel = 'delivery' then 'Delivery held at the counter' else 'Takeaway held at the counter' end, o.created_by
  from public.orders o
 where o.channel in ('pickup', 'delivery') and o.table_id is null and o.status = 'in_billing' and o.paid_at is null
   and not exists (select 1 from public.pos_order_holds h where h.order_id = o.id)
   and not exists (select 1 from public.payments y where y.order_id = o.id)
   and not exists (select 1 from public.kot_tickets k where k.order_id = o.id)
   and exists (select 1 from public.order_items i where i.order_id = o.id and i.status = 'pending')
   and not exists (select 1 from public.ol_orders x where x.pos_order_id = o.id)
on conflict (order_id) do nothing;

-- a restaurant (the same rule as the server's home screen, modules/home.ts kindOf): the business's domain says so, else its first outlet's kind
create or replace function public.pos_org_is_restaurant(p_org uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when lower(coalesce(o.business_domain, '')) ~ '(restaurant|food)' then true
    when lower(coalesce(o.business_domain, '')) ~ '(service|retail|store|grocery)' then false
    else coalesce((select l.kind = 'restaurant' from public.locations l where l.organization_id = o.id order by (l.code = 'MAIN') desc, l.created_at limit 1), false) end
  from public.organizations o where o.id = p_org;
$$;
-- an order whose dishes have not gone to the kitchen yet: in billing, unpaid, dishes waiting, no KOT, not an app order
create or replace function public.pos_order_held_for_kitchen(p_order uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.orders o where o.id = p_order and o.status = 'in_billing' and o.paid_at is null
                   and o.channel in ('pickup', 'delivery', 'dine_in')
                   and exists (select 1 from public.order_items i where i.order_id = o.id and i.kot_ticket_id is null and i.status = 'pending')
                   and not exists (select 1 from public.payments y where y.order_id = o.id)
                   and not exists (select 1 from public.ol_orders x where x.pos_order_id = o.id));
$$;
revoke all on function public.pos_org_is_restaurant(uuid) from public, anon, authenticated;
revoke all on function public.pos_order_held_for_kitchen(uuid) from public, anon, authenticated;

-- pos_orders_board (Orders → Live): a restaurant's held order shows under New, marked held, so it can be sent to the kitchen
CREATE OR REPLACE FUNCTION public.pos_orders_board(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $board$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid;
  v_ch text := coalesce(nullif(p->>'channel', ''), 'all'); v_st text := coalesce(nullif(p->>'status', ''), 'new');
  v_q text := left(nullif(btrim(coalesce(p->>'q', '')), ''), 60); v_tz text; v_prep int; v_day_start timestamptz;
  v_counts jsonb; v_channels jsonb; v_orders jsonb; v_integrations jsonb; v_header jsonb; v_rst boolean := public.pos_org_is_restaurant(public.current_org_id());
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_ch not in ('all', 'dine_in', 'takeaway', 'delivery', 'zomato', 'swiggy') then raise exception 'POS_BAD_REQUEST: unknown channel'; end if;
  if v_st not in ('new', 'preparing', 'ready', 'dispatched', 'completed') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;

  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.id = v_loc) desc nulls last, (l.code = 'MAIN') desc, l.created_at limit 1;
  v_tz := coalesce(v_tz, 'Asia/Kolkata');
  v_day_start := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  select c.default_prep_minutes into v_prep from public.ol_merchant_channels c where c.organization_id = v_org;
  v_prep := coalesce(v_prep, 20);

  with b as materialized (
    select o.id, o.display_no, o.created_at, coalesce(nullif(o.customer_name, ''), case when o.channel = 'dine_in' then 'Dine-in guest' else 'Walk-in Guest' end) as customer,
         o.notes as note, o.total,
         case when o.channel in ('zomato', 'swiggy') then nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '') end as ext,
         public.pos_order_channel_key(o.channel, f.handover_method) as channel_key,
         case when o.channel = 'zomato' then 'Zomato' when o.channel = 'swiggy' then 'Swiggy' when x.id is not null then 'One Local' end as channel_tag,
         s.status_key, s.since, coalesce(x.prep_minutes, v_prep) as promise, t.label as table_label
  from public.orders o
  left join public.pos_fulfilments f on f.order_id = o.id
  left join public.ol_orders x on x.pos_order_id = o.id
  left join public.dining_tables t on t.id = o.table_id
  cross join lateral (select
      case
        when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready' when 'out' then 'dispatched' when 'delivered' then 'completed' end
        when f.order_id is not null then case f.stage when 'awaiting_acceptance' then 'new' when 'picking' then 'preparing' when 'picked' then 'preparing'
                                                      when 'ready' then 'ready' when 'dispatched' then 'dispatched' when 'completed' then 'completed' end
        else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                           when 'awaiting_payment' then 'ready' when 'paid' then 'completed' when 'delivered' then 'completed' end
      end as status_key,
      case
        when x.id is not null then o.created_at
        when f.order_id is not null then case f.stage when 'awaiting_acceptance' then f.created_at when 'picking' then coalesce(f.accepted_at, f.created_at)
                                                      when 'picked' then coalesce(f.accepted_at, f.created_at) when 'ready' then coalesce(f.ready_at, f.created_at)
                                                      when 'dispatched' then coalesce(f.dispatched_at, f.created_at) else f.completed_at end
        else o.created_at
      end as since) s
  where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
    and (v_loc is null or o.location_id = v_loc)
    and o.status <> 'cancelled' and coalesce(x.status, '') <> 'cancelled'
    -- 0643: a restaurant's order held before the kitchen (takeaway, delivery, or dishes waiting on a table) is a New order, to be sent from here
    and not (o.status = 'in_billing' and o.paid_at is null and not (v_rst and public.pos_order_held_for_kitchen(o.id))
             and (exists (select 1 from public.pos_order_holds h where h.order_id = o.id)
                  -- an unpaid counter draft that is not a hold is not a live order either
                  or (o.channel = 'pickup' and f.order_id is null and x.id is null)))
    and s.status_key is not null
    and (s.status_key <> 'completed' or coalesce(f.completed_at, o.paid_at, o.updated_at) >= v_day_start)
    and (v_q is null or o.display_no ilike '%' || v_q || '%' or o.customer_name ilike '%' || v_q || '%' or o.external_ref ilike '%' || v_q || '%')
  ), c as (select * from b where v_ch = 'all' or channel_key = v_ch)
  select
    (select jsonb_build_object(
        'new', count(*) filter (where status_key = 'new'), 'preparing', count(*) filter (where status_key = 'preparing'),
        'ready', count(*) filter (where status_key = 'ready'), 'dispatched', count(*) filter (where status_key = 'dispatched'),
        'completed', count(*) filter (where status_key = 'completed')) from c),
    (select jsonb_agg(jsonb_build_object('key', u.k, 'live', (select count(*) from b where (u.k = 'all' or b.channel_key = u.k) and b.status_key <> 'completed')) order by u.n)
       from unnest(array['all', 'dine_in', 'takeaway', 'delivery', 'zomato', 'swiggy']) with ordinality u(k, n)),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'order_id', r.id, 'display_no', r.display_no, 'placed_at', r.created_at, 'customer', r.customer, 'items', public.pos_order_items_text(r.id),
        'note', r.note, 'channel', r.channel_key, 'channel_tag', r.channel_tag, 'external_id', r.ext, 'table', r.table_label,
        'status', r.status_key, 'minutes', greatest(0, floor(extract(epoch from (now() - coalesce(r.since, r.created_at))) / 60))::int,
        'delayed', r.status_key in ('new', 'preparing') and now() - r.created_at > make_interval(mins => r.promise),
        'total', r.total, 'held', v_rst and r.status_key = 'new' and public.pos_order_held_for_kitchen(r.id)) order by r.created_at desc), '[]'::jsonb)
       from (select * from c where status_key = v_st order by created_at desc limit 100) r)
  into v_counts, v_channels, v_orders;

  select jsonb_agg(jsonb_build_object(
      'channel', k, 'name', initcap(k), 'listed', ci.id is not null,
      'connected', coalesce(ci.is_connected and ci.is_accepting, false) and ic.id is not null,
      'state', case when coalesce(ci.is_connected and ci.is_accepting, false) and ic.id is not null then 'online' else 'offline' end,
      'reason', case when ic.id is null or not coalesce(ci.is_connected, false) then 'not_connected' when not coalesce(ci.is_accepting, false) then 'paused' end) order by k desc)
    into v_integrations
    from unnest(array['zomato', 'swiggy']) k
    left join public.channel_integrations ci on ci.organization_id = v_org and ci.channel = k
    left join lateral (select c.id from public.integration_connections c where c.organization_id = v_org and c.provider = k and c.status = 'connected' limit 1) ic on true;

  select jsonb_build_object('business', g.name,
      'outlet', (select l.name from public.locations l where l.organization_id = v_org and (v_loc is null or l.id = v_loc) and public.location_is_allowed(v_org, l.id)
                 order by (l.id = v_loc) desc nulls last, (l.code = 'MAIN') desc, l.created_at limit 1),
      'accepting', (select c.accepting from public.ol_merchant_channels c where c.organization_id = v_org))
    into v_header from public.organizations g where g.id = v_org;

  return jsonb_build_object('header', v_header, 'channel', v_ch, 'status', v_st, 'counts', v_counts, 'channels', v_channels,
                            'integrations', v_integrations, 'orders', v_orders, 'prep_minutes', v_prep);
end $board$;

-- rst_channel_orders (Orders in a restaurant): a Takeaway source next to OneLocal, Swiggy, Zomato and On call delivery, and each order says
-- whether it is held (not sent to the kitchen), so a held takeaway or delivery can be found and sent
CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $chan$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             d.stage as dstage, d.rider_name, d.rider_phone, d.eta_minutes, d.updated_at as d_at,
             greatest(o.total - (select coalesce(sum(pm.amount), 0) from public.payments pm where pm.order_id = o.id), 0) as due,
             (x.id is not null and x.payment_status = 'paid' and coalesce(x.payment_method, '') <> 'cod') as prepaid,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' when o.channel = 'pickup' then 'takeaway' end as source,
             public.pos_order_held_for_kitchen(o.id) as held,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               -- 0619: the restaurant's own delivery updates
               when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then case when o.channel = 'pickup' then 'ready' else 'on_way' end else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
        left join public.pos_order_delivery d on d.order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery', 'pickup'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4), ('takeaway', 'Takeaway', 5))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), ''),
          'delivery', case when o.dstage is null then null else jsonb_build_object('stage', o.dstage, 'rider_name', o.rider_name, 'rider_phone', o.rider_phone, 'eta_minutes', o.eta_minutes, 'at', o.d_at) end,
          -- 0620: what is still to collect (0 once paid), and whether the customer paid in the app
          'due', o.due, 'prepaid', o.prepaid,
          -- 0643: held on the floor, dishes not yet sent to the kitchen: Send to kitchen (rst_hold_send)
          'held', o.held
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $chan$;
