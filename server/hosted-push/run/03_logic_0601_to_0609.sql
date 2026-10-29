-- ==========================================================================================================================
-- HOSTED PUSH piece 03 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0601_menu_stock_signals.sql
-- 0601 Stock tags on the Menu (founder, 27 Oct 2026): beside "Available", a dish shows "Out of stock" (red) or "Low in stock" (orange)
-- worked out from its recipe (0600: menu_item_recipes) and its ingredients' stock. Read only. Safe to run again.
--   * out: an ingredient that has been stocked (it has stock movements) has less on hand than one serving needs (with wastage);
--   * low: an ingredient with a reorder level is at or below it.
-- Ingredients never stocked through receiving are not judged (a new business would otherwise see every dish "out").
-- A dish switched off on the menu is "out of stock" from menu_items.is_available already; this only adds what stock says.


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
  return jsonb_build_object('items', v_items);
end $$;

revoke all on function public.menu_stock_signals(jsonb) from public, anon;
grant execute on function public.menu_stock_signals(jsonb) to authenticated, service_role;


-- ---- 0602_table_manage.sql
-- 0602 Manage tables in the app (founder, 27 Oct 2026): create, rename, change seats, remove. Until now nothing in the app could make a
-- table (dining_tables had no writer). Safe to run again.
--   * who: tbl_guard(p, 'manage') -> tbl_can_manage (dining_tables:manage, or both order place and order update_status) at that outlet;
--   * a name is unique per outlet; making a name that a removed (hidden) table had brings that table back, with its history;
--   * remove: refused while the table is occupied or has an upcoming reservation; a table that has orders or other history is hidden
--     (is_active = false: the floor no longer shows it, past bills keep pointing at it); a table with no history is deleted.


create or replace function public.tbl_table_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id();
begin
  return jsonb_build_object(
    'location_id', v_loc,
    'can_manage', public.tbl_can_manage(v_org, v_loc),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label, 'seats', t.seats, 'sort_order', t.sort_order,
               'status', coalesce(s.status, 'available'),
               'has_history', exists (select 1 from public.orders o where o.table_id = t.id))
             order by t.sort_order, t.label)
        from public.dining_tables t left join public.tbl_states(v_org, v_loc) s on s.table_id = t.id
       where t.organization_id = v_org and t.is_active and coalesce(t.location_id, public.tbl_main(v_org)) = v_loc), '[]'));
end $$;

create or replace function public.tbl_table_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
  v_label text := upper(btrim(regexp_replace(coalesce(p->>'label', ''), '\s+', ' ', 'g'))); v_seats int; t public.dining_tables%rowtype; v_hidden uuid;
begin
  if char_length(v_label) not between 1 and 20 then raise exception 'TBL_BAD_REQUEST: give the table a name of up to 20 characters (for example T6)'; end if;
  begin v_seats := (p->>'seats')::int; exception when others then v_seats := null; end;
  if v_seats is null or v_seats not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: seats are 1 to 50'; end if;
  if exists (select 1 from public.dining_tables x where x.organization_id = v_org and x.is_active and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
               and upper(x.label) = v_label and x.id is distinct from v_id) then
    raise exception 'TBL_CONFLICT: there is already a table called %', v_label; end if;

  if v_id is null then
    -- a removed table with this name comes back (keeps its past bills) instead of clashing with it
    select x.id into v_hidden from public.dining_tables x where x.organization_id = v_org and not x.is_active
       and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc and upper(x.label) = v_label limit 1;
    if v_hidden is not null then
      update public.dining_tables set is_active = true, seats = v_seats, min_capacity = least(min_capacity, v_seats), updated_at = now()
       where id = v_hidden returning * into t;
    else
      insert into public.dining_tables (organization_id, location_id, label, seats, sort_order)
      values (v_org, v_loc, v_label, v_seats,
              coalesce((select max(sort_order) + 1 from public.dining_tables x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc), 1))
      returning * into t;
    end if;
  else
    if exists (select 1 from public.dining_tables x where x.organization_id = v_org and not x.is_active and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
                 and upper(x.label) = v_label and x.id <> v_id) then
      raise exception 'TBL_CONFLICT: a removed table was called %; add it again instead of renaming', v_label; end if;
    update public.dining_tables set label = v_label, seats = v_seats, min_capacity = least(min_capacity, v_seats), updated_at = now()
     where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc returning * into t;
    if not found then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  end if;
  return jsonb_build_object('id', t.id) || public.tbl_table_list(jsonb_build_object('location_id', v_loc));
