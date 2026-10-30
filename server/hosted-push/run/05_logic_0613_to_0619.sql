-- ==========================================================================================================================
-- HOSTED PUSH piece 05 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0613_menu_price_save.sql
-- 0613: edit a dish's selling price from its recipe (founder, 28 Oct 2026), and, for a dish with sizes, each size's price. Safe to run again.
--   * menu_price_save({id, version, price, sizes?: [{id, price}]}): the dish's price, and each listed size's. The dish's version guards
--     against a change made on another phone (the same rule as menu_item_settings_save). A size must be the dish's; prices are above zero.
--     The default size (Small) always keeps the dish's price, so the Bill and the Menu agree.
--   * menu_item_settings answers the dish's sizes (id, name, price, recipe_factor) as well.


create or replace function public.menu_price_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype; v_price numeric; s jsonb; v_sp numeric;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null or (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;
  begin v_price := round((p->>'price')::numeric, 2); exception when others then v_price := null; end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  if p ? 'sizes' and jsonb_typeof(p->'sizes') <> 'array' then raise exception 'POS_BAD_REQUEST: sizes is a list'; end if;
  for s in select * from jsonb_array_elements(coalesce(p->'sizes', '[]'::jsonb)) loop
    if not exists (select 1 from public.menu_item_variants v where v.id = nullif(s->>'id', '')::uuid and v.menu_item_id = m.id) then
      raise exception 'POS_BAD_REQUEST: that size is not on %', m.name; end if;
    begin v_sp := round((s->>'price')::numeric, 2); exception when others then v_sp := null; end;
    if v_sp is null or v_sp <= 0 or v_sp > 1000000 then raise exception 'POS_BAD_REQUEST: enter a price above zero for every size'; end if;
    update public.menu_item_variants set price = v_sp where id = (s->>'id')::uuid;
  end loop;
  update public.menu_items set price = v_price, updated_at = now() where id = m.id;
  update public.menu_item_variants set price = v_price where menu_item_id = m.id and is_default;   -- Small = the dish's price
  return public.menu_item_settings(jsonb_build_object('id', m.id));
end $$;
revoke all on function public.menu_price_save(jsonb) from public, anon;
grant execute on function public.menu_price_save(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.menu_item_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  return jsonb_build_object('id', m.id, 'version', m.edit_version, 'name', m.name, 'price_minor', round(m.price * 100)::bigint,
    'sizes', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'price', v.price, 'recipe_factor', v.recipe_factor, 'is_default', v.is_default) order by v.sort_order, v.price), '[]'::jsonb)
              from public.menu_item_variants v where v.menu_item_id = m.id),
    'category_id', m.category_id, 'category', (select name from public.menu_categories where id = m.category_id),
    'food_type', m.food_type, 'course', m.course, 'station', m.station, 'prep_minutes', m.prep_minutes, 'is_recommended', m.is_recommended,
    'sku', m.sku, 'is_available', m.is_available, 'image_url', m.image_url, 'description', m.description,
    'addon_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_addon_groups where menu_item_id = m.id), '[]'),
    'recipe', public.mb_recipe_json(v_org, m.id) - 'lines',
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                            from public.menu_categories where organization_id = v_org), '[]'),
    'addon_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'addons', (select count(*) from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                              from public.menu_addon_groups g where g.organization_id = v_org and g.active), '[]'),
    'stations', '["main","grill","beverage","dessert","tandoor","chinese"]'::jsonb);
end $function$

;


-- ---- 0614_activity_log.sql
-- 0614: the Activity log in Settings (founder, 28 Oct 2026): the operational timeline that used to sit on the table order page, for every order of
-- the business in one place, newest first. Read only. Safe to run again.
--   p: location_id (optional; null or 'all' = every outlet the user may see), before (optional cursor: the 'at' of the last entry shown),
--      limit (1-100, default 50).
--   answer: entries [{id, at, kind, message, actor, order_id, display_no, table_label, location_name}], more (true when older entries exist).

