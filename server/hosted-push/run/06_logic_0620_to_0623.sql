-- ==========================================================================================================================
-- HOSTED PUSH piece 06 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0620_delivery_completes.sql
-- 0620: Delivered completes an online order (founder, 29 Oct 2026: "check the complete order process"). Before this, a delivered order
-- stayed open on the POS side: no payment, no paid time, so it still counted as live, stayed in the KOT view and never reached Sales.
-- Now the Delivered / Picked up step records what is still due and closes the order (and its KOTs):
--   Swiggy / Zomato   settled by the aggregator (method other, reference Swiggy / Zomato)
--   OneLocal, paid    paid in the app (method other, reference OneLocal app) when its online payment is not on the order yet
--   at the door       cash, UPI or card, which the restaurant chooses (asked when anything is due: POS_PAYMENT_NEEDED)
-- An order already paid in full is simply closed. rst_channel_orders says each order's 'due' and 'prepaid'.
-- Safe to run again.

create or replace function public.rst_channel_delivery(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; d public.pos_order_delivery%rowtype;
  v_step text := p->>'step'; v_src text; v_stage text; v_rider text := nullif(btrim(coalesce(p->>'rider_name', '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p->>'rider_phone', ''), '\D', '', 'g'), ''); v_eta int := nullif(p->>'eta_minutes', '')::int; v_msg text;
  v_pay text := nullif(p->>'payment_method', ''); v_paid numeric; v_due numeric := 0; v_prepaid boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_step is null or v_step not in ('ready', 'out', 'delivered') then raise exception 'POS_BAD_REQUEST: unknown step'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot update orders'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  select * into d from public.pos_order_delivery where order_id = o.id for update;
  v_src := case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel when o.channel = 'delivery' then 'on_call' end;
  if v_src is null then raise exception 'POS_BAD_REQUEST: this is not an online or delivery order'; end if;
  if o.status = 'cancelled' or x.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  -- where it stands now, as the online orders list says it
  v_stage := case when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
                  when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready' when 'out' then 'on_way' else 'delivered' end
                  else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                     when 'awaiting_payment' then 'on_way' else 'delivered' end end;
  if v_stage = 'new' then raise exception 'POS_WRONG_STATE: accept the order first'; end if;
  if v_stage = 'delivered' then raise exception 'POS_WRONG_STATE: this order is already delivered'; end if;
  if v_rider is not null and char_length(v_rider) > 60 then raise exception 'POS_BAD_REQUEST: the rider''s name is too long'; end if;
  if v_phone is not null then
    if length(v_phone) = 12 and left(v_phone, 2) = '91' then v_phone := right(v_phone, 10); end if;
    if v_phone !~ '^[6-9][0-9]{9}$' then raise exception 'POS_BAD_REQUEST: enter the rider''s 10-digit mobile number'; end if;
  end if;
  if v_eta is not null and (v_eta < 1 or v_eta > 240) then raise exception 'POS_BAD_REQUEST: give the time in minutes, 1 to 240'; end if;

  if v_step = 'ready' then
    if v_stage <> 'preparing' then raise exception 'POS_WRONG_STATE: only an order in the kitchen can be marked ready'; end if;
    if x.id is not null and x.status = 'accepted' then
      perform public.status_gate('ol_orders', x.id, 'kitchen_ready');
      update public.ol_orders set status = 'packed' where id = x.id;
    end if;
    v_msg := o.display_no || ' packed and ready' || case when v_src in ('swiggy', 'zomato') then ' for the rider' else '' end;
  elsif v_step = 'out' then
    if v_src in ('swiggy', 'zomato') then raise exception 'POS_BAD_REQUEST: % riders deliver % orders; mark it picked up instead', initcap(v_src), initcap(v_src); end if;
    if v_stage not in ('preparing', 'ready', 'on_way') then raise exception 'POS_WRONG_STATE: this order cannot go out now'; end if;
    if x.id is not null and x.status in ('accepted', 'packed') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'packed' then 'hand_out' else 'delivery_sync_out' end);
      update public.ol_orders set status = 'out' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, rider_name, rider_phone, eta_minutes, updated_at, updated_by)
    values (o.id, v_org, 'out', v_rider, v_phone, v_eta, now(), auth.uid())
    on conflict (order_id) do update set stage = 'out', rider_name = coalesce(excluded.rider_name, pos_order_delivery.rider_name),
      rider_phone = coalesce(excluded.rider_phone, pos_order_delivery.rider_phone), eta_minutes = coalesce(excluded.eta_minutes, pos_order_delivery.eta_minutes),
      updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || ' out for delivery' || coalesce(' with ' || v_rider, '') || coalesce(', about ' || v_eta || ' min', '');
  else
    if v_src in ('swiggy', 'zomato') and v_stage <> 'ready' then raise exception 'POS_WRONG_STATE: mark it ready first, then picked up by the rider'; end if;
    -- 0620: delivered completes the order. What is still due is paid: by the aggregator (Swiggy / Zomato), already in the app (OneLocal paid
    -- online), or collected at the door, which the restaurant says (cash, UPI or card)
    select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = o.id;
    v_due := greatest(o.total - v_paid, 0);
    v_prepaid := x.id is not null and x.payment_status = 'paid' and coalesce(x.payment_method, '') <> 'cod';
    if v_due > 0.005 and v_src not in ('swiggy', 'zomato') and not v_prepaid then
      if v_pay is null then raise exception 'POS_PAYMENT_NEEDED: ₹% to collect: was it paid by cash, UPI or card?', v_due; end if;
      if v_pay not in ('cash', 'upi', 'card') then raise exception 'POS_BAD_REQUEST: paid by cash, UPI or card'; end if;
    end if;
    if x.id is not null and x.status in ('accepted', 'packed', 'out') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'out' then 'delivered' else 'delivery_sync_delivered' end);
      update public.ol_orders set status = 'delivered' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, updated_at, updated_by) values (o.id, v_org, 'delivered', now(), auth.uid())
    on conflict (order_id) do update set stage = 'delivered', updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || case when v_src in ('swiggy', 'zomato') then ' picked up by the ' || initcap(v_src) || ' rider' else ' delivered' end;
    if v_due > 0.005 and v_pay is not null and v_src not in ('swiggy', 'zomato') and not v_prepaid then
      v_msg := v_msg || ', ₹' || trim(to_char(v_due, 'FM999999990.00')) || ' collected by ' || case v_pay when 'upi' then 'UPI' else v_pay end;
    end if;
  end if;
  -- the kitchen's part is done once it is packed: its dishes are ready
  if o.status in ('new', 'in_billing', 'sent_to_kitchen') then
    update public.kot_tickets set status = 'ready', updated_at = now() where order_id = o.id and status in ('new', 'preparing');
    update public.order_items set status = 'ready' where order_id = o.id and status in ('pending', 'preparing');
    perform public.status_gate('orders', o.id, 'set_ready');
    update public.orders set status = 'ready', updated_at = now() where id = o.id;
  else
    update public.orders set updated_at = now() where id = o.id;
  end if;
  -- 0620: delivered = done: the payment is recorded (that closes the order and its KOTs), or an order already paid is closed
  if v_step = 'delivered' then
    if v_due > 0.005 then
      perform public.pos_record_payment(jsonb_build_object('order_id', o.id, 'amount', v_due,
        'method', case when v_src in ('swiggy', 'zomato') or v_prepaid then 'other' else v_pay end,
        'reference', case when v_src in ('swiggy', 'zomato') then initcap(v_src) when v_prepaid then 'OneLocal app' end,
        'idempotency_key', 'delivered:' || o.id));
    elsif (select status from public.orders where id = o.id) not in ('paid', 'cancelled') then
      perform public.status_gate('orders', o.id, 'set_paid');
      update public.orders set status = 'paid', paid_at = coalesce(paid_at, now()), updated_at = now() where id = o.id;
      update public.kot_tickets set status = 'delivered', updated_at = now() where order_id = o.id and status <> 'delivered';
    end if;
  end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_org, o.id, 'delivery_' || v_step, v_msg, 'pos', jsonb_build_object('by', auth.uid(), 'step', v_step, 'rider', v_rider, 'eta_minutes', v_eta));
  return jsonb_build_object('order_id', o.id, 'step', v_step, 'message', v_msg);
