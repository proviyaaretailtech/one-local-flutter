-- 0615: send a purchase order to the supplier (founder, 28 Oct 2026). The app opens WhatsApp or SMS on the phone with the order; the database
-- records that it was sent (when, how, the number masked) so the order shows "Sent to supplier". Safe to run again.
--   * pur_po_json: the supplier's phone, 'sent' (the last send, and how many), and the 'send' action on an Approved / Partially Received order
--     for whoever may record purchases.
--   * pur_po_send({id, channel: whatsapp | sms, to}): checks the order and the number (10-digit Indian mobile, or +91 / 91 and 10 digits), logs
--     purchase_events 'po_sent', and saves the number on the supplier when the supplier had none. Returns the order.

CREATE OR REPLACE FUNCTION public.pur_po_json(po pos_purchase_orders)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare r record; v_lines jsonb := '[]'::jsonb; v_est bigint := 0; v_sub bigint := 0; v_tax bigint := 0; v_otax bigint := 0; v_ordered bigint; v_acc bigint; v_t bigint; v_ot bigint; v_tag text;
  v_item jsonb; v_rc record; v_sup jsonb; v_received_at timestamptz; v_doc uuid; v_doc_status text; v_doc_no text; v_header_rate boolean; v_rate numeric; v_over numeric; v_cost bigint;
  v_acts jsonb := '[]'::jsonb; v_total bigint; v_mine boolean; v_can_rec boolean; v_can_po boolean; v_can_appr boolean; v_creator uuid;
begin
  v_header_rate := not exists (select 1 from public.pos_purchase_order_lines l where l.organization_id = po.organization_id and l.po_number = po.number
                                  and l.location_id is not distinct from po.location_id and l.deleted_at is null and l.gst_pct > 0) and coalesce(po.tax_pct, 0) > 0;
  for r in select * from public.pos_purchase_order_lines l
            where l.organization_id = po.organization_id and l.po_number = po.number and l.deleted_at is null
              and l.location_id is not distinct from po.location_id order by l.id loop
    v_cost := coalesce(r.unit_cost_minor, public.pur_minor(r.unit_cost));
    v_rate := case when v_header_rate then po.tax_pct::numeric else r.gst_pct end;
    v_ordered := round(r.ordered_qty::numeric * v_cost)::bigint;
    v_acc := round(r.received_qty::numeric * v_cost)::bigint;
    v_t := round(v_acc * v_rate / 100)::bigint;
    v_ot := round(v_ordered * v_rate / 100)::bigint;
    v_est := v_est + v_ordered; v_sub := v_sub + v_acc; v_tax := v_tax + v_t; v_otax := v_otax + v_ot;
    select coalesce(sum(x.over_qty), 0) into v_over from public.purchase_receipt_lines x where x.po_line_row_id = r.row_id;
    v_tag := case when r.received_qty = 0 and r.rejected_qty = 0 and v_over = 0 then null
                  when r.rejected_qty > 0 or v_over > 0 or (po.status = 'Received' and r.received_qty < r.ordered_qty) then 'discrepancy'
                  when r.received_qty >= r.ordered_qty then 'approved' else null end;
    v_item := null;
    if r.material_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select jsonb_build_object('id', i.id, 'name', i.name, 'sku', i.sku, 'unit', i.unit) into v_item
        from public.inventory_items i where i.id = r.material_id::uuid and i.organization_id = po.organization_id;
    end if;
    select x.lot_code, x.expiry_date into v_rc from public.purchase_receipt_lines x
     where x.po_line_row_id = r.row_id order by x.posted_at desc, x.id desc limit 1;
    v_lines := v_lines || jsonb_build_object(
      'id', r.row_id, 'line_no', r.id, 'item', v_item, 'material_id', r.material_id, 'name', r.material_name, 'code', r.code, 'unit', r.unit,
      'ordered_qty', r.ordered_qty, 'received_qty', r.received_qty, 'accepted_qty', r.received_qty, 'rejected_qty', r.rejected_qty, 'over_qty', v_over,
      'unit_cost_minor', v_cost, 'gst_pct', v_rate,
      'ordered_minor', v_ordered, 'accepted_minor', v_acc, 'tax_minor', v_t, 'tag', v_tag,
      'lot_code', nullif(v_rc.lot_code, ''), 'expiry_date', v_rc.expiry_date);
  end loop;
  v_total := v_est + v_otax;
  select max(x.posted_at) into v_received_at from public.purchase_receipt_lines x where x.po_row_id = po.row_id;
  select jsonb_build_object('id', s.id, 'name', s.name, 'rating', s.rating, 'payment_terms', s.payment_terms, 'phone', nullif(btrim(s.phone), '')) into v_sup
    from public.pos_suppliers s where s.organization_id = po.organization_id and s.id = po.supplier_id and s.deleted_at is null
   order by (s.location_id is not distinct from po.location_id) desc limit 1;
  select d.id, d.status, d.doc_no into v_doc, v_doc_status, v_doc_no from public.inventory_documents d
   where d.organization_id = po.organization_id and d.doc_type = 'receipt' and d.po_ref = po.number and d.location_id is not distinct from po.location_id and d.status in ('draft', 'review')
   order by d.created_at limit 1;
  v_can_po := public.has_permission(po.organization_id, 'purchasing', 'record', po.location_id);
  v_can_appr := public.has_permission(po.organization_id, 'purchasing', 'approve_po', po.location_id);
  v_mine := po.created_by = auth.uid()::text;
  v_can_rec := po.status in ('Approved', 'Partially Received') and v_can_po and public.has_permission(po.organization_id, 'inventory', 'record', po.location_id);
  if po.status = 'Draft' and v_can_po then v_acts := v_acts || '["submit", "cancel"]'::jsonb; end if;
  if po.status = 'Pending' then
    if v_can_appr and (not v_mine or (v_total <= public.pur_self_approval_limit_minor()
         and public.pur_self_approved_today(po.organization_id, auth.uid(), po.supplier_id) + v_total <= public.pur_self_approval_limit_minor())) then v_acts := v_acts || '["approve"]'::jsonb; end if;
    if v_can_appr then v_acts := v_acts || '["reject"]'::jsonb; end if;
    if v_can_po or v_can_appr then v_acts := v_acts || '["cancel"]'::jsonb; end if;
  end if;
  if po.status in ('Approved', 'Partially Received') and v_can_appr then v_acts := v_acts || '["cancel"]'::jsonb; end if;
  if v_can_rec then v_acts := v_acts || '["receive"]'::jsonb; end if;
  -- 0615: an approved order can be sent to the supplier (WhatsApp / SMS) by whoever may record purchases
  if po.status in ('Approved', 'Partially Received') and v_can_po then v_acts := v_acts || '["send"]'::jsonb; end if;
  begin v_creator := po.created_by::uuid; exception when others then v_creator := null; end;
  return jsonb_build_object(
    'id', po.row_id, 'number', po.number, 'status', po.status, 'order_date', po.order_date, 'expected_delivery', po.expected_delivery,
    'overdue', po.status in ('Approved', 'Partially Received') and po.expected_delivery < now(), 'received_at', v_received_at, 'notes', po.notes,
    'location_id', po.location_id, 'supplier', coalesce(v_sup, jsonb_build_object('id', po.supplier_id, 'name', po.supplier_id)),
    'created_by', public.inv_person(po.organization_id, v_creator), 'tax_pct', po.tax_pct,
    'lines', v_lines,
    'totals', jsonb_build_object('estimated_minor', v_est, 'ordered_tax_minor', v_otax, 'ordered_total_minor', v_total,
                                 'subtotal_minor', v_sub, 'tax_minor', v_tax, 'total_minor', v_sub + v_tax),
    'self_approval_limit_minor', public.pur_self_approval_limit_minor(),
    'open_receipt', case when v_doc is null then null else jsonb_build_object('id', v_doc, 'status', v_doc_status, 'doc_no', v_doc_no) end,
    'sent', (select jsonb_build_object('at', e.created_at, 'channel', e.meta->>'channel', 'to', e.meta->>'to', 'times', (select count(*) from public.purchase_events c where c.po_row_id = po.row_id and c.action = 'po_sent'))
               from public.purchase_events e where e.po_row_id = po.row_id and e.action = 'po_sent' order by e.created_at desc, e.id desc limit 1),
    'allowed_actions', v_acts);
