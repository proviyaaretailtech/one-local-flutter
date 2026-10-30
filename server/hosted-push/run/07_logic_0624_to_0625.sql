-- ==========================================================================================================================
-- HOSTED PUSH piece 07 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0624_addons_combos_billing.sql
-- 0624: add-ons from the ingredient master, combo groups on a dish, and one pop-up when billing (founder, 29 Oct 2026).
--   * menu_addons: + inventory_item_id, consume_qty. An add-on is an ingredient (from the ingredient master) with the quantity one add-on uses
--     and its selling price; billing it consumes that ingredient (order_stock_consume).
--   * combo groups: menu_combo_groups / menu_combo_group_combos / menu_item_combo_groups; menu_combo_group_list / _save / _delete; a dish's
--     settings tick its combo groups. Choosing a combo on a dish adds the combo's price to the dish and its dishes to the KOT at ₹0.
--   * menu_line_extras(org, dish, line): the add-ons and combos chosen on one bill line, checked against the dish's groups and their
--     min / max, with what they add to the price. tbl_order_add and pos_place_order use it; pos_sell_catalog lists each dish's groups;
--     the KDS shows the add-ons under the dish.
-- Safe to run again.

alter table public.menu_addons add column if not exists inventory_item_id uuid references public.inventory_items(id) on delete set null;
alter table public.menu_addons add column if not exists consume_qty numeric(12,3);
do $$ begin
  alter table public.menu_addons add constraint menu_addons_consume_qty_check check (consume_qty is null or (consume_qty > 0 and consume_qty <= 100000));
exception when duplicate_object then null; end $$;

create table if not exists public.menu_combo_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  min_select int not null default 0 check (min_select between 0 and 10),
  max_select int not null default 1 check (max_select between 1 and 10),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (min_select <= max_select)
);
create unique index if not exists menu_combo_groups_name on public.menu_combo_groups (organization_id, lower(btrim(name)));
create table if not exists public.menu_combo_group_combos (
  group_id uuid not null references public.menu_combo_groups(id) on delete cascade,
  combo_id uuid not null references public.menu_combos(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sort_order int not null default 0,
  primary key (group_id, combo_id)
);
create table if not exists public.menu_item_combo_groups (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  group_id uuid not null references public.menu_combo_groups(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  primary key (menu_item_id, group_id)
);
alter table public.menu_combo_groups enable row level security;
alter table public.menu_combo_group_combos enable row level security;
alter table public.menu_item_combo_groups enable row level security;
revoke all on public.menu_combo_groups, public.menu_combo_group_combos, public.menu_item_combo_groups from anon, authenticated;

-- a combo's dishes in a few words: "Peri Peri Fries, Ice Blue"
create or replace function public.menu_combo_items_text(p_combo uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select string_agg(case when ci.qty > 1 then ci.qty || ' × ' else '' end || m.name, ', ' order by m.name)
    from public.menu_combo_items ci join public.menu_items m on m.id = ci.menu_item_id where ci.combo_id = p_combo
$$;
revoke all on function public.menu_combo_items_text(uuid) from public, anon;

-- the add-on and combo groups of a dish, as billing shows them (null when it has none)
create or replace function public.menu_item_options(p_org uuid, p_item uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'addon_groups', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
                       'addons', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price', a.price, 'food_type', a.food_type) order by a.sort_order, a.name), '[]'::jsonb)
                                    from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                       from public.menu_item_addon_groups x join public.menu_addon_groups g on g.id = x.group_id
                      where x.menu_item_id = p_item and g.organization_id = p_org and g.active
                        and exists (select 1 from public.menu_addons a where a.group_id = g.id and a.active)),
    'combo_groups', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
                       'combos', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price', c.price, 'items', public.menu_combo_items_text(c.id)) order by gc.sort_order, c.name), '[]'::jsonb)
                                    from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active)) order by g.sort_order, g.name)
                       from public.menu_item_combo_groups x join public.menu_combo_groups g on g.id = x.group_id
                      where x.menu_item_id = p_item and g.organization_id = p_org and g.active
                        and exists (select 1 from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active))))
$$;
revoke all on function public.menu_item_options(uuid, uuid) from public, anon;

