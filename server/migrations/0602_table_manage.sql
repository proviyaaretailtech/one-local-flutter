-- 0602 Manage tables in the app (founder, 27 Oct 2026): create, rename, change seats, remove. Until now nothing in the app could make a
-- table (dining_tables had no writer). Safe to run again.
--   * who: tbl_guard(p, 'manage') -> tbl_can_manage (dining_tables:manage, or both order place and order update_status) at that outlet;
--   * a name is unique per outlet; making a name that a removed (hidden) table had brings that table back, with its history;
--   * remove: refused while the table is occupied or has an upcoming reservation; a table that has orders or other history is hidden
--     (is_active = false: the floor no longer shows it, past bills keep pointing at it); a table with no history is deleted.

begin;

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

commit;