end $$

;

create or replace function public.pur_po_send(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); po public.pos_purchase_orders%rowtype; v_ch text := p->>'channel';
  v_digits text := regexp_replace(coalesce(p->>'to', ''), '\D', '', 'g');
begin
  if auth.uid() is null or v_org is null then raise exception 'PUR_FORBIDDEN: sign in to a business first'; end if;
  select * into po from public.pos_purchase_orders o where o.row_id = nullif(p->>'id', '')::uuid and o.organization_id = v_org and o.deleted_at is null for update;
  if not found or not public.location_is_allowed(v_org, po.location_id) then raise exception 'PUR_NOT_FOUND: purchase order not found'; end if;
  if not public.has_permission(v_org, 'purchasing', 'record', po.location_id) then raise exception 'PUR_FORBIDDEN: your role cannot send purchase orders'; end if;
  if v_ch is null or v_ch not in ('whatsapp', 'sms') then raise exception 'PUR_BAD_REQUEST: send by whatsapp or sms'; end if;
  if po.status not in ('Approved', 'Partially Received') then raise exception 'PUR_WRONG_STATE: % is % and cannot be sent; send it once it is approved', po.number, po.status; end if;
  if length(v_digits) = 12 and left(v_digits, 2) = '91' then v_digits := right(v_digits, 10); end if;
  if v_digits !~ '^[6-9][0-9]{9}$' then raise exception 'PUR_BAD_REQUEST: enter the supplier''s 10-digit mobile number'; end if;
  update public.pos_suppliers s set phone = v_digits, server_updated_at = now(), updated_by = auth.uid()
   where s.organization_id = v_org and s.id = po.supplier_id and s.deleted_at is null and coalesce(btrim(s.phone), '') = '';
  insert into public.purchase_events (organization_id, location_id, po_row_id, action, actor, meta)
  values (v_org, po.location_id, po.row_id, 'po_sent', auth.uid(),
          jsonb_build_object('number', po.number, 'channel', v_ch, 'to', repeat('*', 6) || right(v_digits, 4), 'supplier_id', po.supplier_id));
  return public.pur_po_json(po);
end $$;

revoke all on function public.pur_po_send(jsonb) from public, anon;
grant execute on function public.pur_po_send(jsonb) to authenticated, service_role;