-- One bill line's add-ons ("addons": [id, …], an id twice = two of it) and combos ("combos": [id, …]): each must belong to a group of the dish,
-- each group within its min / max. Returns {"add_ons": [{kind, id, name, price, qty}, …], "extra": the price they add to one dish}.
create or replace function public.menu_line_extras(p_org uuid, p_item uuid, p_line jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_dish text := (select name from public.menu_items where id = p_item); v_out jsonb := '[]'::jsonb; v_extra numeric := 0; g record; r record; v_n int;
begin
  if p_line ? 'addons' and jsonb_typeof(p_line->'addons') <> 'array' then raise exception 'POS_BAD_REQUEST: add-ons are a list'; end if;
  if p_line ? 'combos' and jsonb_typeof(p_line->'combos') <> 'array' then raise exception 'POS_BAD_REQUEST: combos are a list'; end if;
  if jsonb_array_length(coalesce(p_line->'addons', '[]')) > 40 or jsonb_array_length(coalesce(p_line->'combos', '[]')) > 10 then
    raise exception 'POS_BAD_REQUEST: too many add-ons on one dish'; end if;
  -- every chosen add-on is an active add-on of a group this dish has
  for r in select a.value as aid, count(*) as n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a group by a.value loop
    if not exists (select 1 from public.menu_addons ad join public.menu_item_addon_groups x on x.group_id = ad.group_id
                    where ad.id::text = r.aid and x.menu_item_id = p_item and ad.organization_id = p_org and ad.active) then
      raise exception 'POS_BAD_REQUEST: that add-on is not offered with %', v_dish; end if;
  end loop;
  for r in select c.value as cid from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c loop
    if not exists (select 1 from public.menu_combo_group_combos gc join public.menu_item_combo_groups x on x.group_id = gc.group_id
                     join public.menu_combos cb on cb.id = gc.combo_id
                    where gc.combo_id::text = r.cid and x.menu_item_id = p_item and gc.organization_id = p_org and cb.active) then
      raise exception 'POS_BAD_REQUEST: that combo is not offered with %', v_dish; end if;
  end loop;
  -- each group within its min / max
  for g in select ag.* from public.menu_item_addon_groups x join public.menu_addon_groups ag on ag.id = x.group_id where x.menu_item_id = p_item and ag.active loop
    select count(*) into v_n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a join public.menu_addons ad on ad.id::text = a.value where ad.group_id = g.id;
    if v_n < g.min_select then raise exception 'POS_BAD_REQUEST: choose at least % from % for %', g.min_select, g.name, v_dish; end if;
    if v_n > g.max_select then raise exception 'POS_BAD_REQUEST: choose at most % from % for %', g.max_select, g.name, v_dish; end if;
  end loop;
  for g in select cg.* from public.menu_item_combo_groups x join public.menu_combo_groups cg on cg.id = x.group_id where x.menu_item_id = p_item and cg.active loop
    select count(*) into v_n from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c join public.menu_combo_group_combos gc on gc.combo_id::text = c.value and gc.group_id = g.id;
    if v_n < g.min_select then raise exception 'POS_BAD_REQUEST: choose at least % from % for %', g.min_select, g.name, v_dish; end if;
    if v_n > g.max_select then raise exception 'POS_BAD_REQUEST: choose at most % from % for %', g.max_select, g.name, v_dish; end if;
  end loop;
  for r in select ad.id, ad.name, ad.price, count(*) as n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a join public.menu_addons ad on ad.id::text = a.value
            group by ad.id, ad.name, ad.price, ad.sort_order order by ad.sort_order, ad.name loop
    v_out := v_out || jsonb_build_object('kind', 'addon', 'id', r.id, 'name', r.name, 'price', r.price, 'qty', r.n);
    v_extra := v_extra + r.price * r.n;
  end loop;
  for r in select distinct cb.id, cb.name, cb.price from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c join public.menu_combos cb on cb.id::text = c.value loop
    v_out := v_out || jsonb_build_object('kind', 'combo', 'id', r.id, 'name', r.name, 'price', r.price, 'qty', 1, 'items', public.menu_combo_items_text(r.id));
    v_extra := v_extra + r.price;
  end loop;
  return jsonb_build_object('add_ons', v_out, 'extra', v_extra);
end $$;
revoke all on function public.menu_line_extras(uuid, uuid, jsonb) from public, anon;

-- the combo dishes of the lines just added, at ₹0 ("Combo: fries & Cole with Veg Grilled Subway"), so the kitchen makes them and their recipes are used
create or replace function public.order_combo_lines(p_order uuid, p_org uuid, p_lines jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course)
  select p_order, m2.id, m2.name, (l->>'qty')::int * ci.qty, 0, left('Combo: ' || cb.name || ' with ' || mi.name, 200), coalesce(m2.station, 'main'), coalesce(m2.course, 'eat')
    from jsonb_array_elements(p_lines) l
    join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = p_org
    cross join lateral jsonb_array_elements_text(coalesce(l->'combos', '[]')) c(cid)
    join public.menu_combos cb on cb.id::text = c.cid and cb.organization_id = p_org
    join public.menu_combo_items ci on ci.combo_id = cb.id
    join public.menu_items m2 on m2.id = ci.menu_item_id
$$;
revoke all on function public.order_combo_lines(uuid, uuid, jsonb) from public, anon, authenticated;

create or replace function public.menu_combo_group_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select, 'active', g.active,
                 'combo_ids', (select coalesce(jsonb_agg(gc.combo_id order by gc.sort_order), '[]'::jsonb) from public.menu_combo_group_combos gc where gc.group_id = g.id),
                 'combos', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price_minor', round(c.price * 100)::bigint) order by gc.sort_order), '[]'::jsonb)
                              from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id),
                 'dish_count', (select count(*) from public.menu_item_combo_groups x where x.group_id = g.id)) order by g.sort_order, g.name)
               from public.menu_combo_groups g where g.organization_id = v_org), '[]'::jsonb),
    'combos', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price_minor', round(c.price * 100)::bigint, 'items', public.menu_combo_items_text(c.id), 'active', c.active) order by c.name)
               from public.menu_combos c where c.organization_id = v_org), '[]'::jsonb));
