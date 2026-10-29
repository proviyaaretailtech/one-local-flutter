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
