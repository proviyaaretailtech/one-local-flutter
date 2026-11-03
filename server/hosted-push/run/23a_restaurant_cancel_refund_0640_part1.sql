-- ==========================================================================================================================
-- HOSTED: 0640 Cancel a dish / KOT item, refund and void a restaurant bill (2 Nov 2026), PART 1 of 2. Run 23a, then 23b.
-- One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Part 1: order_items.cancelled_qty, the helpers, rst_items_cancel, rst_bill_refund (uses the shared pos_refund), rst_bill_void, requests.
-- ==========================================================================================================================
begin;
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

do $$ declare f text; begin
  foreach f in array array['rst_items_cancel(jsonb)', 'rst_bill_refund(jsonb)', 'rst_bill_void(jsonb)', 'rst_requests_list(jsonb)', 'rst_request_decide(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