end $$;

create or replace function public.menu_combo_group_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_min int := coalesce(nullif(p->>'min_select', '')::int, 0); v_max int := coalesce(nullif(p->>'max_select', '')::int, 1); c text; v_n int := 0;
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter the group name (up to 60 characters)'; end if;
  if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 10 then raise exception 'POS_BAD_REQUEST: choose between 0 and 10, the minimum not above the maximum'; end if;
  if jsonb_typeof(p->'combo_ids') is distinct from 'array' or jsonb_array_length(p->'combo_ids') = 0 then raise exception 'POS_BAD_REQUEST: choose at least one combo'; end if;
  if exists (select 1 from public.menu_combo_groups where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already a combo group called %', v_name; end if;
  if v_id is null then
    insert into public.menu_combo_groups (organization_id, name, min_select, max_select, sort_order)
    values (v_org, v_name, v_min, v_max, coalesce((select max(sort_order) + 1 from public.menu_combo_groups where organization_id = v_org), 0)) returning id into v_id;
  else
    update public.menu_combo_groups set name = v_name, min_select = v_min, max_select = v_max, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
  end if;
  delete from public.menu_combo_group_combos where group_id = v_id;
  for c in select jsonb_array_elements_text(p->'combo_ids') loop
    if not exists (select 1 from public.menu_combos where id::text = c and organization_id = v_org) then raise exception 'POS_NOT_FOUND: combo not found'; end if;
    v_n := v_n + 1;
    insert into public.menu_combo_group_combos (group_id, combo_id, organization_id, sort_order) values (v_id, c::uuid, v_org, v_n) on conflict do nothing;
  end loop;
  return jsonb_build_object('id', v_id) || public.menu_combo_group_list('{}');
end $$;

create or replace function public.menu_combo_group_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  delete from public.menu_combo_groups where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
  return public.menu_combo_group_list('{}');
end $$;

revoke all on function public.menu_combo_group_list(jsonb), public.menu_combo_group_save(jsonb), public.menu_combo_group_delete(jsonb) from public, anon;
grant execute on function public.menu_combo_group_list(jsonb), public.menu_combo_group_save(jsonb), public.menu_combo_group_delete(jsonb) to authenticated;

-- ---- existing functions, patched (live definitions + the 0624 changes) ----
CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'TBL_BAD_REQUEST: choose a size of %', v_item.name; end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    -- 0624: the add-ons and combos chosen on each line add to its price and are kept on it; the combo dishes follow at ₹0
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name, add_ons)
    select o.id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price) + (e.x->>'extra')::numeric, nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat'), mv.name,
           nullif(e.x->'add_ons', '[]'::jsonb)
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org
      left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id
      cross join lateral (select public.menu_line_extras(v_org, mi.id, l) as x) e;
    perform public.order_combo_lines(o.id, v_org, p->'lines');
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $$;