create or replace function public.rst_activity_log(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_before timestamptz := nullif(p->>'before', '')::timestamptz; v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100); v_rows jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'kind', x.kind, 'message', x.message, 'actor', x.actor, 'order_id', x.order_id,
           'display_no', x.display_no, 'table_label', x.table_label, 'location_name', x.location_name) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_rows
    from (select ev.id, ev.created_at, ev.kind, ev.message, ev.actor, ev.order_id, o.display_no, t.label as table_label, l.name as location_name
            from public.order_events ev
            join public.orders o on o.id = ev.order_id and o.organization_id = v_org
            left join public.dining_tables t on t.id = o.table_id
            left join public.locations l on l.id = o.location_id
           where ev.organization_id = v_org
             and (v_loc is null or o.location_id = v_loc)
             and (o.location_id is null or public.location_is_allowed(v_org, o.location_id))
             and (v_before is null or ev.created_at < v_before)
           order by ev.created_at desc, ev.id desc
           limit v_limit + 1) x;
  return jsonb_build_object('entries', coalesce((select jsonb_agg(e order by ord) from jsonb_array_elements(v_rows) with ordinality as a(e, ord) where ord <= v_limit), '[]'::jsonb),
                            'more', jsonb_array_length(v_rows) > v_limit);
end $$;

revoke all on function public.rst_activity_log(jsonb) from public, anon;
grant execute on function public.rst_activity_log(jsonb) to authenticated, service_role;

-- ---- 0615_po_send.sql
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

-- ---- 0616_menu_subcategories.sql
-- 0616: menu categories and subcategories (founder, 28 Oct 2026). A category may have subcategories, one level deep (Beverages › Cold
-- coffee). Dishes sit in a category or a subcategory. Names stay unique in the business, so a dish's category is still found by name.
--   * menu_categories.parent_id (null = a top category)
--   * menu_category_list(): every category with its parent, order and dish count, and whether this person may edit
--   * menu_category_save({id?, name, parent_id?, sort_order?}): add or rename; set or clear the parent (a parent must be a top category,
--     never itself, and a category that has subcategories stays a top category)
--   * menu_category_delete({id}): only an empty one (no dishes, no subcategories)
--   * rst_menu: each category also says parent_id and parent_name
-- Safe to run again.

alter table public.menu_categories add column if not exists parent_id uuid references public.menu_categories(id) on delete set null;
create index if not exists menu_categories_parent_idx on public.menu_categories (parent_id);

create or replace function public.menu_category_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object(
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'parent_id', c.parent_id, 'sort_order', c.sort_order,
                      'dishes', (select count(*) from public.menu_items i where i.category_id = c.id)) order by c.sort_order, lower(c.name)), '[]'::jsonb)
                   from public.menu_categories c where c.organization_id = v_org));
end $$;

