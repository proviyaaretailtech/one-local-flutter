-- 0626: a recipe for an add-on (a topping made of several ingredients), kept in the recipe master next to the dishes (founder, 29 Oct 2026).
--   * menu_addon_recipes: an add-on's ingredients, quantity per add-on, wastage, key flag.
--   * rcp_list: + 'addons' (every add-on with its recipe figures); rcp_view / rcp_save take "addon_id" instead of "menu_item_id".
--   * Saving an add-on's recipe sets the add-on's main ingredient (0624) to its key (or first) line, so the add-on master shows it.
--   * order_stock_consume: a billed add-on uses its recipe; an add-on without one still uses its single ingredient (0624).
-- Safe to run again.

create table if not exists public.menu_addon_recipes (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  addon_id uuid not null references public.menu_addons(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
  qty_per_unit numeric(12,4) not null check (qty_per_unit > 0 and qty_per_unit <= 100000),
  wastage_pct numeric(5,2) not null default 0 check (wastage_pct between 0 and 90),
  is_key boolean not null default false,
  note text check (note is null or char_length(note) <= 200),
  primary key (addon_id, inventory_item_id)
);
alter table public.menu_addon_recipes enable row level security;
revoke all on public.menu_addon_recipes from anon, authenticated;

-- an add-on's recipe and its figures, shaped like a dish's (mb_recipe_json): "kind" 'addon', its id also as menu_item_id for the screens
create or replace function public.mb_addon_recipe_json(p_org uuid, p_addon uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.menu_addons%rowtype; v_lines jsonb := '[]'; v_cost bigint := 0; v_missing int := 0; r record; c record; v_line bigint;
begin
  select * into a from public.menu_addons where id = p_addon and organization_id = p_org;
  if not found then raise exception 'POS_NOT_FOUND: add-on not found'; end if;
  for r in select ar.*, i.name, i.unit, i.category from public.menu_addon_recipes ar join public.inventory_items i on i.id = ar.inventory_item_id
            where ar.addon_id = p_addon and ar.organization_id = p_org order by ar.is_key desc, i.name loop
    select * into c from public.mb_ing_cost(p_org, r.inventory_item_id);
    v_line := case when c.cost_minor is null then null else round(c.cost_minor * r.qty_per_unit * (1 + r.wastage_pct / 100))::bigint end;
    if v_line is null then v_missing := v_missing + 1; else v_cost := v_cost + v_line; end if;
    v_lines := v_lines || jsonb_build_object('inventory_item_id', r.inventory_item_id, 'name', r.name, 'unit', r.unit, 'category', r.category,
      'qty', r.qty_per_unit, 'wastage_pct', r.wastage_pct, 'is_key', r.is_key, 'note', r.note,
      'unit_cost_minor', c.cost_minor, 'cost_source', c.source, 'line_cost_minor', v_line);
  end loop;
  return jsonb_build_object(
    'kind', 'addon', 'addon_id', a.id, 'menu_item_id', a.id, 'name', a.name, 'food_type', a.food_type, 'image_url', null,
    'category', (select g.name from public.menu_addon_groups g where g.id = a.group_id),
    -- an add-on without a recipe yet that has its one ingredient (0624): billed, it uses that
    'single', case when jsonb_array_length(v_lines) = 0 and a.inventory_item_id is not null then
                     jsonb_build_object('name', (select name from public.inventory_items where id = a.inventory_item_id),
                                        'unit', (select unit from public.inventory_items where id = a.inventory_item_id), 'qty', a.consume_qty) end,
    'price_minor', round(a.price * 100)::bigint, 'lines', v_lines, 'line_count', jsonb_array_length(v_lines),
    'key_count', (select count(*) from jsonb_array_elements(v_lines) x where (x->>'is_key')::boolean),
    'missing_cost', v_missing, 'cost_minor', v_cost,
    'food_cost_pct', case when a.price > 0 and jsonb_array_length(v_lines) > 0 then round(v_cost / (a.price * 100) * 100, 1) end,
    'margin_minor', case when jsonb_array_length(v_lines) > 0 then round(a.price * 100)::bigint - v_cost end,
    'margin_pct', case when a.price > 0 and jsonb_array_length(v_lines) > 0 then round((a.price * 100 - v_cost) / (a.price * 100) * 100, 1) end);
end $$;
revoke all on function public.mb_addon_recipe_json(uuid, uuid) from public, anon, authenticated;

-- ---- existing functions, patched (live definitions + the 0626 changes) ----

CREATE OR REPLACE FUNCTION public.rcp_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), ''));
  v_items jsonb := '[]'; r record; j jsonb; v_with int := 0; v_sum numeric := 0; v_n int := 0;
