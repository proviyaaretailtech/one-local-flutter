-- 0647: the cash drawer never goes below zero (founder, 3 Nov 2026: "Voiding a 'cash in' entry can push the cash drawer below zero. I got
-- −₹500. (Not possible fix it, it can only be in positive)").
-- 0633 stopped cash out and moves out of cash beyond what is in the drawer, and a move into cash being removed after the cash had gone;
-- removing a plain cash in was not checked, so cash that had already been paid out could be taken back and the drawer went negative.
--   * rmoney_void: a cash in (like a move into cash) cannot be removed beyond what is in the drawer now
--   * a restaurant refund in cash (rst_bill_refund, a cashier's approved request) and a void that gives cash back (rst_bill_void) cannot
--     pay out more cash than the drawer holds: refund by UPI or card, or add the cash first (Money → Add money)
-- Safe to run again.

-- the drawer of the bill's outlet must hold [p_amount] for a cash refund
create or replace function public.rst_adj__cash_left(o public.orders, p_amount numeric, p_method text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_cash bigint;
begin
  if p_method is distinct from 'cash' or coalesce(p_amount, 0) <= 0 then return; end if;
  v_cash := public.rmoney_cash_now(o.organization_id, array[o.location_id]);
  if round(p_amount * 100) > v_cash then
    raise exception 'POS_NOT_ENOUGH_CASH: only % is in the cash drawer; give it back by UPI or card, or add cash to the drawer first',
      public.notice_money(greatest(v_cash, 0) / 100.0, 'INR');
  end if;
end $$;
revoke all on function public.rst_adj__cash_left(public.orders, numeric, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rmoney_void(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_org uuid := public.money_require('money', 'approve'); e public.rmoney_entries; v_reason text := btrim(coalesce(p->>'reason', ''));
begin
  if v_reason = '' then raise exception 'MONEY_BAD_REQUEST: say why it is removed'; end if;
  select * into e from public.rmoney_entries where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'MONEY_NOT_FOUND: entry not found (only entries made here can be removed)'; end if;
  if e.kind = 'cash_difference' then raise exception 'MONEY_BAD_REQUEST: a day close cannot be undone'; end if;
  if e.status = 'voided' then return to_jsonb(e); end if;
  -- 3. a closed day keeps its cash count
  if (e.method = 'cash' or 'cash' in (e.from_account, e.to_account)) and public.rmoney_day_closed(v_org, e.location_id, e.entry_date) then
    raise exception 'MONEY_DAY_CLOSED: the cash for % is closed; this entry stays', to_char(e.entry_date, 'DD Mon');
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
end $f$;

-- a restaurant refund in cash, and a void that gives cash back, check the drawer

CREATE OR REPLACE FUNCTION public.rst_adj__refund_check(o orders, p_amount numeric, p_method text, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
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
  perform public.rst_adj__cash_left(o, p_amount, p_method);
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 300 then raise exception 'POS_BAD_REQUEST: give a reason (3 to 300 characters)'; end if;
end $f$;

CREATE OR REPLACE FUNCTION public.rst_adj__void_apply(o orders, p_reason text, p_method text, p_key text, p_asked_by uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare m jsonb := public.rst_adj__money(o.id); v_left numeric := (m->>'refundable')::numeric; r jsonb; v_new public.orders%rowtype;
  v_approver uuid := case when p_asked_by is distinct from auth.uid() then auth.uid() end; v_refund uuid;
begin
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this bill is already void'; end if;
  if o.channel in ('online', 'swiggy', 'zomato') then raise exception 'POS_WRONG_STATE: an app or aggregator order is changed on its own platform'; end if;
  -- money taken and not yet refunded goes back first (the shared refund, as a cancellation), then the order is cancelled
  if v_left > 0.005 then
    if p_method is null or p_method not in ('cash', 'upi', 'card', 'other') then
      raise exception 'POS_BAD_REQUEST: % was paid on this bill; choose how it goes back', v_left; end if;
    perform public.rst_adj__cash_left(o, v_left, p_method);
    r := public.pos_refund(jsonb_build_object('order_id', o.id, 'amount', v_left, 'method', p_method, 'kind', 'cancel',
                                              'reason', 'Bill void: ' || p_reason, 'idempotency_key', 'void:' || p_key));
    v_refund := (r->>'refund_id')::uuid;
  end if;
  -- a served order is billed before it can be cancelled (the order's own steps)
  if o.status = 'delivered' then perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'awaiting_payment')); end if;
  -- 0645: the void was the owner's own decision (0640): its cancel needs no admin PIN
  perform set_config('app.rst_cancel_ok', 'on', true);
  perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'cancelled', 'reason', 'Bill void: ' || p_reason));
  perform set_config('app.rst_cancel_ok', 'off', true);
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
end $f$;