create or replace function public.menu_category_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_parent uuid := nullif(p->>'parent_id', '')::uuid; v_set_parent boolean := p ? 'parent_id';
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter a category (up to 60 characters)'; end if;
  if v_parent is not null then
    if not exists (select 1 from public.menu_categories where id = v_parent and organization_id = v_org) then raise exception 'POS_NOT_FOUND: parent category not found'; end if;
    if exists (select 1 from public.menu_categories where id = v_parent and parent_id is not null) then
      raise exception 'POS_BAD_REQUEST: a subcategory cannot have its own subcategories'; end if;
    if v_parent = v_id then raise exception 'POS_BAD_REQUEST: a category cannot sit under itself'; end if;
    if v_id is not null and exists (select 1 from public.menu_categories where parent_id = v_id) then
      raise exception 'POS_BAD_REQUEST: this category has subcategories, so it stays a main category'; end if;
  end if;
  if exists (select 1 from public.menu_categories where organization_id = v_org and lower(name) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already a category called %', v_name; end if;
  if v_id is null then
    insert into public.menu_categories (organization_id, name, parent_id, sort_order)
    values (v_org, v_name, v_parent, coalesce(nullif(p->>'sort_order', '')::int, (select max(sort_order) + 1 from public.menu_categories where organization_id = v_org), 0))
    returning id into v_id;
  else
    update public.menu_categories set name = v_name, parent_id = case when v_set_parent then v_parent else parent_id end,
           sort_order = coalesce(nullif(p->>'sort_order', '')::int, sort_order)
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: category not found'; end if;
  end if;
  return jsonb_build_object('id', v_id) || public.menu_category_list('{}'::jsonb);
end $$;

create or replace function public.menu_category_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_n int;
begin
  if not exists (select 1 from public.menu_categories where id = v_id and organization_id = v_org) then raise exception 'POS_NOT_FOUND: category not found'; end if;
  select count(*) into v_n from public.menu_items where category_id = v_id;
  if v_n > 0 then raise exception 'POS_CONFLICT: move its % dish% to another category first', v_n, case when v_n = 1 then '' else 'es' end; end if;
  if exists (select 1 from public.menu_categories where parent_id = v_id) then raise exception 'POS_CONFLICT: delete or move its subcategories first'; end if;
  delete from public.menu_categories where id = v_id and organization_id = v_org;
  return public.menu_category_list('{}'::jsonb);
end $$;

revoke all on function public.menu_category_list(jsonb) from public, anon;
revoke all on function public.menu_category_delete(jsonb) from public, anon;
grant execute on function public.menu_category_list(jsonb) to authenticated, service_role;
grant execute on function public.menu_category_delete(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        -- 0616: a subcategory names its parent, so the Menu tab can group it under the parent's pill
        'parent_id', (select pc.parent_id from public.menu_categories pc where pc.id = c.category_id),
        'parent_name', (select pp.name from public.menu_categories pc join public.menu_categories pp on pp.id = pc.parent_id where pc.id = c.category_id),
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price, 'recipe_factor', mv.recipe_factor) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $$

;

-- ---- 0617_kot_table_moved.sql
-- 0617: a table transfer shows on the kitchen tickets (founder, 28 Oct 2026). The KDS and KOT views already read the table from the order,
-- so a moved order shows its new table; now each ticket also says it moved ("T2 → T5", when), so the kitchen and the pass notice.
--   * order_table_move(order): the order's last transfer {from, to, at}, or null
--   * kds_card_json and rst_kot_orders: 'moved'
-- Read only. Safe to run again.

create or replace function public.order_table_move(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('from', coalesce(f.label, '?'), 'to', coalesce(t.label, '?'), 'at', e.created_at)
    from public.order_events e
    left join public.dining_tables f on f.id = nullif(e.meta->>'from', '')::uuid
    left join public.dining_tables t on t.id = nullif(e.meta->>'to', '')::uuid
   where e.order_id = p_order and e.kind = 'table_transferred'
   order by e.created_at desc, e.id desc limit 1
$$;
revoke all on function public.order_table_move(uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'moved', public.order_table_move(o.id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$$

;

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
  if v_st not in ('all', 'preparing', 'ready', 'completed') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and i.status <> 'cancelled'),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 else 3 end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$

;

-- ---- 0618_kds_cancelled.sql
-- 0618: a cancelled order buzzes the KDS (founder, 28 Oct 2026). A ticket used to vanish from the kitchen display without a word when its
-- order was cancelled. kds_queue now also lists the orders cancelled in the last hour that had already gone to the kitchen: number, where
-- it was going, its KOTs and dishes, and when; the KDS sounds an alarm once for each and shows "Stop cooking" until it is dismissed.
--   * kds_cancelled(org, outlet)
--   * kds_queue: 'cancelled'
-- Read only. Safe to run again.

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_queue(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_station text := nullif(btrim(coalesce(p->>'station', '')), ''); v_loc uuid := nullif(p->>'location_id', '')::uuid;
  v_status text := coalesce(nullif(p->>'status', ''), 'all'); v_q text := nullif(lower(btrim(coalesce(p->>'q', ''))), '');
  v_day timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_stats jsonb; v_counts jsonb; v_cards jsonb; v_chips jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_NOT_FOUND: sign in to a business first'; end if;
  if not public.kitchen_can(v_org, 'view') then raise exception 'POS_FORBIDDEN: your role cannot see the kitchen display'; end if;
  if v_status not in ('all', 'new', 'in_progress', 'ready', 'served') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  if v_station is not null and v_station <> 'unassigned' and not exists (select 1 from public.pos_kitchen_stations where organization_id = v_org and key = v_station) then
    raise exception 'POS_NOT_FOUND: station not found'; end if;
  -- one statement, no scratch tables
  with cards as (select * from public.kds_cards(v_org) c where v_loc is null or c.location_id = v_loc),
  vis_all as (select * from cards c where public.kds_visible(c.chip, c.order_status, c.created_at, c.served_at)),
  vis as (select * from vis_all c where v_station is null or c.queue_key = v_station),
  done as (select count(*) n from cards c where c.chip = 'served' and c.served_at >= v_day and (v_station is null or c.queue_key = v_station)),
  shown as (
    select b.ticket_id, b.queue_key, b.chip, b.priority, b.created_at from vis b
     where (v_status = 'all' or b.chip = v_status)
       and (v_q is null or lower(b.display_no) like '%' || v_q || '%' or exists (select 1 from public.order_items i where i.kot_ticket_id = b.ticket_id and i.status <> 'cancelled'
              and public.kitchen_queue_key(v_org, i.station) = b.queue_key and position(v_q in lower(i.name)) > 0))
     order by (b.chip = 'served'), (b.priority = 'urgent') desc, b.created_at limit 100)
  select jsonb_build_object(
           'queue_critical', count(*) filter (where chip in ('new', 'in_progress') and priority = 'urgent'),
           'pending', count(*) filter (where chip in ('new', 'in_progress')),
           'dine_in', count(*) filter (where chip in ('new', 'in_progress') and channel = 'dine_in'),
           'online_delivery', count(*) filter (where chip in ('new', 'in_progress') and channel in ('delivery', 'online', 'swiggy', 'zomato')),
           'delayed', count(*) filter (where chip in ('new', 'in_progress') and created_at < now() - interval '15 minutes'),
           'completed_today', (select n from done)),
         jsonb_build_object('all', count(*), 'new', count(*) filter (where chip = 'new'), 'in_progress', count(*) filter (where chip = 'in_progress'),
           'ready', count(*) filter (where chip = 'ready'), 'served', count(*) filter (where chip = 'served')),
         coalesce((select jsonb_agg(public.kds_card_json(sh.ticket_id, sh.queue_key) order by (sh.chip = 'served'), (sh.priority = 'urgent') desc, sh.created_at) from shown sh), '[]'),
         -- chips: active stations, a station that was switched off but still has cards, and Unassigned when some card has no station
         coalesce((select jsonb_agg(jsonb_build_object('key', x.key, 'name', x.name) order by x.ord, x.name) from (
              select s.key, s.name, s.sort_order ord from public.pos_kitchen_stations s
               where s.organization_id = v_org and (s.active or s.key in (select queue_key from vis_all))
              union all select 'unassigned', 'Unassigned', 1000000 where exists (select 1 from vis_all where queue_key = 'unassigned')) x), '[]')
    into v_stats, v_counts, v_cards, v_chips from vis;
  return jsonb_build_object('live', (v_counts->>'all')::int, 'station', v_station, 'stats', v_stats, 'counts', v_counts, 'tickets', v_cards, 'stations', v_chips,
    'delayed_after_minutes', 15, 'can', jsonb_build_object('act', public.has_permission(v_org, 'order', 'update_status')),
    -- 0618: orders cancelled in the last hour after they reached the kitchen, so the KDS buzzes and says stop cooking
    'cancelled', public.kds_cancelled(v_org, v_loc));
end $$

;

-- ---- 0619_channel_delivery.sql
-- 0619: delivery updates on online orders (founder, 29 Oct 2026). For an order in progress or out for delivery, the restaurant moves it on:
--   ready      the food is packed and waiting (OneLocal: accepted → packed; the kitchen's dishes are ready)
--   out        out for delivery, with the rider's name and number and how long it will take (OneLocal and phone orders; Swiggy and Zomato
--              riders are theirs)
--   delivered  handed to the customer, or for Swiggy / Zomato picked up by their rider
-- Each update is recorded on the order (order_events: the Activity log) and the online orders list shows it with the rider.
--   * pos_order_delivery: the delivery's stage, rider and time, one row per order
--   * rst_channel_delivery({order_id, step, rider_name?, rider_phone?, eta_minutes?})
--   * rst_channel_orders: stage follows the delivery; each order says 'delivery'
-- Safe to run again.

create table if not exists public.pos_order_delivery (
  order_id uuid primary key references public.orders(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  stage text not null check (stage in ('out', 'delivered')),
  rider_name text check (rider_name is null or char_length(rider_name) <= 60),
  rider_phone text check (rider_phone is null or rider_phone ~ '^[6-9][0-9]{9}$'),
  eta_minutes int check (eta_minutes is null or eta_minutes between 1 and 240),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.pos_order_delivery enable row level security;
revoke all on public.pos_order_delivery from public, anon, authenticated;

create or replace function public.rst_channel_delivery(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; d public.pos_order_delivery%rowtype;
  v_step text := p->>'step'; v_src text; v_stage text; v_rider text := nullif(btrim(coalesce(p->>'rider_name', '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p->>'rider_phone', ''), '\D', '', 'g'), ''); v_eta int := nullif(p->>'eta_minutes', '')::int; v_msg text;
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
    if x.id is not null and x.status in ('accepted', 'packed', 'out') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'out' then 'delivered' else 'delivery_sync_delivered' end);
      update public.ol_orders set status = 'delivered' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, updated_at, updated_by) values (o.id, v_org, 'delivered', now(), auth.uid())
    on conflict (order_id) do update set stage = 'delivered', updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || case when v_src in ('swiggy', 'zomato') then ' picked up by the ' || initcap(v_src) || ' rider' else ' delivered' end;
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
          'delivery', case when o.dstage is null then null else jsonb_build_object('stage', o.dstage, 'rider_name', o.rider_name, 'rider_phone', o.rider_phone, 'eta_minutes', o.eta_minutes, 'at', o.d_at) end
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$

;

notify pgrst, 'reload schema';
commit;