end $$;

create or replace function public.tbl_table_remove(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
  t public.dining_tables%rowtype; v_state text; v_hidden boolean;
begin
  select * into t from public.dining_tables where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  select s.status into v_state from public.tbl_states(v_org, v_loc) s where s.table_id = t.id;
  if v_state = 'occupied' then raise exception 'TBL_WRONG_STATE: % has guests; settle its bill before removing it', t.label; end if;
  if v_state = 'reserved' then raise exception 'TBL_WRONG_STATE: % has a reservation; cancel it first', t.label; end if;
  v_hidden := exists (select 1 from public.orders o where o.table_id = t.id)
           or exists (select 1 from public.table_sessions x where x.table_id = t.id)
           or exists (select 1 from public.pos_reservations x where x.table_id = t.id::text)
           or exists (select 1 from public.table_merge_members x where x.table_id = t.id);
  if v_hidden then
    update public.dining_tables set is_active = false, qr_enabled = false, updated_at = now() where id = t.id;
  else
    delete from public.dining_tables where id = t.id;
  end if;
  return jsonb_build_object('removed', t.label, 'hidden', v_hidden) || public.tbl_table_list(jsonb_build_object('location_id', v_loc));
end $$;

revoke all on function public.tbl_table_list(jsonb) from public, anon;
revoke all on function public.tbl_table_save(jsonb) from public, anon;
revoke all on function public.tbl_table_remove(jsonb) from public, anon;
grant execute on function public.tbl_table_list(jsonb) to authenticated, service_role;
grant execute on function public.tbl_table_save(jsonb) to authenticated, service_role;
grant execute on function public.tbl_table_remove(jsonb) to authenticated, service_role;


-- ---- 0603_table_mark_clean.sql
-- 0603 "Mark as clean" (founder, 27 Oct 2026): a table shows Cleaning for 10 minutes after its bill is paid or its session closes
-- (tbl_states); floor staff can now end that early. Safe to run again.
--   * dining_tables.cleaned_at: when someone marked the table clean;
--   * tbl_states: a table marked clean after its last bill is not Cleaning (everything else exactly as before);
--   * tbl_mark_clean: only a Cleaning table; joined (merged) tables are one place, so every member is marked; floor staff only
--     (tbl_guard 'read': order place, order update status or table manager).


alter table public.dining_tables add column if not exists cleaned_at timestamptz;

create or replace function public.tbl_states(p_org uuid, p_loc uuid, p_table uuid default null::uuid)
 returns table(table_id uuid, status text, since timestamp with time zone, reserved_at timestamp with time zone, reservation_id uuid, open_orders integer)
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with t as (select id, cleaned_at from public.dining_tables
              where organization_id = p_org and is_active and coalesce(location_id, public.tbl_main(p_org)) = p_loc),
  oo as (select o.table_id, count(*)::int n, min(o.created_at) first_at from public.orders o
          where o.organization_id = p_org and o.table_id is not null and public.tbl_order_open(o.status, o.paid_at) group by o.table_id),
  ss as (select s.table_id, min(s.opened_at) first_at from public.table_sessions s where s.organization_id = p_org and s.status in ('open', 'billed') group by s.table_id),
  cl as (select x.table_id, max(x.at) at from (
           select o.table_id, coalesce(o.paid_at, o.updated_at) at from public.orders o
            where o.organization_id = p_org and o.table_id is not null and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
           union all select s.table_id, s.closed_at from public.table_sessions s where s.organization_id = p_org and s.status = 'closed' and s.closed_at is not null) x group by x.table_id),
  rv as (select distinct on (r.table_id) r.table_id, r.scheduled_at, r.row_id from public.pos_reservations r
          where r.organization_id = p_org and r.deleted_at is null and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending')
            and r.scheduled_at between now() - interval '30 minutes' and now() + interval '120 minutes'
          order by r.table_id, r.scheduled_at),
  base as (
    select t.id,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then 'occupied'
                -- 0603: marked clean after the last bill = not Cleaning any more
                when cl.at is not null and cl.at > now() - interval '10 minutes' and (t.cleaned_at is null or t.cleaned_at < cl.at) then 'cleaning'
                when rv.row_id is not null then 'reserved' else 'available' end st,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then least(coalesce(oo.first_at, ss.first_at), coalesce(ss.first_at, oo.first_at)) end sn,
           rv.scheduled_at rat, rv.row_id rid, coalesce(oo.n, 0) n
      from t left join oo on oo.table_id = t.id left join ss on ss.table_id = t.id left join cl on cl.table_id = t.id left join rv on rv.table_id = t.id::text),
  gm as (select m.table_id, m.merge_id from public.table_merge_members m where m.organization_id = p_org and m.released_at is null),
  -- joined tables are one place: occupied if ANY member is, the earliest booking of any member shows, the open orders add up
  agg as (select gm.merge_id, bool_or(b.st = 'occupied') occ, bool_or(b.st = 'cleaning') cln, sum(b.n)::int n, min(b.sn) sn, min(b.rat) rat,
                 (array_agg(b.rid order by b.rat) filter (where b.rid is not null))[1] rid
            from gm join base b on b.id = gm.table_id group by gm.merge_id)
  select b.id,
         case when g.merge_id is null then b.st when a.occ then 'occupied' when a.cln then 'cleaning' when a.rat is not null then 'reserved' else 'available' end,
         case when g.merge_id is null then b.sn when a.occ then a.sn end,
         case when g.merge_id is null then b.rat when not a.occ and not a.cln then a.rat end,
         case when g.merge_id is null then b.rid when not a.occ and not a.cln then a.rid end,
         case when g.merge_id is null then b.n else a.n end
    from base b left join gm g on g.table_id = b.id left join agg a on a.merge_id = g.merge_id
   where p_table is null or b.id = p_table;
$function$;

create or replace function public.tbl_mark_clean(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'table_id', '')::uuid;
  v_label text; v_state text; v_merge uuid; v_n int;
begin
  select label into v_label from public.dining_tables where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc;
  if v_label is null then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  if coalesce(v_state, '') <> 'cleaning' then
    raise exception 'TBL_WRONG_STATE: % is %, not cleaning', v_label, coalesce(v_state, 'available'); end if;
  select merge_id into v_merge from public.table_merge_members where table_id = v_id and organization_id = v_org and released_at is null limit 1;
  update public.dining_tables d set cleaned_at = now(), updated_at = now()
   where d.organization_id = v_org
     and (d.id = v_id or (v_merge is not null and d.id in (select m.table_id from public.table_merge_members m where m.merge_id = v_merge and m.released_at is null)));
  get diagnostics v_n = row_count;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  return jsonb_build_object('table_id', v_id, 'label', v_label, 'status', v_state, 'tables_marked', v_n);
end $$;

revoke all on function public.tbl_mark_clean(jsonb) from public, anon;
grant execute on function public.tbl_mark_clean(jsonb) to authenticated, service_role;


-- ---- 0604_bill_order_types.sql
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

-- ---- 0605_menu_can_make.sql
-- 0605: "200 can be made" on every dish (founder, 27 Oct 2026). How many of a dish the kitchen can still make, from its recipe (0600:
-- menu_item_recipes, with wastage) and each ingredient's stock on hand: the smallest floor(on hand / one serving) over its ingredients.
-- Orders already take their ingredients off stock when they go to the kitchen (order_stock_consume), so the count falls by one per dish
-- sent, and comes back if the order is cancelled. Read only. Safe to run again.
--   * menu_can_make(org, dish): the count; null when the dish has no recipe, or none of its ingredients has ever been stocked
--     (as 0601: a new business would otherwise see every dish at 0). Never below 0.
--   * pos_sell_catalog (the Bill's menu) answers can_make per dish; menu_stock_signals (the Menu tab) answers a can_make list.


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


-- ---- 0606_takeaway_lines.sql
-- 0606: takeaway dishes on a dine-in bill (founder, 27 Oct 2026). Guests eating at a table may also ask for some dishes to take away:
-- those go on the SAME table order (one bill) and each such line is marked takeaway, so the bill, the table's order and the kitchen
-- card say "Takeaway" (the kitchen packs it).
--   * order_items.is_takeaway (default false).
--   * tbl_order_add: a line may carry "takeaway": true. The lines of this call are marked after they are inserted (one row per line,
--     matched on dish and quantity among the rows this call added). Everything else is unchanged.
--   * tbl_order_view, rst_bill_order_json, kds_card_json, pos_order_view: each item also answers "takeaway".
-- The functions below are the live definitions with only those additions. Safe to run again.


alter table public.order_items add column if not exists is_takeaway boolean not null default false;

CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course)
    select o.id, mi.id, mi.name, (l->>'qty')::int, mi.price, nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat')
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org;
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
end $function$

;

CREATE OR REPLACE FUNCTION public.tbl_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype; mg jsonb; v_main uuid; v_grp uuid[]; v_st text; v_area text;
  v_update boolean; v_manage boolean; v_held boolean; v_bill boolean; v_place boolean;
begin
  t := public.tbl_get(v_org, v_loc, (p->>'table_id')::uuid);
  mg := public.tbl_merge_json(v_org, t.id);
  v_main := coalesce((mg->>'primary_table_id')::uuid, t.id);
  v_grp := public.tbl_group(v_org, t.id);
  select a.name into v_area from public.dining_areas a where a.id = t.area_id;
  v_update := public.has_permission(v_org, 'order', 'update_status', v_loc);
  v_place := public.has_permission(v_org, 'order', 'place', v_loc);
  v_manage := public.tbl_can_manage(v_org, v_loc);
  select o.status into v_st from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by o.created_at desc limit 1;
  -- 0485: dishes held (not yet sent) on an order the kitchen can still take
  select exists (select 1 from public.orders o join public.order_items i on i.order_id = o.id where o.organization_id = v_org and o.table_id = any(v_grp)
                  and o.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready') and i.kot_ticket_id is null and i.status = 'pending') into v_held;
  select exists (select 1 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and o.status in ('in_billing', 'sent_to_kitchen', 'ready', 'delivered') and public.tbl_order_open(o.status, o.paid_at)) into v_bill;
  return jsonb_build_object('table', jsonb_build_object('id', t.id, 'label', t.label, 'seats', coalesce((mg->>'combined_seats')::int, t.seats), 'area_name', v_area, 'main_table_id', v_main),
    'status', case when v_st is null then null else jsonb_build_object('key', v_st, 'label', case v_st
        when 'sent_to_kitchen' then 'ACTIVE IN KITCHEN' when 'new' then 'NOT SENT TO KITCHEN' when 'in_billing' then 'NOT SENT TO KITCHEN'
        when 'ready' then 'READY TO SERVE' when 'delivered' then 'SERVED' when 'awaiting_payment' then 'AWAITING PAYMENT' else upper(v_st) end) end,
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'total', o.total, 'subtotal', o.subtotal) order by o.created_at), '[]'::jsonb)
                 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price, 'line_total', i.unit_price * i.qty,
                'status', i.status, 'sent', i.kot_ticket_id is not null,
                'status_label', case when i.kot_ticket_id is null and i.status = 'pending' then 'Not sent' else case i.status when 'pending' then 'Pending' when 'preparing' then 'Preparing' when 'ready' then 'Ready' when 'delivered' then 'Served' else initcap(i.status) end end,
                'notes', i.notes) order by o.created_at, i.created_at, i.id), '[]'::jsonb)
                from public.order_items i join public.orders o on o.id = i.order_id
               where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) and i.status <> 'cancelled'),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at', e.created_at, 'message', e.message) order by e.created_at, e.id), '[]'::jsonb)
                   from (select ev.* from public.order_events ev join public.orders o on o.id = ev.order_id
                          where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by ev.created_at desc limit 30) e),
    'subtotal', (select coalesce(sum(o.subtotal), 0) from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'can', jsonb_build_object('add_items', v_place and (v_st is null or v_st in ('new', 'in_billing', 'sent_to_kitchen', 'ready')),
                              'send_kot', (v_update or v_place) and v_held, 'print_kot', false, 'change_table', v_manage and v_st is not null and (mg is null),
                              'merge_table', v_manage and v_st is not null and (mg is null), 'generate_bill', v_update and v_bill),
    'unavailable', jsonb_build_object('print_kot', 'Printing a KOT is not in this release.'));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone,
    'bill_generated', o.status = 'awaiting_payment',
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price,
                'line_total', i.unit_price * i.qty) order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'at', y.created_at,
                   'tendered', (select t.tendered from public.pos_cash_tenders t where t.payment_id = y.id)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'split', (select public.rst_split_json(s.id) from public.rst_bill_splits s where s.order_id = o.id and s.status in ('active', 'completed')
               order by s.created_at desc limit 1))
  from public.orders o where o.id = p_order;
