-- 0613: edit a dish's selling price from its recipe (founder, 28 Oct 2026), and, for a dish with sizes, each size's price. Safe to run again.
--   * menu_price_save({id, version, price, sizes?: [{id, price}]}): the dish's price, and each listed size's. The dish's version guards
--     against a change made on another phone (the same rule as menu_item_settings_save). A size must be the dish's; prices are above zero.
--     The default size (Small) always keeps the dish's price, so the Bill and the Menu agree.
--   * menu_item_settings answers the dish's sizes (id, name, price, recipe_factor) as well.

begin;

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

commit;
