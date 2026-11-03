-- ==========================================================================================================================
-- HOSTED: 0648 Card and UPI payments always keep their reference number (3 Nov 2026). One transaction: if it stops with an error,
-- nothing has changed. Project ywylhzcxuoeilygzdonx. A restaurant's card or UPI payment needs its reference (the card's last 4 digits or
-- approval code, the UPI UTR), on Checkout, each guest of a split bill, the order page, the cart and delivery paid at the door. Stores
-- unchanged; payments already recorded are not changed.
-- ==========================================================================================================================
begin;
-- 0648: a restaurant's card and UPI payments always keep their reference number (founder, 3 Nov 2026: "The card or UPI reference number is
-- never saved. (Card and upi numbers are always be saved)"). pos_record_payment already stored a reference when one was sent, but no
-- restaurant screen sent one.
--   * pos_record_payment: for a restaurant, a card or UPI payment needs its reference (4 to 60 characters): the card's last 4 digits or
--     approval code, the UPI UTR / transaction id. Every restaurant payment goes through it: Checkout (rst_bill_pay, each split part),
--     the order page (pos_checkout_pay), the cart (pos_checkout), delivered orders paid at the door (rst_channel_delivery). Stores and service businesses unchanged.
--   * rst_channel_delivery: a card or UPI payment at the door keeps the reference it was given.
-- Payments already recorded are not changed. Safe to run again.

CREATE OR REPLACE FUNCTION public.pos_record_payment(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_o public.orders%rowtype; v_amt numeric(10,2) := (p->>'amount')::numeric; v_method text := p->>'method'; v_key text := nullif(p->>'idempotency_key','');
  v_paid numeric; v_methods int; v_exp timestamptz := nullif(p->>'expected_updated_at','')::timestamptz;
begin
  select * into v_o from public.orders where id = (p->>'order_id')::uuid for update;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id() then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','biller','business_manager','location_manager','finance_manager']) then raise exception 'POS_FORBIDDEN: your role cannot take payments'; end if;
  if v_key is not null and exists (select 1 from public.payments where order_id = v_o.id and idempotency_key = v_key) then
    return public.pos_order_json(v_o.id) || jsonb_build_object('replayed', true); end if;
  if v_amt is null or v_amt <= 0 then raise exception 'POS_BAD_REQUEST: enter the amount received'; end if;
  if v_method not in ('cash','upi','card','wallet','other') then raise exception 'POS_BAD_REQUEST: unknown payment method'; end if;
  -- 0648: a restaurant's card or UPI payment always keeps its reference (card: last 4 digits or approval code; UPI: the UTR / transaction id)
  if v_method in ('card', 'upi') and public.pos_org_is_restaurant(v_o.organization_id) then
    if char_length(btrim(coalesce(p->>'reference', ''))) = 0 then
      raise exception 'POS_BAD_REQUEST: enter the % reference number (%)', case v_method when 'card' then 'card' else 'UPI' end,
        case v_method when 'card' then 'the last 4 digits or the approval code' else 'the UTR or transaction id' end; end if;
    if char_length(btrim(p->>'reference')) not between 4 and 60 then raise exception 'POS_BAD_REQUEST: the reference number is 4 to 60 characters'; end if;
  end if;
  if v_o.status in ('paid','cancelled') then raise exception 'POS_WRONG_STATE: this order is already %', v_o.status; end if;
  if v_exp is not null and v_exp <> v_o.updated_at then raise exception 'POS_STALE: this order was changed on another device'; end if;
  select coalesce(sum(amount),0) into v_paid from public.payments where order_id = v_o.id;
  if v_paid + v_amt > v_o.total then raise exception 'POS_OVERPAY: payment exceeds the amount due (due %)', v_o.total - v_paid; end if;
  insert into public.payments (organization_id, order_id, method, amount, reference, created_by, idempotency_key)
  values (v_o.organization_id, v_o.id, v_method, v_amt, nullif(btrim(p->>'reference'),''), auth.uid(), v_key);
  select count(distinct method) into v_methods from public.payments where order_id = v_o.id;
  if v_paid + v_amt >= v_o.total then
    perform public.status_gate('orders', v_o.id, 'set_paid');
    update public.orders set status = 'paid', paid_at = now(), updated_at = now(),
      payment_method = case when v_methods > 1 then 'split' when v_method in ('cash','upi','card') then v_method else null end where id = v_o.id;
    update public.kot_tickets set status = 'delivered', updated_at = now() where order_id = v_o.id and status <> 'delivered';
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values (v_o.organization_id, v_o.id, 'paid', v_o.display_no || ' paid in full', 'pos', jsonb_build_object('by', auth.uid()));
  else
    if v_o.status <> 'awaiting_payment' then perform public.status_gate('orders', v_o.id, 'set_awaiting_payment'); end if;
    update public.orders set status = 'awaiting_payment', updated_at = now() where id = v_o.id and status <> 'awaiting_payment';
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values (v_o.organization_id, v_o.id, 'part_paid', v_method || ' ' || v_amt || ' received', 'pos', jsonb_build_object('by', auth.uid()));
  end if;
  return public.pos_order_json(v_o.id) || jsonb_build_object('replayed', false);
end $f$;

CREATE OR REPLACE FUNCTION public.rst_channel_delivery(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
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
        -- 0648: a card or UPI payment at the door keeps its reference number
        'reference', case when v_src in ('swiggy', 'zomato') then initcap(v_src) when v_prepaid then 'OneLocal app' else nullif(btrim(coalesce(p->>'reference', '')), '') end,
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
end $f$;

notify pgrst, 'reload schema';
commit;