end $$;

revoke all on function public.rst_channel_delivery(jsonb) from public, anon;
grant execute on function public.rst_channel_delivery(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
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
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               -- 0619: the restaurant's own delivery updates
               when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
        left join public.pos_order_delivery d on d.order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
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
          'due', o.due, 'prepaid', o.prepaid
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$

;

-- ---- 0621_kot_shows_cancels.sql
-- 0621: an order cancelled while the kitchen has it shows on the KDS and on the KOT view (founder, 29 Oct 2026). The KOT view used to drop
-- a cancelled order without a word, and the KDS alert (0618) did not say who cancelled or why.
--   * order_cancel_info(order): who cancelled (Customer / Restaurant / Swiggy / Zomato / OneLocal) and the reason
--   * kds_cancelled: + 'by', 'reason'
--   * rst_kot_orders: today's cancelled kitchen orders stay, stage 'cancelled' with 'cancel' {by, reason, at}; a 'cancelled' count and
--     filter; one cancelled in the last hour comes first
-- Read only. Safe to run again.

create or replace function public.order_cancel_info(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with o as (select o.id, o.channel from public.orders o where o.id = p_order),
  ol as (select ol.id, ol.user_id, ol.cancelled_by, ol.cancel_reason from public.ol_orders ol join o on ol.pos_order_id = o.id limit 1),
  oc as (select c.initiated_by, c.reason from public.order_cancellations c join ol on c.ol_order_id = ol.id limit 1),
  ev as (select e.meta->>'reason' as reason from public.order_events e join o on e.order_id = o.id
          where e.kind = 'status_cancelled' order by e.created_at desc limit 1)
  select jsonb_build_object(
    'by', case
            when exists (select 1 from ev) then 'Restaurant'
            when (select initiated_by from oc) = 'customer' or ((select cancelled_by from ol) is not null and (select cancelled_by from ol) = (select user_id from ol)) then 'Customer'
            when (select initiated_by from oc) = 'restaurant' then 'Restaurant'
            when exists (select 1 from ol) then 'OneLocal'
            when (select channel from o) = 'swiggy' then 'Swiggy'
            when (select channel from o) = 'zomato' then 'Zomato'
            else 'Restaurant' end,
    'reason', coalesce(nullif(btrim((select reason from ev)), ''), nullif(btrim((select reason from oc)), ''), nullif(btrim((select cancel_reason from ol)), '')))
$$;
revoke all on function public.order_cancel_info(uuid) from public, anon;

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         || public.order_cancel_info(o.id)
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

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
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case when s.fresh_cancel then -1 else case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 when 'completed' then 3 else 4 end end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$;

-- ---- 0622_restaurant_money.sql
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

-- ---- 0623_org_sell_plan.sql
-- 0623: the business's current plan for Subscription plans (founder, 29 Oct 2026: subscription plans in the restaurant POS, same prices as
-- the store). Read from the business's approved partner application (pos_only | pos_and_onelocal), for anyone signed in to the business,
-- not only the person who applied. Read only. Safe to run again.
create or replace function public.org_sell_plan(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object('plan', (select a.sell_plan from public.ol_partner_applications a where a.organization_id = v_org and a.sell_plan is not null
                                      order by (a.status = 'approved') desc, a.updated_at desc nulls last limit 1));
end $$;
revoke all on function public.org_sell_plan(jsonb) from public, anon;
grant execute on function public.org_sell_plan(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