CREATE OR REPLACE FUNCTION public.pos_place_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare
  v_org uuid := (p->>'organization_id')::uuid; v_key text := nullif(p->>'idempotency_key','');
  v_channel text := p->>'service_type'; v_placed_by text := coalesce(nullif(p->>'placed_by',''),'pos');
  v_qty int; v_line jsonb; v_item public.menu_items%rowtype; v_sub numeric(10,2) := 0; v_n int := 0;
  v_cfg public.org_bill_settings%rowtype; v_gst_pct numeric; v_gst numeric(10,2); v_sc numeric(10,2) := 0; v_waived numeric(10,2) := 0;
  v_raw numeric(10,2); v_total numeric(10,2); v_round numeric(10,2) := 0; v_disc numeric(10,2) := 0;
  v_table public.dining_tables%rowtype; v_loc uuid; v_no bigint; v_display text; v_id uuid; v_status text; v_kot uuid; v_ex uuid;
  v_waive boolean := coalesce((p->>'waive_service_charge')::boolean, false);
  v_code text; v_cp public.sell_coupons%rowtype; v_ckey text;
begin
  if auth.uid() is null or v_org is null or v_org is distinct from public.current_org_id() then raise exception 'POS_FORBIDDEN: not your organization'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','biller','captain','business_manager','location_manager','operations_manager']) then
    raise exception 'POS_FORBIDDEN: your role cannot place orders'; end if;
  if v_channel not in ('dine_in','pickup','delivery') then raise exception 'POS_BAD_REQUEST: unknown service type'; end if;
  if v_placed_by not in ('pos','captain','guest','integration') then raise exception 'POS_BAD_REQUEST: unknown placed_by'; end if;
  if v_key is not null then
    select id into v_ex from public.orders where organization_id = v_org and idempotency_key = v_key;
    if found then return public.pos_order_json(v_ex) || jsonb_build_object('replayed', true); end if;
  end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'POS_EMPTY: add between 1 and 50 lines'; end if;
  v_code := upper(nullif(btrim(coalesce(p->>'coupon_code', '')), ''));

  if nullif(p->>'table_id','') is not null then
    select * into v_table from public.dining_tables where id = (p->>'table_id')::uuid and organization_id = v_org and is_active;
    if not found then raise exception 'POS_BAD_TABLE: table not found'; end if;
    v_loc := v_table.location_id;
  elsif v_channel = 'dine_in' then raise exception 'POS_BAD_TABLE: choose a table for a dine-in order'; end if;
  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;

  select * into v_cfg from public.org_bill_settings where organization_id = v_org;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    v_qty := (v_line->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'POS_BAD_QTY: quantities must be 1 to 99'; end if;
    select * into v_item from public.menu_items where id = (v_line->>'menu_item_id')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'POS_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name,'an item'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'POS_BAD_VARIANT: choose a size of %', v_item.name; end if;
    v_sub := v_sub + (coalesce((select mv.price from public.menu_item_variants mv where mv.id = nullif(v_line->>'variant_id', '')::uuid and mv.menu_item_id = v_item.id), v_item.price)
                      + (public.menu_line_extras(v_org, v_item.id, v_line)->>'extra')::numeric) * v_qty; v_n := v_n + v_qty;
  end loop;

  -- 0380: a coupon code takes money off the bill. The rules live in sell_coupons; the discount is worked out here, never by the app.
  if v_code is not null then
    select * into v_cp from public.sell_coupons where organization_id = v_org and upper(code) = v_code and active
      and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
    if not found then raise exception 'POS_COUPON_UNKNOWN: this coupon code is not valid'; end if;
    if v_sub < v_cp.min_order then raise exception 'POS_COUPON_MIN: this coupon needs a bill of at least %', v_cp.min_order; end if;
    v_disc := case v_cp.kind when 'percent' then round(v_sub * v_cp.value / 100, 2) else v_cp.value end;
    if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if;
    v_disc := least(v_disc, v_sub);
    -- use limits, counted under the coupon row's lock (the select above), so two tills cannot both take the last use
    v_ckey := nullif(right(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), 10), '');   -- the last 10 digits, so +91 and 0 prefixes do not make a second customer
    if v_cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and released_at is null) >= v_cp.max_uses then
      raise exception 'POS_COUPON_LIMIT: this coupon has been used up'; end if;
    if v_cp.max_uses_per_customer is not null then
      if v_ckey is null then raise exception 'POS_COUPON_CUSTOMER: this coupon is limited per customer; enter the customer''s mobile number'; end if;
      if (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and customer_key = v_ckey and released_at is null) >= v_cp.max_uses_per_customer then
        raise exception 'POS_COUPON_LIMIT: this customer has already used this coupon'; end if;
    end if;
    update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = v_cp.id;
  end if;

  -- 0371: a shop that is not GST-registered charges no GST; when menu prices already include GST, the tax is taken out of them, not added on top
  v_gst_pct := case when v_cfg.gst_registered is false then 0 else v_cfg.sgst_pct + v_cfg.cgst_pct end;
  if coalesce(v_cfg.prices_include_tax, false) and v_gst_pct > 0 then
    v_gst := round((v_sub - v_disc) * v_gst_pct / (100 + v_gst_pct), 2);
    v_sub := v_sub - v_gst;   -- subtotal is stored before tax, so subtotal + GST still equals what the menu showed
  else
    v_gst := round((v_sub - v_disc) * v_gst_pct / 100, 2);
  end if;
  v_sc := round((v_sub - v_disc) * v_cfg.service_charge_pct / 100, 2);
  if v_waive then
    if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can remove the service charge'; end if;
    if coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
    v_waived := v_sc; v_sc := 0;
  end if;
  v_raw := v_sub - v_disc + v_gst + v_sc;
  v_total := case when v_cfg.round_off_enabled then round(v_raw) else v_raw end; v_round := v_total - v_raw;

  -- a coupon that makes the bill free is refused: a bill with nothing to pay cannot be completed at the counter
  if v_code is not null and v_total <= 0 then raise exception 'POS_COUPON_ZERO: this coupon would make the bill free; use a smaller discount'; end if;

  v_no := public.next_org_seq(v_org, 'order'); v_display := 'P-' || lpad(v_no::text, 5, '0');
  v_status := case when coalesce((p->>'fire_kot')::boolean, true) then 'sent_to_kitchen' else 'in_billing' end;
  insert into public.orders (organization_id, location_id, order_no, display_no, channel, status, table_id, customer_name, customer_phone, captain_name,
      subtotal, discount, gst_pct, gst_amount, service_charge, round_off, total, placed_by, guest_count, notes, idempotency_key,
      service_charge_waived, service_charge_waived_amount, waive_reason, created_by, coupon_code)
  values (v_org, v_loc, v_no, v_display, v_channel, v_status, v_table.id, nullif(p->>'customer_name',''), nullif(p->>'customer_phone',''), null,
      v_sub, v_disc, v_gst_pct, v_gst, v_sc, v_round, v_total, v_placed_by, coalesce(nullif(p->>'guest_count','')::int, 1), nullif(p->>'notes',''), v_key,
      v_waive, v_waived, case when v_waive then p->>'waive_reason' end, auth.uid(), case when v_disc > 0 then v_cp.code end)
  returning id into v_id;
  if v_code is not null and v_disc > 0 then
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, v_cp.id, v_id, v_ckey);
  end if;
  -- 0624: add-ons and combos on each line; the combo dishes follow at ₹0
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name, add_ons)
  select v_id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price) + (e.x->>'extra')::numeric, nullif(l->>'notes',''), coalesce(mi.station,'main'), coalesce(mi.course,'eat'), mv.name,
         nullif(e.x->'add_ons', '[]'::jsonb)
  from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid
  left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id
  cross join lateral (select public.menu_line_extras(v_org, mi.id, l) as x) e;
  perform public.order_combo_lines(v_id, v_org, p->'lines');
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values
    (v_org, v_id, 'placed', 'Order ' || v_display || ' placed - ' || v_n || ' items', v_placed_by, jsonb_build_object('by', auth.uid()));
  if v_status = 'sent_to_kitchen' then
    insert into public.kot_tickets (organization_id, order_id, kot_no, station, status) values (v_org, v_id, public.next_org_seq(v_org,'kot'), 'main', 'new') returning id into v_kot;
    update public.order_items set kot_ticket_id = v_kot where order_id = v_id;
    insert into public.order_events (organization_id, order_id, kind, message, actor) values (v_org, v_id, 'kot_fired', 'KOT fired for ' || v_display, v_placed_by);
  end if;
  if v_waive then insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, v_id, 'service_charge_waived', 'Service charge removed: ' || (p->>'waive_reason'), v_placed_by, jsonb_build_object('amount', v_waived, 'by', auth.uid())); end if;
  return public.pos_order_json(v_id) || jsonb_build_object('replayed', false);
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
      -- 0624: an add-on made from an ingredient uses that ingredient: its quantity, times how many, times the dishes
      select ad.inventory_item_id, oi.qty * coalesce((a->>'qty')::numeric, 1) * ad.consume_qty
        from public.order_items oi
        cross join lateral jsonb_array_elements(case when jsonb_typeof(oi.add_ons) = 'array' then oi.add_ons else '[]'::jsonb end) a
        join public.menu_addons ad on ad.id::text = a->>'id' and ad.organization_id = o.organization_id
       where oi.order_id = o.id and oi.status <> 'cancelled' and a->>'kind' = 'addon' and ad.inventory_item_id is not null and ad.consume_qty is not null) u
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