$function$

;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$function$

;

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
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty,
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
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

;


-- ---- 0607_channel_orders.sql
-- 0607: the restaurant Orders tab's channel cards (founder, 27 Oct 2026): today's delivery orders by where they came from, each source a
-- card (count, total, who), and its orders. Read only. Safe to run again.
--   * onelocal  - ordered in the OneLocal app (an ol_orders row, or channel 'online')
--   * swiggy / zomato - from the aggregators (channel)
--   * on_call  - a phone order taken at the counter for delivery (channel 'delivery', not from the app)
-- Dine-in and takeaway are not here (the Bill and the live board have them). Cancelled orders are only counted.
-- Each order gets one plain status: new · preparing · ready · on_way · delivered, from the app order's status when there is one,
-- else from the POS order: new/in billing = new, sent to kitchen = preparing, ready = ready, awaiting payment = on the way
-- (cash to collect), paid/delivered = delivered.

create or replace function public.rst_channel_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name, ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
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
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$;

revoke all on function public.rst_channel_orders(jsonb) from public, anon;
grant execute on function public.rst_channel_orders(jsonb) to authenticated, service_role;

-- ---- 0608_home_insights.sql
-- 0608: more on the restaurant Home (founder, 27 Oct 2026): what the day's data already says, in one read. Read only. Safe to run again.
--   * mix:      today's orders by how they were served (dine in, takeaway, delivery), with sales and the average bill
--   * payments: today's money by method (cash, card, UPI, …)
--   * top:      today's five best-selling dishes, by quantity, with what they brought in
--   * menu:     how the menu stands: dishes with few left to make (from 0605's "can be made"), out of stock, average food cost and the dishes
--               over 45% (the Recipe tab's own figure, mb_recipe_json), and dishes missing a recipe, photo or description
--   * ready:    dishes the kitchen has made that are waiting to be served
-- "Today" is the store's day (its time zone). Cancelled orders and lines are left out.

create or replace function public.rst_home_insights(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.total, o.channel,
             case when o.channel = 'dine_in' then 'dine_in' when o.channel = 'pickup' then 'takeaway' else 'delivery' end as served
        from public.orders o
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
    ), li as (
      select i.menu_item_id, i.name, i.qty, i.unit_price from public.order_items i join o on o.id = i.order_id where i.status <> 'cancelled'
    ), dishes as materialized (
      select m.id, m.name, m.is_available, m.image_url, m.description,
             public.menu_can_make(v_org, m.id) as can_make,
             exists (select 1 from public.menu_item_recipes r where r.menu_item_id = m.id and r.organization_id = v_org) as has_recipe,
             (public.mb_recipe_json(v_org, m.id)->>'food_cost_pct')::numeric as food_pct
        from public.menu_items m where m.organization_id = v_org
    )
    select jsonb_build_object(
      'mix', jsonb_build_object(
        'orders', (select count(*) from o),
        'sales', (select coalesce(sum(total), 0) from o),
        'avg_bill', (select coalesce(round(avg(total), 2), 0) from o),
        'by', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label,
                  'orders', (select count(*) from o where o.served = k.key), 'sales', (select coalesce(sum(o.total), 0) from o where o.served = k.key)) order by k.sort)
               from (values ('dine_in', 'Dine in', 1), ('takeaway', 'Takeaway', 2), ('delivery', 'Delivery', 3)) k(key, label, sort))),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', x.method, 'amount', x.amount, 'count', x.n) order by x.amount desc), '[]')
                     from (select pm.method, sum(pm.amount) as amount, count(*) as n from public.payments pm
                            where pm.organization_id = v_org and pm.created_at >= v_since and pm.amount > 0
                              and (v_loc is null or exists (select 1 from public.orders x where x.id = pm.order_id and x.location_id = v_loc))
                            group by pm.method) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'sales', t.sales) order by t.qty desc, t.sales desc), '[]')
                from (select li.name, sum(li.qty) as qty, sum(li.qty * li.unit_price) as sales from li group by li.name order by 2 desc, 3 desc limit 5) t),
      'menu', jsonb_build_object(
        'dishes', (select count(*) from dishes),
        'low', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'can_make', d.can_make) order by d.can_make, d.name), '[]')
                  from (select * from dishes where can_make is not null and can_make < 10 order by can_make, name limit 5) d),
        'out', (select count(*) from dishes where not is_available or can_make = 0),
        'food_cost_avg', (select round(avg(food_pct), 1) from dishes where food_pct is not null),
        'high_cost', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'pct', round(d.food_pct, 1)) order by d.food_pct desc), '[]')
                        from (select * from dishes where food_pct > 45 order by food_pct desc limit 5) d),
        'no_recipe', (select count(*) from dishes where not has_recipe),
        'no_photo', (select count(*) from dishes where coalesce(btrim(image_url), '') = ''),
        'no_description', (select count(*) from dishes where coalesce(btrim(description), '') = '')),
      'ready', (select count(*) from public.order_items i join o on o.id = i.order_id where i.status = 'ready')
    )
  );
end $$;

revoke all on function public.rst_home_insights(jsonb) from public, anon;
grant execute on function public.rst_home_insights(jsonb) to authenticated, service_role;

-- ---- 0609_kot_orders.sql
-- 0609: the KOT view (founder, 27 Oct 2026): today's orders that went to the kitchen, one card each: its status, total, table or source,
-- dishes and how many are ready, the captain and whether it is paid, every KOT in order (KOT 1 › KOT 2 › …) with its own progress, and the
-- stations with a tick when they are done. Read only. Safe to run again.
--   stage: new (nothing started) · preparing · ready (every dish ready or served, not paid) · completed (paid or delivered)
--   [status] filters: all, preparing (new + preparing), ready, completed.
-- A dish counts as ready when it is, or when its KOT is (the kitchen may close a whole ticket).
-- ready_item_ids are the dishes Serve hands over (tbl_mark_served); latest_ticket is the newest KOT (for Print).

create or replace function public.rst_kot_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

revoke all on function public.rst_kot_orders(jsonb) from public, anon;
grant execute on function public.rst_kot_orders(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
