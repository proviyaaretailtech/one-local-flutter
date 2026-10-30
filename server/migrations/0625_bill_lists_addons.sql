-- 0625: the bill slip, the printed bill, checkout and the receipt list each dish's add-ons and combos under it (founder, 29 Oct 2026), with
-- their price; a combo's dishes (₹0 rows that are there for the kitchen) are marked "in_combo" so the bill does not list them twice.
-- rst_bill_order_json feeds rst_bill_view and rst_receipt_view. Safe to run again.

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone,
    'bill_generated', o.status = 'awaiting_payment',
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
$$;
