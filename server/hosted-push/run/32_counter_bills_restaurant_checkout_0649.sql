-- ==========================================================================================================================
-- HOSTED: 0649 Takeaway and delivery bills use the restaurant Checkout (3 Nov 2026). One transaction: if it stops with an error, nothing
-- has changed. Project ywylhzcxuoeilygzdonx. A restaurant's takeaway or phone delivery bill (no table) opens at the restaurant Checkout by
-- its order: coupon, manual discount, split, card / UPI references and the receipt work on it (they answered "Bill not found"). It can be
-- paid once it went to the kitchen. A held takeaway needs the admin PIN for a discount only once a payment was taken. Table bills unchanged.
-- ==========================================================================================================================
begin;
-- 0649: takeaway and delivery bills in a restaurant use the restaurant Checkout (founder, 3 Nov 2026: "Takeaway and delivery bills use
-- the store's order screen: no coupon, manual discount or split. The restaurant payment route answers 'Bill not found' for them. Make it
-- for restaurant pos").
-- The restaurant bill functions only took a bill on a table (rst_bill_lock, the receipt). A counter bill is a restaurant's order with no
-- table on the takeaway (pickup) or phone delivery channel; app and aggregator orders are still paid on their own platform.
--   * rst_bill_ready: a table bill is ready to pay once generated (awaiting payment), as before; a counter bill once it went to the kitchen
--     (sent to the kitchen, ready, delivered) or was held for payment.
--   * rst_bill_lock, rst_receipt_view, rst_receipt_log: a counter bill is found.
--   * rst_bill_view: by order_id for a counter bill ('table' is null, 'counter' says Takeaway or Delivery), by table_id as before.
--   * rst_bill_order_json: bill_generated follows rst_bill_ready, and the channel is given.
--   * rst_bill_pay, rst_bill_split: "generate the bill first" follows rst_bill_ready (a counter bill: "send the order to the kitchen first").
--   * rst_admin__guard: a held counter bill is a cart, not a printed bill: its discount and coupon need the admin PIN once a payment was
--     taken on it. Table bills unchanged.
-- Dine-in bills are unchanged. Safe to run again.

create or replace function public.rst_bill_ready(p_status text, p_table uuid, p_channel text) returns boolean
  language sql immutable set search_path to 'public', 'pg_temp' as $f$
  select p_status = 'awaiting_payment'
      or (p_table is null and p_channel in ('pickup', 'delivery') and p_status in ('sent_to_kitchen', 'ready', 'delivered'));
$f$;
revoke all on function public.rst_bill_ready(text, uuid, text) from public, anon;
grant execute on function public.rst_bill_ready(text, uuid, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_bill_lock(p_order uuid)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into v_o from public.orders where id = p_order for update;
  if not found or v_o.organization_id is distinct from public.current_org_id() or (v_o.table_id is null and not (v_o.channel in ('pickup', 'delivery') and public.pos_org_is_restaurant(v_o.organization_id)))
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: bill not found'; end if;
  return v_o;
end $function$;

CREATE OR REPLACE FUNCTION public.rst_receipt_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or v_o.organization_id is distinct from public.current_org_id() or (v_o.table_id is null and not (v_o.channel in ('pickup', 'delivery') and public.pos_org_is_restaurant(v_o.organization_id)))
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: bill not found'; end if;
  if not (public.has_permission(v_o.organization_id, 'order', 'place', v_o.location_id) or public.has_permission(v_o.organization_id, 'order', 'update_status', v_o.location_id)
          or public.rst_can_pay()) then raise exception 'POS_FORBIDDEN: your role cannot see bills'; end if;
  return public.rst_bill_order_json(v_o.id) || jsonb_build_object(
    'paid_at', v_o.paid_at, 'payment_method', v_o.payment_method,
    'table_label', (select d.label from public.dining_tables d where d.id = v_o.table_id),
    'location', (select jsonb_build_object('id', l.id, 'name', l.name) from public.locations l where l.id = v_o.location_id),
    'business', (select g.name from public.organizations g where g.id = v_o.organization_id),
    'receipt_printer', (select x.name from public.pos_printers x where x.organization_id = v_o.organization_id and x.printer_type = 'receipt' and x.active and x.deleted_at is null
                          and (x.location_id is null or x.location_id = v_o.location_id) order by x.is_default desc, (x.location_id is null), x.created_at limit 1),
    'sent', (select coalesce(jsonb_agg(jsonb_build_object('channel', replace(e.kind, 'receipt_', ''), 'to', e.meta->>'to', 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id and e.kind in ('receipt_print', 'receipt_whatsapp', 'receipt_sms', 'receipt_email')));
end $function$;

CREATE OR REPLACE FUNCTION public.rst_receipt_log(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_ch text := p->>'channel'; v_to text := nullif(btrim(coalesce(p->>'to', '')), ''); v_mask text; v_digits text;
begin
  if auth.uid() is null or public.current_org_id() is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or v_o.organization_id is distinct from public.current_org_id() or (v_o.table_id is null and not (v_o.channel in ('pickup', 'delivery') and public.pos_org_is_restaurant(v_o.organization_id)))
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: bill not found'; end if;
  if not (public.has_permission(v_o.organization_id, 'order', 'place', v_o.location_id) or public.has_permission(v_o.organization_id, 'order', 'update_status', v_o.location_id)
          or public.rst_can_pay()) then raise exception 'POS_FORBIDDEN: your role cannot send receipts'; end if;
  if v_o.status <> 'paid' then raise exception 'POS_WRONG_STATE: a receipt is sent once the bill is paid'; end if;
  if v_ch is null or v_ch not in ('print', 'whatsapp', 'sms', 'email') then raise exception 'POS_BAD_REQUEST: print, WhatsApp, SMS or email'; end if;
  if v_ch in ('whatsapp', 'sms') then
    v_digits := regexp_replace(coalesce(v_to, ''), '\D', '', 'g');
    if char_length(v_digits) not between 10 and 13 then raise exception 'POS_BAD_REQUEST: enter a mobile number'; end if;
    v_mask := '******' || right(v_digits, 4);
  elsif v_ch = 'email' then
    if v_to is null or v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_to) > 200 then raise exception 'POS_BAD_REQUEST: enter an email address'; end if;
    v_mask := left(v_to, 1) || '***@' || split_part(v_to, '@', 2);
  else
    v_mask := left(coalesce(v_to, 'counter printer'), 60);
  end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, 'receipt_' || v_ch, 'Receipt ' || case v_ch when 'print' then 'printed' else 'sent by ' || v_ch end || ' (' || v_mask || ')', 'pos',
          jsonb_build_object('by', auth.uid(), 'to', v_mask));
  return jsonb_build_object('order_id', v_o.id, 'channel', v_ch, 'to', v_mask, 'logged', true);
end $function$;

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'manual_discount', public.rst_bill_manual_discount(o.id),
    'discount_limit_pct', coalesce((select s.manual_discount_limit_pct from public.org_bill_settings s where s.organization_id = o.organization_id), 10), 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone, 'customer_name', o.customer_name, 'customer_id', o.pos_customer_id,
    'bill_generated', public.rst_bill_ready(o.status, o.table_id, o.channel), 'channel', o.channel,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price,
                'line_total', i.unit_price * i.qty,
                -- 0625: what was chosen with the dish (add-ons and combos, each priced for one dish), and whether this row is a combo's dish at ₹0
                'add_ons', (select coalesce(jsonb_agg(jsonb_build_object('kind', x->>'kind', 'name', x->>'name', 'qty', coalesce((x->>'qty')::int, 1),
                              'price', (x->>'price')::numeric, 'items', x->>'items')), '[]'::jsonb)
                              from jsonb_array_elements(case when jsonb_typeof(i.add_ons) = 'array' then i.add_ons else '[]'::jsonb end) x),
                'in_combo', i.unit_price = 0 and coalesce(i.notes, '') like 'Combo: %') order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'at', y.created_at,
                   'tendered', (select t.tendered from public.pos_cash_tenders t where t.payment_id = y.id)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'split', (select public.rst_split_json(s.id) from public.rst_bill_splits s where s.order_id = o.id and s.status in ('active', 'completed')
               order by s.created_at desc limit 1))
  from public.orders o where o.id = p_order;
$function$;

CREATE OR REPLACE FUNCTION public.rst_bill_pay(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_method text := p->>'method';
  v_tendered numeric; v_part public.rst_bill_parts%rowtype; v_split public.rst_bill_splits%rowtype; v_pkey text; v_due numeric; v_amt numeric; v_pay uuid;
begin
  if v_key is null or char_length(v_key) > 90 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  begin v_tendered := nullif(p->>'tendered', '')::numeric; exception when others then raise exception 'POS_BAD_REQUEST: enter the amount received'; end;
  v_o := public.rst_bill_lock(nullif(p->>'order_id', '')::uuid);
  if not public.rst_can_pay() then raise exception 'POS_FORBIDDEN: your role cannot take payments'; end if;

  if nullif(p->>'part_id', '') is not null then
    select * into v_part from public.rst_bill_parts where id = (p->>'part_id')::uuid and order_id = v_o.id for update;
    if not found then raise exception 'POS_NOT_FOUND: this guest''s part was not found'; end if;
    v_pkey := 'rstpart:' || v_part.id;
    if v_part.status = 'paid' then
      if v_part.pay_key = v_key then return public.rst_pay_result(v_o.id, v_part.payment_id, v_part.id, true); end if;
      raise exception 'POS_WRONG_STATE: % has already paid', v_part.label;
    end if;
    select * into v_split from public.rst_bill_splits where id = v_part.split_id;
    if v_split.status <> 'active' then raise exception 'POS_WRONG_STATE: this split was replaced; open the bill again'; end if;
    if v_o.status in ('paid', 'cancelled') then raise exception 'POS_WRONG_STATE: this bill is already %', v_o.status; end if;
    if not public.rst_bill_ready(v_o.status, v_o.table_id, v_o.channel) then
      raise exception 'POS_WRONG_STATE: %', case when v_o.table_id is null then 'send the order to the kitchen first' else 'generate the bill first' end; end if;
    -- the open parts must still add up to what is due; otherwise the bill changed under the plan
    if (select coalesce(sum(amount), 0) from public.rst_bill_parts where split_id = v_split.id and status = 'open') <> v_o.total - public.rst_paid(v_o.id) then
      raise exception 'POS_STALE: the bill changed after it was split; split it again'; end if;
    v_amt := v_part.amount;
  else
    v_pkey := v_key || ':rst';
    select id into v_pay from public.payments where order_id = v_o.id and idempotency_key = v_pkey;
    if found then return public.rst_pay_result(v_o.id, v_pay, null, true); end if;
    if v_o.status in ('paid', 'cancelled') then raise exception 'POS_WRONG_STATE: this bill is already %', v_o.status; end if;
    if not public.rst_bill_ready(v_o.status, v_o.table_id, v_o.channel) then
      raise exception 'POS_WRONG_STATE: %', case when v_o.table_id is null then 'send the order to the kitchen first' else 'generate the bill first' end; end if;
    if exists (select 1 from public.rst_bill_splits where order_id = v_o.id and status = 'active') then
      raise exception 'POS_WRONG_STATE: this bill is split; take each guest''s part'; end if;
    v_amt := v_o.total - public.rst_paid(v_o.id);
    if v_amt <= 0 then raise exception 'POS_WRONG_STATE: nothing is due on this bill'; end if;
  end if;

  perform public.pos_check_tender(v_method, v_amt, v_tendered);
  perform public.pos_record_payment(jsonb_build_object('order_id', v_o.id, 'amount', v_amt, 'method', v_method,
    'reference', nullif(btrim(coalesce(p->>'reference', '')), ''), 'idempotency_key', v_pkey,
    'expected_updated_at', case when v_part.id is null then nullif(p->>'expected_updated_at', '') end));
  perform public.pos_record_tender(v_o.id, v_pkey, v_tendered);
  select id into v_pay from public.payments where order_id = v_o.id and idempotency_key = v_pkey;
  if v_part.id is not null then
    update public.rst_bill_parts set status = 'paid', payment_id = v_pay, pay_key = v_key, paid_at = now() where id = v_part.id;
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_o.organization_id, v_o.id, 'bill_part_paid', v_part.label || ' paid ' || v_amt || ' by ' || v_method, 'pos',
            jsonb_build_object('by', auth.uid(), 'part_id', v_part.id, 'payment_id', v_pay));
    if not exists (select 1 from public.rst_bill_parts where split_id = v_split.id and status = 'open') then
      update public.rst_bill_splits set status = 'completed', closed_at = now() where id = v_split.id;
    end if;
  end if;
  return public.rst_pay_result(v_o.id, v_pay, v_part.id, false);
end $function$;

CREATE OR REPLACE FUNCTION public.rst_bill_split(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_mode text := p->>'mode';
  v_parts jsonb := coalesce(p->'parts', '[]'::jsonb); v_n int; v_due numeric(10,2); v_paid numeric; v_old public.rst_bill_splits%rowtype; v_split uuid;
  v_i int; v_part jsonb; v_amt numeric(10,2); v_sum numeric(10,2) := 0; v_amounts numeric[] := '{}'; v_ids uuid[]; v_all uuid[];
  v_gross numeric; v_g numeric; v_method text; v_label text; v_ex public.rst_bill_splits%rowtype;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  v_o := public.rst_bill_lock(nullif(p->>'order_id', '')::uuid);
  if not public.rst_can_pay() then raise exception 'POS_FORBIDDEN: your role cannot take payments'; end if;
  select * into v_ex from public.rst_bill_splits where organization_id = v_o.organization_id and idempotency_key = v_key;
  if found then
    if v_ex.order_id <> v_o.id then raise exception 'POS_IDEMPOTENCY_MISMATCH: this key was already used for a different bill'; end if;
    return public.rst_split_json(v_ex.id) || jsonb_build_object('replayed', true);
  end if;
  if v_o.status in ('paid', 'cancelled') then raise exception 'POS_WRONG_STATE: this bill is already %', v_o.status; end if;
  if not public.rst_bill_ready(v_o.status, v_o.table_id, v_o.channel) then
      raise exception 'POS_WRONG_STATE: %', case when v_o.table_id is null then 'send the order to the kitchen first' else 'generate the bill first' end; end if;
  if v_mode is null or v_mode not in ('equal', 'item', 'amount') then raise exception 'POS_BAD_REQUEST: split equally, by item or by amount'; end if;
  if jsonb_typeof(v_parts) <> 'array' then raise exception 'POS_BAD_REQUEST: parts must be a list'; end if;
  select * into v_old from public.rst_bill_splits where order_id = v_o.id and status = 'active' for update;
  if found then
    if exists (select 1 from public.rst_bill_parts where split_id = v_old.id and status = 'paid') then
      raise exception 'POS_WRONG_STATE: a guest has already paid; the split cannot be changed'; end if;
    update public.rst_bill_splits set status = 'replaced', closed_at = now() where id = v_old.id;
  end if;
  v_paid := public.rst_paid(v_o.id); v_due := v_o.total - v_paid;
  if v_due <= 0 then raise exception 'POS_WRONG_STATE: nothing is due on this bill'; end if;

  v_n := case when v_mode = 'equal' then coalesce(nullif(p->>'guests', '')::int, jsonb_array_length(v_parts)) else jsonb_array_length(v_parts) end;
  if v_n is null or v_n not between 2 and 20 then raise exception 'POS_BAD_REQUEST: split between 2 and 20 guests'; end if;
  if v_mode <> 'equal' and jsonb_array_length(v_parts) <> v_n then raise exception 'POS_BAD_REQUEST: one part per guest'; end if;
  if v_mode = 'equal' and jsonb_array_length(v_parts) not in (0, v_n) then raise exception 'POS_BAD_REQUEST: one part per guest'; end if;

  if v_mode = 'equal' then
    -- to the paisa; the last guest takes the paise left over, so the parts always add up to what is due
    for v_i in 1 .. v_n loop
      v_amt := case when v_i < v_n then floor(v_due * 100 / v_n) / 100 else v_due - v_sum end;
      v_amounts := v_amounts || v_amt; v_sum := v_sum + v_amt;
    end loop;
  elsif v_mode = 'amount' then
    for v_i in 1 .. v_n loop
      v_part := v_parts -> (v_i - 1);
      begin v_amt := (v_part->>'amount')::numeric; exception when others then v_amt := null; end;
      if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then raise exception 'POS_BAD_REQUEST: enter an amount for every guest'; end if;
      v_amounts := v_amounts || v_amt; v_sum := v_sum + v_amt;
    end loop;
    if v_sum <> v_due then raise exception 'POS_BAD_REQUEST: the parts add up to % but % is due', v_sum, v_due; end if;
  else
    -- by item: every item of the bill goes to exactly one guest; each guest pays the share of the bill their items make up
    select array_agg(i.id order by i.id), sum(i.unit_price * i.qty) into v_all, v_gross from public.order_items i where i.order_id = v_o.id and i.status <> 'cancelled';
    if v_gross is null or v_gross <= 0 then raise exception 'POS_WRONG_STATE: this bill has no items to split'; end if;
    for v_i in 1 .. v_n loop
      v_part := v_parts -> (v_i - 1);
      begin
        select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(v_part->'item_ids', '[]'::jsonb)) x;
      exception when others then raise exception 'POS_BAD_REQUEST: an item id is not valid'; end;
      if v_ids is null then raise exception 'POS_BAD_REQUEST: give every guest at least one item'; end if;
      if exists (select 1 from unnest(v_ids) u where not (u = any(v_all))) then raise exception 'POS_BAD_REQUEST: an item is not on this bill'; end if;
      select sum(i.unit_price * i.qty) into v_g from public.order_items i where i.id = any(v_ids);
      v_amt := case when v_i < v_n then round(v_due * v_g / v_gross, 2) else v_due - v_sum end;
      if v_amt <= 0 then raise exception 'POS_BAD_REQUEST: a guest''s share comes to nothing; give them another item'; end if;
      v_amounts := v_amounts || v_amt; v_sum := v_sum + v_amt;
      v_parts := jsonb_set(v_parts, array[(v_i - 1)::text, 'item_ids'], to_jsonb(v_ids));
    end loop;
    if (select count(*) from (select jsonb_array_elements_text(e->'item_ids') from jsonb_array_elements(v_parts) e) z) <> cardinality(v_all)
       or (select count(distinct x) from (select jsonb_array_elements_text(e->'item_ids') x from jsonb_array_elements(v_parts) e) z) <> cardinality(v_all) then
      raise exception 'POS_BAD_REQUEST: give every item to exactly one guest'; end if;
  end if;

  insert into public.rst_bill_splits (organization_id, location_id, order_id, mode, due, idempotency_key, created_by)
  values (v_o.organization_id, v_o.location_id, v_o.id, v_mode, v_due, v_key, auth.uid()) returning id into v_split;
  for v_i in 1 .. v_n loop
    v_part := coalesce(v_parts -> (v_i - 1), '{}'::jsonb);
    v_method := coalesce(nullif(v_part->>'method', ''), 'cash');
    if v_method not in ('cash', 'card', 'upi') then raise exception 'POS_BAD_REQUEST: each guest pays by cash, card or UPI'; end if;
    v_label := coalesce(nullif(btrim(coalesce(v_part->>'label', '')), ''), 'Guest ' || v_i);
    if char_length(v_label) > 40 then raise exception 'POS_BAD_REQUEST: a guest name can be up to 40 characters'; end if;
    insert into public.rst_bill_parts (split_id, organization_id, order_id, part_no, label, amount, method, item_ids)
    values (v_split, v_o.organization_id, v_o.id, v_i, v_label, v_amounts[v_i], v_method,
            case when v_mode = 'item' then array(select jsonb_array_elements_text(v_part->'item_ids')::uuid) else '{}'::uuid[] end);
  end loop;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, 'bill_split', v_o.display_no || ' split ' || case v_mode when 'equal' then 'equally' when 'item' then 'by item' else 'by amount' end
          || ' between ' || v_n || ' guests', 'pos', jsonb_build_object('by', auth.uid(), 'split_id', v_split, 'due', v_due));
  return public.rst_split_json(v_split) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.rst_admin__guard(o orders, p jsonb, p_action text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.pos_org_is_restaurant(o.organization_id) then return null; end if;
  -- 0649: a held takeaway / delivery bill is a cart until a payment is taken on it
  if o.status = 'awaiting_payment' and (o.table_id is not null or exists (select 1 from public.payments y where y.order_id = o.id)) then
    return public.rst_admin__consume(o, p, p_action, 'this bill is generated, so it can only be changed with an admin PIN');
  end if;
  if p_action = 'order_cancel' and exists (select 1 from public.kot_tickets k where k.order_id = o.id) then
    return public.rst_admin__consume(o, p, p_action, 'this order went to the kitchen, so it can only be cancelled with an admin PIN');
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.rst_bill_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid; v_org uuid := public.current_org_id(); t public.dining_tables%rowtype; v_grp uuid[]; mg jsonb;
  v_area text; v_pay boolean; v_orders jsonb; v_first jsonb; c public.orders%rowtype;
begin
  if nullif(p->>'table_id', '') is null and nullif(p->>'order_id', '') is not null then
    -- 0649: a takeaway or delivery bill (no table), by its order
    select * into c from public.orders where id = (p->>'order_id')::uuid;
    if not found or c.organization_id is distinct from v_org or c.table_id is not null or c.channel not in ('pickup', 'delivery')
       or not public.pos_org_is_restaurant(c.organization_id) then raise exception 'POS_NOT_FOUND: bill not found'; end if;
    v_loc := public.tbl_guard(p || jsonb_build_object('location_id', c.location_id), 'read');
    v_pay := public.rst_can_pay();
    v_orders := case when public.tbl_order_open(c.status, c.paid_at) then jsonb_build_array(public.rst_bill_order_json(c.id)) else '[]'::jsonb end;
  else
  v_loc := public.tbl_guard(p, 'read');
  t := public.tbl_get(v_org, v_loc, (p->>'table_id')::uuid);
  mg := public.tbl_merge_json(v_org, t.id);
  v_grp := public.tbl_group(v_org, t.id);
  v_pay := public.rst_can_pay();
  select a.name into v_area from public.dining_areas a where a.id = t.area_id;
  select coalesce(jsonb_agg(public.rst_bill_order_json(o.id) order by o.created_at, o.id), '[]'::jsonb) into v_orders
    from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)
     and public.location_is_allowed(o.organization_id, o.location_id);
  end if;
  v_first := v_orders -> 0;
  return jsonb_build_object(
    'table', case when t.id is null then null else jsonb_build_object('id', t.id, 'label', t.label, 'seats', coalesce((mg->>'combined_seats')::int, t.seats), 'area_name', v_area,
                                'main_table_id', coalesce((mg->>'primary_table_id')::uuid, t.id), 'labels', coalesce(mg->'labels', jsonb_build_array(t.label))) end,
    'counter', case when c.id is null then null else jsonb_build_object('order_id', c.id, 'display_no', c.display_no, 'channel', c.channel,
                'label', case c.channel when 'pickup' then 'Takeaway' else 'Delivery' end, 'customer', c.customer_name) end,
    'location', (select jsonb_build_object('id', l.id, 'name', l.name) from public.locations l where l.id = v_loc),
    'orders', v_orders,
    'current_order_id', v_first->'id',
    'receipt_printer', (select x.name from public.pos_printers x where x.organization_id = v_org and x.printer_type = 'receipt' and x.active and x.deleted_at is null
                          and (x.location_id is null or x.location_id = v_loc) order by (x.location_id is null), x.created_at limit 1),
    'can', jsonb_build_object(
      'pay', v_pay and v_first is not null and (v_first->>'bill_generated')::boolean,
      'split', v_pay and v_first is not null and (v_first->>'bill_generated')::boolean and coalesce((v_first->'split'->>'paid_parts')::int, 0) = 0
               and (v_first->'payments') = '[]'::jsonb,
      'coupon', v_pay and v_first is not null and (v_first->'payments') = '[]'::jsonb and v_first->>'coupon_code' is null
                and coalesce(v_first->'split'->>'status', '') <> 'active',
      'note', v_first is not null and (public.has_permission(v_org, 'order', 'place', v_loc) or public.has_permission(v_org, 'order', 'update_status', v_loc))),
    'unavailable', jsonb_build_object(
      'pay', case when not v_pay then 'Your role cannot take payments.' when v_first is null then case when c.id is null then 'No open bill on this table.' else 'This bill is already settled.' end
                  when not (v_first->>'bill_generated')::boolean then case when c.id is null then 'Generate the bill first.' else 'Send the order to the kitchen first.' end end,
      'coupon', case when v_first is null then null when v_first->>'coupon_code' is not null then 'A discount code is already on this bill.'
                     when (v_first->'payments') <> '[]'::jsonb then 'A payment was already taken; a code can no longer be added.'
                     when coalesce(v_first->'split'->>'status', '') = 'active' then 'The bill is split; add the code before splitting.' end));
end $function$;

notify pgrst, 'reload schema';
commit;
