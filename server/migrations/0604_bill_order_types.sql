-- 0604: the Bill's Dine in / Takeaway / Delivery pills and the veg / non-veg mark on its menu squares.
--   * pos_sell_catalog answers each dish's food_type (veg / non_veg / egg) as well; nothing else changes.
--   * pos_counter_order(p) places a Takeaway (service type pickup) or Delivery order from the Bill without a table:
--     the same pos_place_order as every other order (prices, GST, role), in the outlet the screen looks at, unpaid.
--     send true fires a KOT at once (tbl_kot_fire, the same ticket a table gets); false holds it "in billing".
--     Delivery needs the customer's phone and address; the address is kept on the order's notes.

create or replace function public.pos_sell_catalog(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg')) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $$;

create or replace function public.pos_counter_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id();
  v_type text := coalesce(nullif(p->>'service_type', ''), 'pickup'); v_send boolean; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  v_name text := nullif(btrim(coalesce(p->>'customer_name', '')), ''); v_phone text := nullif(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), '');
  v_addr text := nullif(btrim(coalesce(p->>'address', '')), ''); v_notes text := nullif(btrim(coalesce(p->>'notes', '')), '');
  v_res jsonb; v_id uuid; v_kot jsonb;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an Idempotency-Key is needed so a retry never places the order twice'; end if;
  if v_type not in ('pickup', 'delivery') then raise exception 'POS_BAD_REQUEST: choose Takeaway or Delivery'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'POS_BAD_REQUEST: send is true or false'; end;
  if v_type = 'delivery' then
    if v_phone is null or char_length(v_phone) < 10 then raise exception 'POS_BAD_REQUEST: enter the customer''s phone number for a delivery'; end if;
    if v_addr is null then raise exception 'POS_BAD_REQUEST: enter the delivery address'; end if;
  end if;
  if char_length(coalesce(v_addr, '')) > 300 then raise exception 'POS_BAD_REQUEST: the address can be up to 300 characters'; end if;

  v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', v_type, 'placed_by', 'pos', 'fire_kot', false,
    'idempotency_key', v_key, 'lines', p->'lines', 'customer_name', v_name, 'customer_phone', v_phone,
    'notes', nullif(concat_ws(' · ', case when v_addr is not null then 'Deliver to: ' || v_addr end, v_notes), '')));
  v_id := (v_res->>'id')::uuid;
  if coalesce((v_res->>'replayed')::boolean, false) then return jsonb_build_object('order_id', v_id, 'replayed', true, 'order', v_res); end if;
  if v_loc is not null then update public.orders set location_id = v_loc where id = v_id; end if;
  if v_send then v_kot := public.tbl_kot_fire(v_id); end if;
  return jsonb_build_object('order_id', v_id, 'replayed', false, 'held', not v_send, 'service_type', v_type, 'kot', v_kot,
    'order', jsonb_build_object('display_no', v_res->>'display_no', 'total', (v_res->>'total')::numeric, 'status', case when v_send then 'sent_to_kitchen' else 'in_billing' end));
end $$;

revoke all on function public.pos_counter_order(jsonb) from public, anon;
grant execute on function public.pos_counter_order(jsonb) to authenticated, service_role;
