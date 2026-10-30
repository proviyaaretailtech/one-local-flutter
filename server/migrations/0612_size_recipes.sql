-- 0612: a size uses its recipe that many times (founder, 28 Oct 2026). The recipe on a dish is its Small; a size carries recipe_factor,
-- e.g. Small 1, Medium 2 (two Smalls), Large 3 (three Smalls). Safe to run again.
--   * menu_item_variants.recipe_factor (default 1, 0 to 20).
--   * order_stock_consume: a line of a size takes recipe x factor from stock when it goes to the kitchen (the line keeps its size's name).
--   * sell_return_restock: a returned line of a size puts recipe x factor back.
--   * pos_sell_catalog: each size answers its factor and how many of it can be made (the dish's count / factor, rounded down).
--   * rst_menu: each size answers its factor.
-- The functions below are the live definitions with only those changes.

begin;

alter table public.menu_item_variants add column if not exists recipe_factor numeric(6,2) not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'menu_item_variants_recipe_factor_check') then
    alter table public.menu_item_variants add constraint menu_item_variants_recipe_factor_check check (recipe_factor > 0 and recipe_factor <= 20);
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    select rc.inventory_item_id, round(sum(oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100)), 3) as need
      from public.order_items oi
      join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
     where oi.order_id = o.id and oi.status <> 'cancelled'
     group by rc.inventory_item_id
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
end $function$

;

CREATE OR REPLACE FUNCTION public.sell_return_restock(p_return uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.sell_returns%rowtype; o public.orders%rowtype; l record; rc record; v_sold numeric; v_back numeric; v_qty numeric; v_left numeric; v_take numeric;
  v_mid bigint; a record; v_bin uuid; v_n int := 0; v_expired boolean;
begin
  select * into r from public.sell_returns where id = p_return;
  select * into o from public.orders where id = r.order_id;
  if not found or o.location_id is null then return 0; end if;
  for l in select sl.id, sl.qty, i.menu_item_id, coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = i.menu_item_id and mv.name = i.variant_name limit 1), 1) as factor from public.sell_return_lines sl join public.order_items i on i.id = sl.order_item_id where sl.return_id = r.id and sl.restock loop
    for rc in select inventory_item_id, qty_per_unit from public.menu_item_recipes where menu_item_id = l.menu_item_id and organization_id = r.organization_id loop
      select coalesce(-sum(quantity), 0) into v_sold from public.stock_movements
       where ref_type = 'orders' and kind = 'sale' and inventory_item_id = rc.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
      continue when v_sold <= 0;
      select coalesce(sum(m.quantity), 0) into v_back from public.stock_movements m
       where m.ref_type = 'sell_returns' and m.kind = 'sale_reversal' and m.inventory_item_id = rc.inventory_item_id
         and m.ref_id in (select x.id::text from public.sell_return_lines x join public.sell_returns y on y.id = x.return_id where y.order_id = o.id);
      v_qty := least(round(l.qty * l.factor * rc.qty_per_unit, 3), v_sold - v_back);
      continue when v_qty <= 0;
      insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
      values (r.organization_id, o.location_id, rc.inventory_item_id, 'sale_reversal', v_qty, 'sell_returns', l.id::text, 'return ' || r.return_no, auth.uid())
      on conflict do nothing returning id into v_mid;
      continue when v_mid is null;
      v_left := v_qty;
      for a in select al.bin_id, al.lot_id, -sum(al.quantity) as taken from public.stock_allocations al join public.stock_movements s on s.id = al.movement_id
                where s.ref_type = 'orders' and s.kind = 'sale' and s.inventory_item_id = rc.inventory_item_id and (s.ref_id = o.id::text or s.ref_id like o.id::text || '#%')
                group by al.bin_id, al.lot_id having -sum(al.quantity) > 0 order by -sum(al.quantity) desc loop
        exit when v_left <= 0;
        v_take := least(v_left, a.taken);
        v_expired := a.lot_id is not null and exists (select 1 from public.inventory_lots lt where lt.id = a.lot_id and lt.expiry_date < current_date);
        v_bin := case when v_expired then public.inv_default_bin(r.organization_id, o.location_id, 'quarantine') else a.bin_id end;
        insert into public.stock_allocations (organization_id, movement_id, bin_id, lot_id, quantity) values (r.organization_id, v_mid, v_bin, a.lot_id, v_take);
        v_left := v_left - v_take;
      end loop;
      if v_left > 0 then
        insert into public.stock_allocations (organization_id, movement_id, bin_id, quantity) values (r.organization_id, v_mid, public.inv_default_bin(r.organization_id, o.location_id), v_left);
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
                 'can_make', public.menu_can_make(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default, 'recipe_factor', mv.recipe_factor,
                                  'can_make', floor(public.menu_can_make(v_org, i.id) / mv.recipe_factor)::int) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price, 'recipe_factor', mv.recipe_factor) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $function$

;

commit;
