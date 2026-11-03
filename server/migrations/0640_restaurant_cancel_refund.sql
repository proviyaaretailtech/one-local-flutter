-- 0640: cancel a dish, cancel KOT items, refund and void a restaurant bill (founder, 2 Nov 2026). Before this the restaurant could only
-- cancel a whole order: a wrongly added dish could not come off, a KOT item could not be stopped, and a paid bill could not be refunded or
-- voided from the restaurant screens.
--   * rst_items_cancel: cancel one or more dishes (all of a line or part of its quantity), with a reason. The line stays on the order:
--     order_items.cancelled_qty counts what was cancelled (status 'cancelled' once nothing is left). The bill is repriced by
--     tbl_order_reprice (tax, service charge, round off; a percent discount follows the new subtotal). The KOT's status follows its items,
--     the kitchen hears it at once (the KOT broadcast + kds_cancelled), and the order is ready when nothing is left to cook.
--       - not sent to the kitchen, or sent but not started: anyone who takes orders
--       - already cooking, ready or served, or the bill is already generated: a manager; others ask (a request a manager approves)
--       - a bill with a payment on it: refund instead (an item cannot come off money already taken)
--   * rst_bill_refund: a refund of a paid bill through the shared pos_refund (its idempotency key, its cap at what was paid, its ledger rows):
--     a manager refunds, a cashier (biller) asks and a manager approves. Full or part.
--   * rst_bill_void: voids a bill as its money stands. Unpaid: the order is cancelled. Money taken: what is left is refunded through pos_refund
--     (kind 'cancel') and then the order is cancelled. Owner and admin only; managers and cashiers ask.
--   * requests: rst_requests_list, rst_request_decide. Kept in order_events (adjust_requested / adjust_approved / adjust_rejected), the order's
--     own append-only history; approving runs the action as the approver, so who asked and who approved are both on the record.
--   * rst_order_adjust: one order's payment details (paid, refunded, still refundable, payment status), its refunds, cancelled items and open
--     requests, and what the signed-in person may do.
--   * rst_report_cancellations: item cancels, voids and refunds between two days.
--   * tbl_order_view: lines say what was cancelled and whether this person may cancel them; kds_cancelled and rst_kot_orders: item cancels.
-- Every action writes an order_event and an audit_logs row (order, bill = order, item, KOT, quantity, amount, reason, who, approver, when,
-- reference, before and after). Nothing is deleted. Safe to run again.

alter table public.order_items add column if not exists cancelled_qty integer not null default 0;
do $$ begin
  alter table public.order_items add constraint order_items_cancelled_qty_check check (cancelled_qty >= 0);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------- helpers

-- the order, locked, if it is this business's and this person may see its outlet; aggregator and app orders are not changed here
create or replace function public.rst_adj__lock(p_order uuid) returns public.orders
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_o public.orders%rowtype;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into v_o from public.orders where id = p_order for update;
  if not found or v_o.organization_id is distinct from public.current_org_id() or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then
    raise exception 'POS_NOT_FOUND: order not found'; end if;
  return v_o;
end $$;
revoke all on function public.rst_adj__lock(uuid) from public, anon, authenticated;

-- the managers pos_refund accepts (the same list, so an approved refund always goes through)
create or replace function public.rst_adj__mgr() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'finance_manager']);
$$;
create or replace function public.rst_adj__owner() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.has_org_role(array['org_owner', 'org_admin']);
$$;
revoke all on function public.rst_adj__mgr() from public, anon, authenticated;
revoke all on function public.rst_adj__owner() from public, anon, authenticated;

create or replace function public.money_person(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select nullif(btrim(ou.full_name), '') from public.org_users ou where ou.organization_id = p_org and ou.user_id = p_user
                    order by (ou.status = 'active') desc limit 1), 'Staff');
$$;
revoke all on function public.money_person(uuid, uuid) from public, anon, authenticated;