CREATE OR REPLACE FUNCTION public.menu_addon_group_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_min int := coalesce(nullif(p->>'min_select', '')::int, 0); v_max int := coalesce(nullif(p->>'max_select', '')::int, 1); a jsonb; v_keep uuid[] := '{}'; v_aid uuid; v_n int := 0;
  v_price numeric;
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter the group name (up to 60 characters)'; end if;
  if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 20 then raise exception 'POS_BAD_REQUEST: choose between 0 and 20, the minimum not above the maximum'; end if;
  if jsonb_typeof(p->'addons') <> 'array' or jsonb_array_length(p->'addons') = 0 then raise exception 'POS_BAD_REQUEST: add at least one add-on'; end if;
  if jsonb_array_length(p->'addons') > 50 then raise exception 'POS_BAD_REQUEST: up to 50 add-ons in a group'; end if;
  if exists (select 1 from public.menu_addon_groups where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already an add-on group called %', v_name; end if;
  if v_id is null then
    insert into public.menu_addon_groups (organization_id, name, min_select, max_select, sort_order)
    values (v_org, v_name, v_min, v_max, coalesce((select max(sort_order) + 1 from public.menu_addon_groups where organization_id = v_org), 0)) returning id into v_id;
  else
    update public.menu_addon_groups set name = v_name, min_select = v_min, max_select = v_max, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
  end if;
  for a in select * from jsonb_array_elements(p->'addons') loop
    v_n := v_n + 1;
    -- 0624: an add-on picked from the ingredient master takes its name unless one is typed, and says how much of it one add-on uses
    if nullif(a->>'inventory_item_id', '') is not null then
      if not exists (select 1 from public.inventory_items ii where ii.id = (a->>'inventory_item_id')::uuid and ii.organization_id = v_org) then
        raise exception 'POS_NOT_FOUND: ingredient not found'; end if;
      if coalesce(nullif(a->>'consume_qty', '')::numeric, 0) <= 0 then raise exception 'POS_BAD_REQUEST: enter how much of the ingredient one add-on uses'; end if;
      a := a || jsonb_build_object('name', coalesce(public.mb_clean(a->>'name'), (select ii.name from public.inventory_items ii where ii.id = (a->>'inventory_item_id')::uuid)));
    end if;
    if public.mb_clean(a->>'name') is null or char_length(public.mb_clean(a->>'name')) > 60 then raise exception 'POS_BAD_REQUEST: every add-on needs a name (up to 60 characters)'; end if;
    v_price := round(coalesce(nullif(a->>'price', '')::numeric, 0), 2);
    if v_price < 0 or v_price > 100000 then raise exception 'POS_BAD_REQUEST: an add-on price is zero or more'; end if;
    if coalesce(a->>'food_type', 'veg') not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
    v_aid := nullif(a->>'id', '')::uuid;
    if v_aid is not null and exists (select 1 from public.menu_addons where id = v_aid and group_id = v_id) then
      update public.menu_addons set name = public.mb_clean(a->>'name'), price = v_price, food_type = coalesce(a->>'food_type', 'veg'),
             active = coalesce((a->>'active')::boolean, true), sort_order = v_n,
             inventory_item_id = nullif(a->>'inventory_item_id', '')::uuid, consume_qty = case when nullif(a->>'inventory_item_id', '') is null then null else nullif(a->>'consume_qty', '')::numeric end
       where id = v_aid;
    else
      insert into public.menu_addons (organization_id, group_id, name, price, food_type, active, sort_order, inventory_item_id, consume_qty)
      values (v_org, v_id, public.mb_clean(a->>'name'), v_price, coalesce(a->>'food_type', 'veg'), coalesce((a->>'active')::boolean, true), v_n,
              nullif(a->>'inventory_item_id', '')::uuid, case when nullif(a->>'inventory_item_id', '') is null then null else nullif(a->>'consume_qty', '')::numeric end) returning id into v_aid;
    end if;
    v_keep := v_keep || v_aid;
  end loop;
  delete from public.menu_addons where group_id = v_id and not (id = any (v_keep));
  if jsonb_typeof(p->'menu_item_ids') = 'array' then
    delete from public.menu_item_addon_groups where group_id = v_id;
    insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id)
    select m.id, v_id, v_org from public.menu_items m where m.organization_id = v_org and m.id::text in (select jsonb_array_elements_text(p->'menu_item_ids'))
    on conflict do nothing;
  end if;
  return jsonb_build_object('id', v_id) || public.menu_addon_list('{}');
