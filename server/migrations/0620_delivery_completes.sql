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
