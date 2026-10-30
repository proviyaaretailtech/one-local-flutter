-- 0605: "200 can be made" on every dish (founder, 27 Oct 2026). How many of a dish the kitchen can still make, from its recipe (0600:
-- menu_item_recipes, with wastage) and each ingredient's stock on hand: the smallest floor(on hand / one serving) over its ingredients.
-- Orders already take their ingredients off stock when they go to the kitchen (order_stock_consume), so the count falls by one per dish
-- sent, and comes back if the order is cancelled. Read only. Safe to run again.
--   * menu_can_make(org, dish): the count; null when the dish has no recipe, or none of its ingredients has ever been stocked
--     (as 0601: a new business would otherwise see every dish at 0). Never below 0.
--   * pos_sell_catalog (the Bill's menu) answers can_make per dish; menu_stock_signals (the Menu tab) answers a can_make list.

begin;

create or replace function public.menu_can_make(p_org uuid, p_dish uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, min(floor(public.mb_on_hand(p_org, mr.inventory_item_id) / (mr.qty_per_unit * (1 + coalesce(mr.wastage_pct, 0) / 100)))))::int
    from public.menu_item_recipes mr
   where mr.organization_id = p_org and mr.menu_item_id = p_dish and mr.qty_per_unit > 0
     and exists (select 1 from public.stock_movements m where m.organization_id = p_org and m.inventory_item_id = mr.inventory_item_id)
$$;
revoke all on function public.menu_can_make(uuid, uuid) from public, anon;

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
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $$;

create or replace function public.menu_stock_signals(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_items jsonb := '[]'; r record; v_state text; v_ing text; l record; v_on numeric;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  for r in select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org loop
    v_state := null; v_ing := null;
    for l in select mr.qty_per_unit, mr.wastage_pct, i.id, i.name, i.reorder_level
               from public.menu_item_recipes mr join public.inventory_items i on i.id = mr.inventory_item_id
              where mr.menu_item_id = r.menu_item_id and mr.organization_id = v_org
                and exists (select 1 from public.stock_movements m where m.organization_id = v_org and m.inventory_item_id = i.id)
              order by mr.is_key desc, i.name loop
      v_on := public.mb_on_hand(v_org, l.id);
      if v_on < l.qty_per_unit * (1 + l.wastage_pct / 100) then
        v_state := 'out'; v_ing := l.name; exit;
      elsif l.reorder_level > 0 and v_on <= l.reorder_level and v_state is null then
        v_state := 'low'; v_ing := l.name;
      end if;
    end loop;
    if v_state is not null then
      v_items := v_items || jsonb_build_object('menu_item_id', r.menu_item_id, 'state', v_state, 'ingredient', v_ing);
    end if;
  end loop;
  return jsonb_build_object('items', v_items,
    'can_make', (select coalesce(jsonb_agg(jsonb_build_object('menu_item_id', d.menu_item_id, 'can_make', public.menu_can_make(v_org, d.menu_item_id))), '[]'::jsonb)
                   from (select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org) d));
end $$;

revoke all on function public.menu_stock_signals(jsonb) from public, anon;
grant execute on function public.menu_stock_signals(jsonb) to authenticated, service_role;

commit;