end $$;

CREATE OR REPLACE FUNCTION public.menu_addon_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object('groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select,
      'max_select', g.max_select, 'active', g.active,
      'dish_count', (select count(*) from public.menu_item_addon_groups x where x.group_id = g.id),
      'addons', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price_minor', round(a.price * 100)::bigint,
                  'food_type', a.food_type, 'active', a.active, 'inventory_item_id', a.inventory_item_id, 'consume_qty', a.consume_qty,
                  'ingredient', (select ii.name from public.inventory_items ii where ii.id = a.inventory_item_id),
                  'unit', (select ii.unit from public.inventory_items ii where ii.id = a.inventory_item_id)) order by a.sort_order, a.name) from public.menu_addons a where a.group_id = g.id), '[]'))
    order by g.sort_order, g.name) from public.menu_addon_groups g where g.organization_id = v_org), '[]'),
    -- 0624: the ingredient master, to pick an add-on from
    'ingredients', coalesce((select jsonb_agg(jsonb_build_object('id', ii.id, 'name', ii.name, 'unit', ii.unit) order by lower(ii.name))
                              from public.inventory_items ii where ii.organization_id = v_org and ii.active), '[]'));
end $$;

CREATE OR REPLACE FUNCTION public.menu_item_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
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
    'combo_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_combo_groups where menu_item_id = m.id), '[]'),
    'combo_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'combos', (select count(*) from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active)) order by g.sort_order, g.name)
                              from public.menu_combo_groups g where g.organization_id = v_org and g.active), '[]'),
    'stations', '["main","grill","beverage","dessert","tandoor","chinese"]'::jsonb);