-- what was paid, refunded and is still refundable; the payment status a paid bill has after refunds
create or replace function public.rst_adj__money(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with m as (
    select (select coalesce(sum(amount), 0) from public.payments where order_id = p_order and method <> 'due') taken,
           (select coalesce(sum(amount), 0) from public.payments where order_id = p_order and method = 'due') on_credit,
           (select coalesce(sum(amount), 0) from public.pos_refunds where order_id = p_order) back,
           (select total from public.orders where id = p_order) total)
  select jsonb_build_object('total', m.total, 'paid', m.taken, 'on_credit', m.on_credit, 'refunded', m.back,
    'refundable', greatest(m.taken - m.back, 0),
    'payment_status', case when m.taken <= 0 then 'unpaid'
                           when m.back >= m.taken - 0.005 then 'refunded'
                           when m.back > 0 then 'partly_refunded'
                           when m.taken < m.total - 0.005 then 'part_paid' else 'paid' end)
  from m;
$$;
revoke all on function public.rst_adj__money(uuid) from public, anon, authenticated;

create or replace function public.rst_adj__audit(p_org uuid, p_action text, p_order uuid, p_before jsonb, p_after jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (p_org, auth.uid(), p_action, 'order', p_order::text, p_before, p_after);
$$;
revoke all on function public.rst_adj__audit(uuid, text, uuid, jsonb, jsonb) from public, anon, authenticated;

-- an open request of this order (asked, not yet approved or rejected, under 12 hours old)
create or replace function public.rst_adj__open_requests(p_order uuid) returns setof public.order_events
language sql stable security definer set search_path = public, pg_temp as $$
  select e.* from public.order_events e
   where e.order_id = p_order and e.kind = 'adjust_requested' and e.created_at > now() - interval '12 hours'
     and not exists (select 1 from public.order_events d where d.order_id = p_order and d.kind in ('adjust_approved', 'adjust_rejected')
                      and d.meta->>'request_id' = e.meta->>'request_id');
$$;
revoke all on function public.rst_adj__open_requests(uuid) from public, anon, authenticated;

-- the KOT's own status follows its items (as kds_ticket_act): nothing left is 'cancelled'; a closed (delivered) KOT stays closed
create or replace function public.rst_adj__kot_follow(p_kot uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_st text; v_new text;
begin
  select status into v_st from public.kot_tickets where id = p_kot for update;
  if not found then return; end if;
  select case when count(*) = 0 then 'cancelled'
              when count(*) filter (where i.status = 'delivered') = count(*) then 'delivered'
              when count(*) filter (where i.status in ('pending', 'preparing')) = 0 then 'ready'
              when count(*) filter (where i.status = 'pending') = count(*) then 'new' else 'preparing' end
    into v_new from public.order_items i where i.kot_ticket_id = p_kot and i.status <> 'cancelled';
  -- updated_at always moves: the KOT broadcast (kot_updated) tells every kitchen screen at once
  update public.kot_tickets set status = case when v_st = 'delivered' then v_st else v_new end, updated_at = now() where id = p_kot;
end $$;
revoke all on function public.rst_adj__kot_follow(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- cancel items

-- p_lines: [{item_id, qty}]. Checks every line against the order as it is now and says whether a manager is needed. Raises on anything wrong.
create or replace function public.rst_adj__cancel_check(o public.orders, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare l jsonb; i public.order_items%rowtype; v_qty int; v_out jsonb := '[]'::jsonb; v_mgr boolean := false; v_seen uuid[] := '{}';
  v_value numeric := 0; v_left int;
begin
  if o.channel in ('online', 'swiggy', 'zomato') then raise exception 'POS_WRONG_STATE: an app or aggregator order is changed on its own platform'; end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order is already cancelled'; end if;
  if o.status = 'paid' or o.paid_at is not null then raise exception 'POS_WRONG_STATE: this bill is paid; give a refund instead'; end if;
  if exists (select 1 from public.payments where order_id = o.id) then
    raise exception 'POS_WRONG_STATE: a payment was already taken on this bill; give a refund instead'; end if;
  if exists (select 1 from public.rst_bill_splits where order_id = o.id and status = 'active') then
    raise exception 'POS_WRONG_STATE: the bill is split; take the split off before cancelling a dish'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'POS_BAD_REQUEST: choose a dish to cancel'; end if;
  if jsonb_array_length(p_lines) > 50 then raise exception 'POS_BAD_REQUEST: at most 50 dishes at a time'; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    begin
      select * into i from public.order_items where id = (l->>'item_id')::uuid and order_id = o.id;
      v_qty := (l->>'qty')::int;
    exception when others then raise exception 'POS_BAD_REQUEST: choose the dish and how many again'; end;
    if i.id is null then raise exception 'POS_NOT_FOUND: that dish is not on this order'; end if;
    if i.id = any (v_seen) then raise exception 'POS_BAD_REQUEST: a dish is listed twice'; end if;
    v_seen := v_seen || i.id;
    if i.status = 'cancelled' then raise exception 'POS_WRONG_STATE: % is already cancelled', i.name; end if;
    if v_qty is null or v_qty < 1 then raise exception 'POS_BAD_REQUEST: cancel at least one'; end if;
    if v_qty > i.qty then raise exception 'POS_BAD_REQUEST: only % of % are on the order', i.qty, i.name; end if;
    -- started, ready or served, or the bill was already handed over: a manager decides
    if i.status in ('preparing', 'ready', 'delivered') or o.status = 'awaiting_payment' then v_mgr := true; end if;
    v_value := v_value + i.unit_price * v_qty;
    v_out := v_out || jsonb_build_object('item_id', i.id, 'qty', v_qty, 'name', i.name, 'variant', i.variant_name, 'unit_price', i.unit_price,
      'status', i.status, 'sent', i.kot_ticket_id is not null, 'kot_id', i.kot_ticket_id,
      'kot_no', (select k.kot_no from public.kot_tickets k where k.id = i.kot_ticket_id), 'whole', v_qty = i.qty);

  end loop;
  select coalesce(sum(x.qty), 0) - coalesce(sum((select (e->>'qty')::int from jsonb_array_elements(v_out) e where (e->>'item_id')::uuid = x.id)), 0)
    into v_left from public.order_items x where x.order_id = o.id and x.status <> 'cancelled';
  if v_left <= 0 then raise exception 'POS_WRONG_STATE: that cancels every dish; cancel the whole order instead'; end if;
  return jsonb_build_object('lines', v_out, 'needs_manager', v_mgr, 'value', v_value);
end $$;
revoke all on function public.rst_adj__cancel_check(public.orders, jsonb) from public, anon, authenticated;

-- applies a checked cancel: the lines, the discount, the bill, the KOTs, the order status, the history and the audit
create or replace function public.rst_adj__cancel_apply(o public.orders, c jsonb, p_reason text, p_asked_by uuid, p_request uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare l jsonb; v_gross numeric; v_md jsonb; v_cp record; v_disc numeric; v_new public.orders%rowtype; v_kots uuid[] := '{}'; k uuid;
  v_approver uuid := case when p_asked_by is distinct from auth.uid() then auth.uid() end; v_before jsonb; v_status_before text := o.status;
begin
  v_before := jsonb_build_object('status', o.status, 'subtotal', o.subtotal, 'discount', o.discount, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'total', o.total,
    'lines', (select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', i.qty, 'cancelled_qty', i.cancelled_qty, 'status', i.status))
                from public.order_items i where i.id in (select (e->>'item_id')::uuid from jsonb_array_elements(c->'lines') e)));
  for l in select * from jsonb_array_elements(c->'lines') loop
    if (l->>'whole')::boolean then
      update public.order_items set status = 'cancelled', cancelled_qty = cancelled_qty + (l->>'qty')::int where id = (l->>'item_id')::uuid;
    else
      update public.order_items set qty = qty - (l->>'qty')::int, cancelled_qty = cancelled_qty + (l->>'qty')::int where id = (l->>'item_id')::uuid;
    end if;
    if l->>'kot_id' is not null and not ((l->>'kot_id')::uuid = any (v_kots)) then v_kots := v_kots || (l->>'kot_id')::uuid; end if;
  end loop;

  -- the discount follows the dishes left: a percent (manual or code) is taken of the new subtotal; an amount stays, and may not take the bill
  select coalesce(sum(i.unit_price * i.qty), 0) into v_gross from public.order_items i where i.order_id = o.id and i.status <> 'cancelled';
  v_disc := coalesce(o.discount, 0);
  if v_disc > 0 then
    v_md := public.rst_bill_manual_discount(o.id);
    if o.coupon_code is not null then
      select cp.kind, cp.value, cp.max_discount into v_cp from public.sell_coupons cp where cp.organization_id = o.organization_id and upper(cp.code) = upper(o.coupon_code) limit 1;
      if found and v_cp.kind = 'percent' then v_disc := round(v_gross * v_cp.value / 100, 2); if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if; end if;
    elsif v_md is not null and v_md->>'kind' = 'percent' and (v_md->>'value') is not null then
      v_disc := round(v_gross * (v_md->>'value')::numeric / 100, 2);
    end if;
    if v_disc >= v_gross then raise exception 'POS_WRONG_STATE: the discount on this bill is more than what is left; take the discount off first'; end if;
    update public.orders set discount = v_disc where id = o.id;
  end if;
  perform public.tbl_order_reprice(o.id);

  foreach k in array v_kots loop perform public.rst_adj__kot_follow(k); end loop;
  -- the order is ready when nothing is left to cook (the one authority for order status is pos_set_order_status)
  if o.status = 'sent_to_kitchen' and not exists (select 1 from public.order_items i where i.order_id = o.id and i.status in ('pending', 'preparing')) then
    perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'ready'));
  end if;
  select * into v_new from public.orders where id = o.id;

  for l in select * from jsonb_array_elements(c->'lines') loop
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
    values (o.organization_id, o.id, 'item_cancelled',
            (l->>'qty') || '× ' || (l->>'name') || ' cancelled' || case when l->>'kot_no' is not null then ' (KOT ' || (l->>'kot_no') || ')' else '' end || ': ' || p_reason,
            'pos', jsonb_build_object('order_id', o.id, 'bill_id', o.id, 'item_id', l->>'item_id', 'name', l->>'name', 'variant', l->>'variant', 'qty', (l->>'qty')::int,
              'unit_price', (l->>'unit_price')::numeric, 'value', (l->>'unit_price')::numeric * (l->>'qty')::int,
              'kot_id', l->>'kot_id', 'kot_no', l->>'kot_no', 'sent', (l->>'sent')::boolean, 'item_status', l->>'status',
              'new_item_status', (select i.status from public.order_items i where i.id = (l->>'item_id')::uuid),
              'reason', p_reason, 'by', coalesce(p_asked_by, auth.uid()), 'approved_by', v_approver, 'request_id', p_request, 'reference', p_key,
              'order_status_before', v_status_before, 'order_status_after', v_new.status, 'old_total', o.total, 'new_total', v_new.total),
            clock_timestamp());
  end loop;
  perform public.rst_adj__audit(o.organization_id, 'rst.item_cancel', o.id, v_before,
    jsonb_build_object('status', v_new.status, 'subtotal', v_new.subtotal, 'discount', v_new.discount, 'gst_amount', v_new.gst_amount,
      'service_charge', v_new.service_charge, 'total', v_new.total, 'lines', c->'lines', 'reason', p_reason,
      'by', coalesce(p_asked_by, auth.uid()), 'approved_by', v_approver, 'request_id', p_request, 'reference', p_key));
  return jsonb_build_object('status', 'cancelled', 'order_id', o.id, 'old_total', o.total, 'new_total', v_new.total, 'order_status', v_new.status,
                            'lines', c->'lines', 'approved_by', v_approver);
end $$;
revoke all on function public.rst_adj__cancel_apply(public.orders, jsonb, text, uuid, uuid, text) from public, anon, authenticated;

-- an open request is stored as an order_event; asking twice for the same thing returns the first ask
create or replace function public.rst_adj__ask(o public.orders, p_action text, p_payload jsonb, p_amount numeric, p_reason text, p_roles text[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.order_events%rowtype; v_id uuid := gen_random_uuid();
begin
  select * into e from public.rst_adj__open_requests(o.id) r where r.meta->>'action' = p_action and r.meta->'payload' = p_payload limit 1;
  if found then return jsonb_build_object('status', 'requested', 'request_id', e.meta->>'request_id', 'replayed', true); end if;
  if (select count(*) from public.rst_adj__open_requests(o.id)) >= 10 then raise exception 'POS_WRONG_STATE: this bill already has 10 requests waiting'; end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (o.organization_id, o.id, 'adjust_requested',
          case p_action when 'item_cancel' then 'Asked to cancel ' || coalesce(p_payload->>'label', 'dishes')
                        when 'refund' then 'Asked to refund ' || p_amount else 'Asked to void ' || coalesce(o.display_no, 'the bill') end || ': ' || p_reason,
          'pos', jsonb_build_object('request_id', v_id, 'action', p_action, 'payload', p_payload, 'amount', p_amount, 'reason', p_reason,
                                    'by', auth.uid(), 'approver_roles', to_jsonb(p_roles), 'expires_at', now() + interval '12 hours'),
          clock_timestamp());
  perform public.rst_adj__audit(o.organization_id, 'rst.request', o.id, null,
    jsonb_build_object('request_id', v_id, 'action', p_action, 'payload', p_payload, 'amount', p_amount, 'reason', p_reason));
  return jsonb_build_object('status', 'requested', 'request_id', v_id, 'replayed', false);
end $$;
revoke all on function public.rst_adj__ask(public.orders, text, jsonb, numeric, text, text[]) from public, anon, authenticated;

-- Cancel dishes: {order_id, items: [{item_id, qty}], reason, idempotency_key}. Done now, or asked of a manager ({status: 'requested'}).
create or replace function public.rst_items_cancel(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; c jsonb; v_reason text := btrim(coalesce(p->>'reason', '')); v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  v_begin jsonb; v_scope text; v_res jsonb; v_lines jsonb;
begin
  o := public.rst_adj__lock(nullif(p->>'order_id', '')::uuid);
  if not (public.has_permission(o.organization_id, 'order', 'update_status', o.location_id) or public.has_permission(o.organization_id, 'order', 'place', o.location_id)) then
    raise exception 'POS_FORBIDDEN: your role cannot change orders'; end if;
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  v_scope := 'rst_items_cancel:' || o.id;
  v_begin := public.idempotency_begin(v_scope, v_key, md5((p - 'idempotency_key')::text));
  if v_begin->>'state' = 'replay' then return (v_begin->'response') || jsonb_build_object('replayed', true); end if;
  if char_length(v_reason) not between 3 and 200 then raise exception 'POS_BAD_REQUEST: say why (3 to 200 characters)'; end if;
  -- the same dish asked as {item_id, qty} in any order is the same request
  begin
    select jsonb_agg(jsonb_build_object('item_id', (x->>'item_id')::uuid, 'qty', (x->>'qty')::int) order by x->>'item_id') into v_lines
      from jsonb_array_elements(case when jsonb_typeof(p->'items') = 'array' then p->'items' else '[]'::jsonb end) x;
  exception when others then raise exception 'POS_BAD_REQUEST: choose the dish and how many again'; end;
  c := public.rst_adj__cancel_check(o, coalesce(v_lines, '[]'::jsonb));
  if (c->>'needs_manager')::boolean and not public.rst_adj__mgr() then
    v_res := public.rst_adj__ask(o, 'item_cancel', jsonb_build_object('lines', v_lines, 'label', (select string_agg((l->>'qty') || '× ' || (l->>'name'), ', ') from jsonb_array_elements(c->'lines') l)), (c->>'value')::numeric, v_reason,
                                 array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'finance_manager']);
  else
    v_res := public.rst_adj__cancel_apply(o, c, v_reason, auth.uid(), null, v_key);
  end if;
  v_res := v_res || jsonb_build_object('order', public.rst_adj__view(o.id));
  perform public.idempotency_complete(v_scope, v_key, v_res - 'replayed');   -- a replay of this key says replayed: true
  return jsonb_build_object('replayed', false) || v_res;
end $$;

-- ---------------------------------------------------------------- refund and void

create or replace function public.rst_adj__refund_apply(o public.orders, p_amount numeric, p_method text, p_reason text, p_key text, p_asked_by uuid, p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_before jsonb := public.rst_adj__money(o.id); r jsonb; v_kind text := 'goodwill';
  v_approver uuid := case when p_asked_by is distinct from auth.uid() then auth.uid() end;
begin
  perform public.rst_adj__refund_check(o, p_amount, p_method, p_reason);
  -- the shared refund: its key, its cap at what was paid, its pos_refunds and payment_ledger rows and its 'refunded' event
  r := public.pos_refund(jsonb_build_object('order_id', o.id, 'amount', p_amount, 'method', p_method, 'kind', v_kind, 'reason', p_reason, 'idempotency_key', p_key));
  if not coalesce((r->>'replayed')::boolean, false) then
    perform public.rst_adj__audit(o.organization_id, 'rst.refund', o.id, v_before,
      public.rst_adj__money(o.id) || jsonb_build_object('refund_id', r->>'refund_id', 'amount', p_amount, 'method', p_method, 'kind', v_kind, 'reason', p_reason,
        'by', coalesce(p_asked_by, auth.uid()), 'approved_by', v_approver, 'request_id', p_request, 'reference', p_key));
  end if;
  return jsonb_build_object('status', 'refunded', 'order_id', o.id, 'refund_id', r->>'refund_id', 'amount', p_amount, 'approved_by', v_approver,
                            'replayed', coalesce((r->>'replayed')::boolean, false)) || public.rst_adj__money(o.id);
end $$;
revoke all on function public.rst_adj__refund_apply(public.orders, numeric, text, text, text, uuid, uuid) from public, anon, authenticated;

-- the checks before a refund, the same sentences pos_refund would give, so a cashier's request is not one that can never be approved
create or replace function public.rst_adj__refund_check(o public.orders, p_amount numeric, p_method text, p_reason text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m jsonb := public.rst_adj__money(o.id);
begin
  if o.channel = 'online' then raise exception 'POS_WRONG_STATE: an online order is refunded through the online refund flow'; end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order is cancelled'; end if;
  if (m->>'paid')::numeric <= 0 then raise exception 'POS_WRONG_STATE: no money was taken on this bill'; end if;
  -- a part-paid bill is not refunded: finish the payment, or void the bill (which gives back what was taken)
  if (m->>'paid')::numeric < o.total - 0.005 then raise exception 'POS_WRONG_STATE: this bill is not paid in full; finish the payment or void the bill'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then raise exception 'POS_BAD_REQUEST: enter the amount to refund'; end if;
  if p_amount > (m->>'refundable')::numeric + 0.005 then raise exception 'POS_OVER_REFUND: at most % can be refunded on this bill', m->>'refundable'; end if;
  if p_method is null or p_method not in ('cash', 'upi', 'card', 'other') then raise exception 'POS_BAD_REQUEST: choose how the money goes back'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 300 then raise exception 'POS_BAD_REQUEST: give a reason (3 to 300 characters)'; end if;
end $$;
revoke all on function public.rst_adj__refund_check(public.orders, numeric, text, text) from public, anon, authenticated;

-- Refund: {order_id, amount, method, reason, idempotency_key}. A manager refunds now; a cashier asks ({status: 'requested'}).
create or replace function public.rst_bill_refund(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; v_amt numeric; v_method text := p->>'method'; v_reason text := btrim(coalesce(p->>'reason', ''));
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_res jsonb; r public.pos_refunds%rowtype;
begin
  o := public.rst_adj__lock(nullif(p->>'order_id', '')::uuid);
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  begin v_amt := (p->>'amount')::numeric; exception when others then v_amt := null; end;
  if not (public.rst_adj__mgr() or public.rst_can_pay()) then raise exception 'POS_FORBIDDEN: your role cannot refund bills'; end if;
  -- a retry of a refund already given answers as it did (the shared refund's own replay)
  select * into r from public.pos_refunds where organization_id = o.organization_id and idempotency_key = v_key;
  if found then
    if r.order_id <> o.id or r.amount <> v_amt then raise exception 'POS_IDEMPOTENCY_MISMATCH: this key was already used for a different refund'; end if;
    return jsonb_build_object('status', 'refunded', 'order_id', o.id, 'refund_id', r.id, 'amount', r.amount, 'replayed', true)
           || public.rst_adj__money(o.id) || jsonb_build_object('order', public.rst_adj__view(o.id));
  end if;
  perform public.rst_adj__refund_check(o, v_amt, v_method, v_reason);
  if public.rst_adj__mgr() then
    v_res := public.rst_adj__refund_apply(o, v_amt, v_method, v_reason, v_key, auth.uid(), null);
  else
    v_res := public.rst_adj__ask(o, 'refund', jsonb_build_object('amount', v_amt, 'method', v_method), v_amt, v_reason,
                                 array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'finance_manager']);
  end if;
  return v_res || jsonb_build_object('order', public.rst_adj__view(o.id));
end $$;

create or replace function public.rst_adj__void_apply(o public.orders, p_reason text, p_method text, p_key text, p_asked_by uuid, p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m jsonb := public.rst_adj__money(o.id); v_left numeric := (m->>'refundable')::numeric; r jsonb; v_new public.orders%rowtype;
  v_approver uuid := case when p_asked_by is distinct from auth.uid() then auth.uid() end; v_refund uuid;
begin
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this bill is already void'; end if;
  if o.channel in ('online', 'swiggy', 'zomato') then raise exception 'POS_WRONG_STATE: an app or aggregator order is changed on its own platform'; end if;
  -- money taken and not yet refunded goes back first (the shared refund, as a cancellation), then the order is cancelled
  if v_left > 0.005 then
    if p_method is null or p_method not in ('cash', 'upi', 'card', 'other') then
      raise exception 'POS_BAD_REQUEST: % was paid on this bill; choose how it goes back', v_left; end if;
    r := public.pos_refund(jsonb_build_object('order_id', o.id, 'amount', v_left, 'method', p_method, 'kind', 'cancel',
                                              'reason', 'Bill void: ' || p_reason, 'idempotency_key', 'void:' || p_key));
    v_refund := (r->>'refund_id')::uuid;
  end if;
  -- a served order is billed before it can be cancelled (the order's own steps)
  if o.status = 'delivered' then perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'awaiting_payment')); end if;
  perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'cancelled', 'reason', 'Bill void: ' || p_reason));
  select * into v_new from public.orders where id = o.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (o.organization_id, o.id, 'bill_voided', coalesce(o.display_no, 'Bill') || ' voided' || case when v_refund is not null then ', ' || v_left || ' refunded' else '' end || ': ' || p_reason,
          'pos', jsonb_build_object('order_id', o.id, 'bill_id', o.id, 'reason', p_reason, 'by', coalesce(p_asked_by, auth.uid()), 'approved_by', v_approver,
                                    'request_id', p_request, 'reference', p_key, 'refund_id', v_refund, 'refund_amount', case when v_refund is not null then v_left else 0 end,
                                    'refund_method', case when v_refund is not null then p_method end, 'total', o.total,
                                    'status_before', o.status, 'status_after', v_new.status, 'payment_before', m->>'payment_status'),
          clock_timestamp());
  perform public.rst_adj__audit(o.organization_id, 'rst.bill_void', o.id, m || jsonb_build_object('status', o.status),
    public.rst_adj__money(o.id) || jsonb_build_object('status', v_new.status, 'reason', p_reason, 'refund_id', v_refund, 'by', coalesce(p_asked_by, auth.uid()),
                                                      'approved_by', v_approver, 'request_id', p_request, 'reference', p_key));
  return jsonb_build_object('status', 'voided', 'order_id', o.id, 'refund_id', v_refund, 'refunded', case when v_refund is not null then v_left else 0 end,
                            'approved_by', v_approver);
end $$;
revoke all on function public.rst_adj__void_apply(public.orders, text, text, text, uuid, uuid) from public, anon, authenticated;

-- Void: {order_id, reason, method (when money was taken), idempotency_key}. Owner and admin void now; managers and cashiers ask.
create or replace function public.rst_bill_void(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; v_reason text := btrim(coalesce(p->>'reason', '')); v_method text := nullif(p->>'method', '');
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_res jsonb; e public.order_events%rowtype; m jsonb;
begin
  o := public.rst_adj__lock(nullif(p->>'order_id', '')::uuid);
  if v_key is null or char_length(v_key) > 90 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  if not (public.rst_adj__mgr() or public.rst_can_pay()) then raise exception 'POS_FORBIDDEN: your role cannot void bills'; end if;
  select * into e from public.order_events where order_id = o.id and kind = 'bill_voided' and meta->>'reference' = v_key limit 1;
  if found then return jsonb_build_object('status', 'voided', 'order_id', o.id, 'refund_id', e.meta->>'refund_id', 'replayed', true, 'order', public.rst_adj__view(o.id)); end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this bill is already void'; end if;
  if o.channel in ('online', 'swiggy', 'zomato') then raise exception 'POS_WRONG_STATE: an app or aggregator order is changed on its own platform'; end if;
  if char_length(v_reason) not between 3 and 200 then raise exception 'POS_BAD_REQUEST: say why (3 to 200 characters)'; end if;
  m := public.rst_adj__money(o.id);
  if (m->>'refundable')::numeric > 0.005 and (v_method is null or v_method not in ('cash', 'upi', 'card', 'other')) then
    raise exception 'POS_BAD_REQUEST: % was paid on this bill; choose how it goes back', m->>'refundable'; end if;
  if public.rst_adj__owner() then
    v_res := public.rst_adj__void_apply(o, v_reason, v_method, v_key, auth.uid(), null) || jsonb_build_object('replayed', false);
  else
    v_res := public.rst_adj__ask(o, 'void', jsonb_build_object('method', v_method), (m->>'refundable')::numeric, v_reason, array['org_owner', 'org_admin']);
  end if;
  return v_res || jsonb_build_object('order', public.rst_adj__view(o.id));
end $$;

-- ---------------------------------------------------------------- requests

create or replace function public.rst_adj__request_json(e public.order_events) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('request_id', e.meta->>'request_id', 'order_id', e.order_id, 'display_no', o.display_no,
    'table_label', (select t.label from public.dining_tables t where t.id = o.table_id), 'action', e.meta->>'action', 'payload', e.meta->'payload',
    'amount', (e.meta->>'amount')::numeric, 'reason', e.meta->>'reason', 'asked_by', public.money_person(e.organization_id, (e.meta->>'by')::uuid),
    'asked_by_id', e.meta->>'by', 'at', e.created_at, 'message', e.message,
    'may_decide', public.has_org_role(array(select jsonb_array_elements_text(e.meta->'approver_roles'))) and (e.meta->>'by')::uuid is distinct from auth.uid())
  from public.orders o where o.id = e.order_id;
$$;
revoke all on function public.rst_adj__request_json(public.order_events) from public, anon, authenticated;

-- requests waiting: of one order ({order_id}) or of the outlets this person sees; newest first
create or replace function public.rst_requests_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_order uuid;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  begin v_order := nullif(p->>'order_id', '')::uuid; exception when others then raise exception 'POS_BAD_REQUEST: not a valid order'; end;
  if not (public.rst_adj__mgr() or public.rst_can_pay() or public.has_permission(v_org, 'order', 'update_status', null)) then
    raise exception 'POS_FORBIDDEN: your role cannot see requests'; end if;
  return jsonb_build_object('requests', (
    select coalesce(jsonb_agg(public.rst_adj__request_json(e) order by e.created_at desc), '[]'::jsonb)
      from public.order_events e join public.orders o on o.id = e.order_id
     where e.organization_id = v_org and e.kind = 'adjust_requested' and e.created_at > now() - interval '12 hours'
       and (v_order is null or e.order_id = v_order) and public.location_is_allowed(o.organization_id, o.location_id)
       and not exists (select 1 from public.order_events d where d.order_id = e.order_id and d.kind in ('adjust_approved', 'adjust_rejected')
                        and d.meta->>'request_id' = e.meta->>'request_id')));
end $$;

-- Approve or reject: {request_id, decision: approve | reject, note}. Approving does the action now, as the approver.
create or replace function public.rst_request_decide(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_rid text := nullif(btrim(coalesce(p->>'request_id', '')), ''); v_dec text := p->>'decision';
  v_note text := nullif(btrim(coalesce(p->>'note', '')), ''); e public.order_events%rowtype; o public.orders%rowtype; v_res jsonb; v_asked uuid; v_pl jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_rid is null then raise exception 'POS_BAD_REQUEST: which request?'; end if;
  if v_dec is null or v_dec not in ('approve', 'reject') then raise exception 'POS_BAD_REQUEST: approve or reject'; end if;
  if char_length(coalesce(v_note, '')) > 200 then raise exception 'POS_BAD_REQUEST: keep the note under 200 characters'; end if;
  select * into e from public.order_events where organization_id = v_org and kind = 'adjust_requested' and meta->>'request_id' = v_rid limit 1;
  if not found then raise exception 'POS_NOT_FOUND: request not found'; end if;
  o := public.rst_adj__lock(e.order_id);   -- one decision at a time per order
  if exists (select 1 from public.order_events d where d.order_id = o.id and d.kind in ('adjust_approved', 'adjust_rejected') and d.meta->>'request_id' = v_rid) then
    raise exception 'POS_WRONG_STATE: this request was already decided'; end if;
  if e.created_at <= now() - interval '12 hours' then raise exception 'POS_WRONG_STATE: this request has expired; ask again'; end if;
  v_asked := (e.meta->>'by')::uuid;
  if v_asked = auth.uid() then raise exception 'POS_FORBIDDEN: someone else approves your own request'; end if;
  if not public.has_org_role(array(select jsonb_array_elements_text(e.meta->'approver_roles'))) then
    raise exception 'POS_FORBIDDEN: %', case when e.meta->>'action' = 'void' then 'only the owner or an admin can approve a void' else 'only a manager can approve this' end; end if;
  v_pl := e.meta->'payload';
  if v_dec = 'approve' then
    v_res := case e.meta->>'action'
      when 'item_cancel' then public.rst_adj__cancel_apply(o, public.rst_adj__cancel_check(o, v_pl->'lines'), e.meta->>'reason', v_asked, v_rid::uuid, 'request:' || v_rid)
      when 'refund' then public.rst_adj__refund_apply(o, (v_pl->>'amount')::numeric, v_pl->>'method', e.meta->>'reason', 'request:' || v_rid, v_asked, v_rid::uuid)
      when 'void' then public.rst_adj__void_apply(o, e.meta->>'reason', v_pl->>'method', 'request:' || v_rid, v_asked, v_rid::uuid) end;
  else
    v_res := jsonb_build_object('status', 'rejected');
  end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (o.organization_id, o.id, case when v_dec = 'approve' then 'adjust_approved' else 'adjust_rejected' end,
          case when v_dec = 'approve' then 'Approved: ' else 'Rejected: ' end || e.message || coalesce(' · ' || v_note, ''), 'pos',
          jsonb_build_object('request_id', v_rid, 'action', e.meta->>'action', 'decided_by', auth.uid(), 'asked_by', v_asked, 'note', v_note), clock_timestamp());
  perform public.rst_adj__audit(o.organization_id, 'rst.request_' || v_dec, o.id, null,
    jsonb_build_object('request_id', v_rid, 'action', e.meta->>'action', 'asked_by', v_asked, 'note', v_note, 'result', v_res));
  return v_res || jsonb_build_object('request_id', v_rid, 'decision', v_dec, 'order', public.rst_adj__view(o.id));
end $$;

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