begin
  for r in select m.id from public.menu_items m left join public.menu_categories c on c.id = m.category_id
            where m.organization_id = v_org and (v_q = '' or lower(m.name) like '%' || v_q || '%')
            order by c.sort_order nulls last, c.name, m.sort_order, m.name loop
    j := public.mb_recipe_json(v_org, r.id) - 'lines';
    if (j->>'line_count')::int > 0 then
      v_with := v_with + 1;
      if j->>'food_cost_pct' is not null then v_sum := v_sum + (j->>'food_cost_pct')::numeric; v_n := v_n + 1; end if;
    end if;
    v_items := v_items || j;
  end loop;
  return jsonb_build_object('items', v_items,
    'summary', jsonb_build_object('dishes', jsonb_array_length(v_items), 'with_recipe', v_with, 'without_recipe', jsonb_array_length(v_items) - v_with,
                                  'avg_food_cost_pct', case when v_n > 0 then round(v_sum / v_n, 1) end),
    -- 0626: every add-on with its recipe figures (the recipe master's Add-ons)
    'addons', coalesce((select jsonb_agg(public.mb_addon_recipe_json(v_org, ad.id) - 'lines' order by g.sort_order, g.name, ad.sort_order, ad.name)
                          from public.menu_addons ad join public.menu_addon_groups g on g.id = ad.group_id
                         where ad.organization_id = v_org and ad.active and (v_q = '' or lower(ad.name) like '%' || v_q || '%')), '[]'::jsonb));
end $$;

CREATE OR REPLACE FUNCTION public.rcp_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  -- 0626: an add-on's recipe
  if nullif(p->>'addon_id', '') is not null then return public.mb_addon_recipe_json(v_org, (p->>'addon_id')::uuid); end if;
  return public.mb_recipe_json(v_org, nullif(p->>'menu_item_id', '')::uuid);
end $$;

CREATE OR REPLACE FUNCTION public.rcp_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_item uuid := nullif(p->>'menu_item_id', '')::uuid; l jsonb; v_ing uuid; v_qty numeric; v_w numeric;
begin
  -- 0626: an add-on's recipe, the same rules as a dish's
  if nullif(p->>'addon_id', '') is not null then
    if not exists (select 1 from public.menu_addons where id = (p->>'addon_id')::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: add-on not found'; end if;
    if jsonb_typeof(p->'lines') <> 'array' then raise exception 'POS_BAD_REQUEST: lines is a list'; end if;
    if jsonb_array_length(p->'lines') > 60 then raise exception 'POS_BAD_REQUEST: up to 60 ingredients in one recipe'; end if;
    delete from public.menu_addon_recipes where addon_id = (p->>'addon_id')::uuid and organization_id = v_org;
    for l in select * from jsonb_array_elements(p->'lines') loop
      v_ing := nullif(l->>'inventory_item_id', '')::uuid;
      if not exists (select 1 from public.inventory_items where id = v_ing and organization_id = v_org) then raise exception 'POS_NOT_FOUND: an ingredient in this recipe was not found'; end if;
      v_qty := nullif(l->>'qty', '')::numeric;
      if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'POS_BAD_REQUEST: every ingredient needs a quantity above zero'; end if;
      v_w := coalesce(nullif(l->>'wastage_pct', '')::numeric, 0);
      if v_w < 0 or v_w > 90 then raise exception 'POS_BAD_REQUEST: wastage is 0 to 90 percent'; end if;
      insert into public.menu_addon_recipes (organization_id, addon_id, inventory_item_id, qty_per_unit, wastage_pct, is_key, note)
      values (v_org, (p->>'addon_id')::uuid, v_ing, v_qty, v_w, coalesce((l->>'is_key')::boolean, false), left(public.mb_clean(l->>'note'), 200))
      on conflict (addon_id, inventory_item_id) do update set qty_per_unit = excluded.qty_per_unit + menu_addon_recipes.qty_per_unit,
        wastage_pct = excluded.wastage_pct, is_key = excluded.is_key or menu_addon_recipes.is_key;
    end loop;
    -- the add-on master shows the recipe's key (or first) ingredient as the add-on's ingredient
    update public.menu_addons ad set inventory_item_id = k.inventory_item_id, consume_qty = k.qty_per_unit
      from (select ar.inventory_item_id, ar.qty_per_unit from public.menu_addon_recipes ar where ar.addon_id = (p->>'addon_id')::uuid
             order by ar.is_key desc, ar.qty_per_unit desc limit 1) k
     where ad.id = (p->>'addon_id')::uuid;
    return public.mb_addon_recipe_json(v_org, (p->>'addon_id')::uuid);
  end if;
  if not exists (select 1 from public.menu_items where id = v_item and organization_id = v_org) then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if jsonb_typeof(p->'lines') <> 'array' then raise exception 'POS_BAD_REQUEST: lines is a list'; end if;
  if jsonb_array_length(p->'lines') > 60 then raise exception 'POS_BAD_REQUEST: up to 60 ingredients in one recipe'; end if;
  delete from public.menu_item_recipes where menu_item_id = v_item and organization_id = v_org;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_ing := nullif(l->>'inventory_item_id', '')::uuid;
    if not exists (select 1 from public.inventory_items where id = v_ing and organization_id = v_org) then raise exception 'POS_NOT_FOUND: an ingredient in this recipe was not found'; end if;
    v_qty := nullif(l->>'qty', '')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'POS_BAD_REQUEST: every ingredient needs a quantity above zero'; end if;
    v_w := coalesce(nullif(l->>'wastage_pct', '')::numeric, 0);
    if v_w < 0 or v_w > 90 then raise exception 'POS_BAD_REQUEST: wastage is 0 to 90 percent'; end if;
    insert into public.menu_item_recipes (organization_id, menu_item_id, inventory_item_id, qty_per_unit, wastage_pct, is_key, note)
    values (v_org, v_item, v_ing, v_qty, v_w, coalesce((l->>'is_key')::boolean, false), left(public.mb_clean(l->>'note'), 200))
    on conflict (menu_item_id, inventory_item_id) do update set qty_per_unit = excluded.qty_per_unit + menu_item_recipes.qty_per_unit,
      wastage_pct = excluded.wastage_pct, is_key = excluded.is_key or menu_item_recipes.is_key;
  end loop;
  return public.mb_recipe_json(v_org, v_item);
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare o public.orders%rowtype; r record; v_done numeric; v_seq integer; v_n integer := 0; v_k integer;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.status not in ('sent_to_kitchen', 'ready', 'paid', 'delivered') then return 0; end if;
  -- an order already reversed (cancelled earlier in this transaction) never consumes again
  if exists (select 1 from public.stock_movements where ref_type = 'orders' and (ref_id = p_order::text or ref_id like p_order::text || '#%') and kind = 'sale_reversal') then return 0; end if;
  -- one consumer per order at a time
  perform pg_advisory_xact_lock(hashtextextended('order_stock:' || p_order::text, 400));
  -- What the order needs per stock item, against what the ledger already took for it. The first consumption writes one row per item
  -- (ref_id = the order id); a line added or increased later is consumed as a further row for just the difference (ref_id = order id#n), so
  -- it is consumed once and a repeat run adds nothing (H-06). Cancel puts back every row, whichever consumption wrote it.
  for r in
    select u.inventory_item_id, round(sum(u.need), 3) as need from (
      select rc.inventory_item_id, oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100) as need
        from public.order_items oi
        join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
       where oi.order_id = o.id and oi.status <> 'cancelled'
      union all
      -- 0624 / 0626: a billed add-on uses its recipe (each ingredient, with wastage); one without a recipe uses its single ingredient;
      -- times how many of the add-on, times the dishes
      select coalesce(ar.inventory_item_id, ad.inventory_item_id),
             oi.qty * coalesce((a->>'qty')::numeric, 1) * coalesce(ar.qty_per_unit * (1 + ar.wastage_pct / 100), ad.consume_qty)
        from public.order_items oi
        cross join lateral jsonb_array_elements(case when jsonb_typeof(oi.add_ons) = 'array' then oi.add_ons else '[]'::jsonb end) a
        join public.menu_addons ad on ad.id::text = a->>'id' and ad.organization_id = o.organization_id
        left join public.menu_addon_recipes ar on ar.addon_id = ad.id
       where oi.order_id = o.id and oi.status <> 'cancelled' and a->>'kind' = 'addon'
         and (ar.addon_id is not null or (ad.inventory_item_id is not null and ad.consume_qty is not null))) u
     group by u.inventory_item_id
  loop
    select coalesce(-sum(quantity), 0), count(*) into v_done, v_seq from public.stock_movements
     where ref_type = 'orders' and kind = 'sale' and inventory_item_id = r.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
    continue when r.need - v_done <= 0;
    insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
    values (o.organization_id, o.location_id, r.inventory_item_id, 'sale', -(r.need - v_done), 'orders',
            case when v_seq = 0 then o.id::text else o.id::text || '#' || v_seq end, o.display_no, o.created_by)
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  return v_n;
end $$;