end $$;

CREATE OR REPLACE FUNCTION public.menu_item_settings_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype; v_name text; v_price numeric; v_cat uuid; v_sku text; g text;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null or (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;
  v_name := coalesce(public.mb_clean(p->>'name'), m.name);
  if char_length(v_name) not between 2 and 120 then raise exception 'POS_BAD_REQUEST: enter the dish name'; end if;
  v_price := case when p ? 'price' then round((p->>'price')::numeric, 2) else m.price end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  v_cat := case when nullif(p->>'category_id', '') is not null then (select id from public.menu_categories where id = (p->>'category_id')::uuid and organization_id = v_org)
                when public.mb_clean(p->>'category') is not null then public.mb_category(v_org, p->>'category') else m.category_id end;
  if v_cat is null then raise exception 'POS_NOT_FOUND: category not found'; end if;
  v_sku := case when p ? 'sku' then public.mb_clean(p->>'sku') else m.sku end;
  if v_sku is not null and exists (select 1 from public.menu_items where organization_id = v_org and lower(sku) = lower(v_sku) and id <> m.id) then
    raise exception 'POS_CONFLICT: another dish already uses the code %', v_sku; end if;
  if p ? 'food_type' and p->>'food_type' not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
  if p ? 'course' and p->>'course' not in ('eat', 'drink') then raise exception 'POS_BAD_REQUEST: course is eat or drink'; end if;
  if p ? 'prep_minutes' and ((p->>'prep_minutes')::int < 0 or (p->>'prep_minutes')::int > 240) then raise exception 'POS_BAD_REQUEST: preparation time is 0 to 240 minutes'; end if;
  if p ? 'station' and coalesce(public.mb_clean(p->>'station'), '') = '' then raise exception 'POS_BAD_REQUEST: choose a kitchen station'; end if;
  if exists (select 1 from public.menu_items where organization_id = v_org and category_id = v_cat and lower(name) = lower(v_name) and id <> m.id) then
    raise exception 'POS_CONFLICT: % is already in this category', v_name; end if;
  update public.menu_items set name = v_name, price = v_price, category_id = v_cat, sku = v_sku,
    food_type = coalesce(p->>'food_type', food_type), course = coalesce(p->>'course', course),
    station = coalesce(public.mb_clean(p->>'station'), station), prep_minutes = coalesce((p->>'prep_minutes')::int, prep_minutes),
    is_recommended = coalesce((p->>'is_recommended')::boolean, is_recommended), updated_at = now()
   where id = m.id;
  if jsonb_typeof(p->'addon_group_ids') = 'array' then
    delete from public.menu_item_addon_groups where menu_item_id = m.id;
    for g in select jsonb_array_elements_text(p->'addon_group_ids') loop
      if not exists (select 1 from public.menu_addon_groups where id = g::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
      insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id) values (m.id, g::uuid, v_org) on conflict do nothing;
    end loop;
  end if;
  -- 0624: the combo groups ticked on the dish
  if jsonb_typeof(p->'combo_group_ids') = 'array' then
    delete from public.menu_item_combo_groups where menu_item_id = m.id;
    for g in select jsonb_array_elements_text(p->'combo_group_ids') loop
      if not exists (select 1 from public.menu_combo_groups where id = g::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
      insert into public.menu_item_combo_groups (menu_item_id, group_id, organization_id) values (m.id, g::uuid, v_org) on conflict do nothing;
    end loop;
  end if;
  return public.menu_item_settings(jsonb_build_object('id', m.id));
end $$;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
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
                 'options', public.menu_item_options(v_org, i.id),
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
end $$;

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
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name,
                 'add_ons', (select jsonb_agg(case when coalesce((a->>'qty')::int, 1) > 1 then (a->>'qty') || ' × ' else '' end || (a->>'name') || case when a->>'kind' = 'combo' then ' (combo)' else '' end)
                               from jsonb_array_elements(case when jsonb_typeof(i.add_ons) = 'array' then i.add_ons else '[]'::jsonb end) a)) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$$;


-- ---- 0625_bill_lists_addons.sql
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

notify pgrst, 'reload schema';
commit;
