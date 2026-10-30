-- 0629: one order's page (pos_order_view) as both sides changed it since 26 Oct 2026, merged:
--   * the store team (on hosted, "packed photo"): the packed-bag photo or why there is none, and whether the store asks for one;
--   * 0606 / 0611 (restaurant): each dish's name with its size, and whether it is a takeaway dish.
-- Only where the packed-photo tables exist (hosted); elsewhere the 0611 version stays.
do $do$
begin
  if to_regclass('public.order_packed_photos') is null or to_regclass('public.rr_store_settings') is null then
    raise notice '0629: no packed-photo tables here; pos_order_view left as it is';
    return;
  end if;
  execute $sql$
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
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'takeaway', i.is_takeaway, 'qty', i.qty,
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
    -- packed-order photos (0029 packed photo): the latest photo or the reason there is none, and whether the store asks for one
    'packed_photo', (select jsonb_build_object('id', ph.id, 'has_photo', ph.path is not null, 'skip_reason', ph.skip_reason, 'at', ph.created_at)
                     from public.order_packed_photos ph where ph.order_id = v_o.id order by ph.created_at desc limit 1),
    'photo_required', coalesce((select s.dispatch_photo from public.rr_store_settings s where s.organization_id = v_o.organization_id), true),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

  $sql$;
end $do$;
