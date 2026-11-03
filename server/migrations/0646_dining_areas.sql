-- 0646: Dining areas in table management (founder, 3 Nov 2026: "Kitchen setup (stations) has no button that opens it. Inside it, 'Add
-- printer' and 'Add area' say 'later release'. (add area is part of table management add a feature there)", with the Dining Areas page of
-- the web panel as the reference). The floor already groups and orders tables by dining area, and tables join only within one area, but
-- nothing could make an area or put a table in one.
--   * dining_areas: + area_type (indoor, outdoor, rooftop, ac_hall, garden, private, bar, terrace), is_active, updated_at
--   * tbl_areas: the outlet's areas with their tables, the stats (areas, tables linked, areas in use, needing tables, the largest), and
--     the next confirmed booking per table
--   * tbl_area_save (add / rename / change type), tbl_area_set_active, tbl_area_reorder (the order the floor and order-taking show them),
--     tbl_area_delete (only an area with no tables), tbl_area_tables (which tables are in an area; joined tables move together or not at all)
--   * tbl_floor: an area switched off is not offered: its free tables leave the floor (ones with guests, a booking or cleaning stay)
-- Who: anyone on the floor sees them; table managers change them. Safe to run again.

alter table public.dining_areas add column if not exists area_type text not null default 'indoor';
alter table public.dining_areas add column if not exists is_active boolean not null default true;
alter table public.dining_areas add column if not exists updated_at timestamptz not null default now();
do $$ begin
  -- not valid: rows written before (by any tool) are left as they are; new and changed rows are checked
  alter table public.dining_areas add constraint dining_areas_type_check check (area_type in ('indoor', 'outdoor', 'rooftop', 'ac_hall', 'garden', 'private', 'bar', 'terrace')) not valid;
exception when duplicate_object then null; end $$;

create or replace function public.tbl__area_json(a public.dining_areas) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'area_type', a.area_type, 'active', a.is_active, 'sort_order', a.sort_order,
    'tables', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label, 'seats', t.seats) order by t.sort_order, length(t.label), t.label), '[]'::jsonb)
                 from public.dining_tables t where t.area_id = a.id and t.is_active),
    'table_count', (select count(*) from public.dining_tables t where t.area_id = a.id and t.is_active),
    'seats', (select coalesce(sum(t.seats), 0) from public.dining_tables t where t.area_id = a.id and t.is_active));
$$;
revoke all on function public.tbl__area_json(public.dining_areas) from public, anon, authenticated;

-- The outlet's dining areas ({location_id}), first to last as the floor shows them
create or replace function public.tbl_areas(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_tz text := public.tbl_tz(v_loc);
begin
  return (
    with a as (select x.*, public.tbl__area_json(x) j from public.dining_areas x
                where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc),
    t as (select x.* from public.dining_tables x where x.organization_id = v_org and x.is_active and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc),
    nb as (select distinct on (r.table_id) r.*, t.label, (select ar.name from public.dining_areas ar where ar.id = t.area_id) area_name
             from public.pos_reservations r join t on t.id::text = r.table_id
            where r.organization_id = v_org and r.deleted_at is null and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending')
              and r.scheduled_at > now() - interval '30 minutes'
            order by r.table_id, r.scheduled_at)
    select jsonb_build_object(
      'areas', (select coalesce(jsonb_agg(a.j order by a.sort_order, a.name), '[]'::jsonb) from a),
      'stats', jsonb_build_object(
        'areas', (select count(*) from a), 'active', (select count(*) from a where is_active), 'inactive', (select count(*) from a where not is_active),
        'tables', (select count(*) from t), 'tables_linked', (select count(*) from t where t.area_id in (select id from a)),
        'tables_unassigned', (select count(*) from t where t.area_id is null or t.area_id not in (select id from a)),
        'in_use', (select count(*) from a where (a.j->>'table_count')::int > 0), 'needs_tables', (select count(*) from a where (a.j->>'table_count')::int = 0),
        'largest', (select jsonb_build_object('name', a.name, 'tables', (a.j->>'table_count')::int) from a where (a.j->>'table_count')::int > 0
                     order by (a.j->>'table_count')::int desc, a.sort_order limit 1)),
      'upcoming', (select coalesce(jsonb_agg(jsonb_build_object('id', nb.row_id, 'table_label', nb.label, 'area_name', nb.area_name, 'guest_name', nb.guest_name,
                     'guests', nb.guests, 'scheduled_at', nb.scheduled_at, 'local_date', to_char(nb.scheduled_at at time zone v_tz, 'YYYY-MM-DD'),
                     'local_time', to_char(nb.scheduled_at at time zone v_tz, 'HH24:MI')) order by nb.scheduled_at), '[]'::jsonb)
                   from (select * from nb order by scheduled_at limit 10) nb),
      'types', jsonb_build_array('indoor', 'outdoor', 'rooftop', 'ac_hall', 'garden', 'private', 'bar', 'terrace'),
      'can', jsonb_build_object('manage', public.tbl_can_manage(v_org, v_loc))));
end $$;

-- Add or change an area: {location_id, id (to change), name, area_type}
create or replace function public.tbl_area_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_id uuid; v_name text := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  v_type text := coalesce(nullif(p->>'area_type', ''), 'indoor'); a public.dining_areas%rowtype;
begin
  begin v_id := nullif(p->>'id', '')::uuid; exception when others then raise exception 'TBL_BAD_REQUEST: not a valid area'; end;
  if char_length(v_name) not between 1 and 40 then raise exception 'TBL_BAD_REQUEST: give the area a name of up to 40 characters (for example Rooftop)'; end if;
  if v_type not in ('indoor', 'outdoor', 'rooftop', 'ac_hall', 'garden', 'private', 'bar', 'terrace') then raise exception 'TBL_BAD_REQUEST: choose the kind of area'; end if;
  if exists (select 1 from public.dining_areas x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
               and lower(x.name) = lower(v_name) and x.id is distinct from v_id) then
    raise exception 'TBL_CONFLICT: there is already an area called %', v_name; end if;
  if v_id is null then
    if (select count(*) from public.dining_areas x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc) >= 30 then
      raise exception 'TBL_BAD_REQUEST: an outlet can have up to 30 areas'; end if;
    insert into public.dining_areas (organization_id, location_id, name, area_type, sort_order)
    values (v_org, v_loc, v_name, v_type,
            coalesce((select max(x.sort_order) + 1 from public.dining_areas x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc), 1))
    returning * into a;
  else
    update public.dining_areas set name = v_name, area_type = v_type, updated_at = now()
     where id = v_id and organization_id = v_org and coalesce(location_id, public.tbl_main(v_org)) = v_loc returning * into a;
    if not found then raise exception 'TBL_NOT_FOUND: area not found'; end if;
  end if;
  return jsonb_build_object('area', public.tbl__area_json(a));
end $$;

-- Switch an area on or off: {location_id, id, active}
create or replace function public.tbl_area_set_active(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); a public.dining_areas%rowtype; v_on boolean;
begin
  begin v_on := (p->>'active')::boolean; exception when others then v_on := null; end;
  if v_on is null then raise exception 'TBL_BAD_REQUEST: active is true or false'; end if;
  update public.dining_areas set is_active = v_on, updated_at = now()
   where id = nullif(p->>'id', '')::uuid and organization_id = v_org and coalesce(location_id, public.tbl_main(v_org)) = v_loc returning * into a;
  if not found then raise exception 'TBL_NOT_FOUND: area not found'; end if;
  return jsonb_build_object('area', public.tbl__area_json(a));
end $$;

-- The order of the areas, first to last: {location_id, ids: every area of the outlet once}
create or replace function public.tbl_area_reorder(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_ids uuid[];
begin
  begin v_ids := array(select (x)::uuid from jsonb_array_elements_text(p->'ids') x); exception when others then raise exception 'TBL_BAD_REQUEST: the order is a list of areas'; end;
  if v_ids is null or cardinality(v_ids) = 0 or cardinality(v_ids) <> (select count(distinct x) from unnest(v_ids) x)
     or (select array_agg(x.id order by x.id) from public.dining_areas x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc)
        is distinct from (select array_agg(x order by x) from unnest(v_ids) x) then
    raise exception 'TBL_CONFLICT: the areas changed on another device; refresh and try again'; end if;
  update public.dining_areas a set sort_order = o.n, updated_at = now() from unnest(v_ids) with ordinality o(id, n) where a.id = o.id;
  return public.tbl_areas(jsonb_build_object('location_id', v_loc));
end $$;

-- Delete an area that has no tables: {location_id, id}
create or replace function public.tbl_area_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); a public.dining_areas%rowtype; v_n int;
begin
  select * into a from public.dining_areas where id = nullif(p->>'id', '')::uuid and organization_id = v_org and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: area not found'; end if;
  select count(*) into v_n from public.dining_tables t where t.area_id = a.id and t.is_active;
  if v_n > 0 then raise exception 'TBL_CONFLICT: % has % table%; move them to another area first', a.name, v_n, case when v_n = 1 then '' else 's' end; end if;
  update public.dining_tables set area_id = null, updated_at = now() where area_id = a.id;   -- removed tables let go of it too
  delete from public.dining_areas where id = a.id;
  return jsonb_build_object('deleted', a.id, 'name', a.name);
end $$;

-- Which tables are in an area: {location_id, id, table_ids}. Tables listed move here; ones here and not listed leave it (no area).
-- Joined tables are one place: they move together or not at all.
create or replace function public.tbl_area_tables(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); a public.dining_areas%rowtype; v_ids uuid[]; v_bad text;
begin
  select * into a from public.dining_areas where id = nullif(p->>'id', '')::uuid and organization_id = v_org and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: area not found'; end if;
  begin v_ids := array(select (x)::uuid from jsonb_array_elements_text(coalesce(p->'table_ids', '[]'::jsonb)) x); exception when others then raise exception 'TBL_BAD_REQUEST: choose the tables again'; end;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.dining_tables t where t.id = x and t.organization_id = v_org and t.is_active
                                                                and coalesce(t.location_id, public.tbl_main(v_org)) = v_loc)) then
    raise exception 'TBL_NOT_FOUND: a table was not found'; end if;
  -- joined tables must end in one area: each table's area after this change, then any joined group that would be split up
  with fin as (select t.id, t.label, m.merge_id,
                      case when t.id = any (v_ids) then a.id when t.area_id = a.id then null else t.area_id end as area_after
                 from public.dining_tables t join public.table_merge_members m on m.table_id = t.id and m.released_at is null
                where t.organization_id = v_org),
       split as (select merge_id from fin group by merge_id having count(distinct coalesce(area_after::text, '-')) > 1)
  select string_agg(distinct fin.label, ', ') into v_bad from fin join split using (merge_id);
  if v_bad is not null then raise exception 'TBL_MERGED: % % joined to other tables; move all of them together or split them first', v_bad, case when position(',' in v_bad) > 0 then 'are' else 'is' end; end if;
  update public.dining_tables set area_id = null, updated_at = now() where area_id = a.id and not (id = any (v_ids));
  update public.dining_tables set area_id = a.id, updated_at = now() where id = any (v_ids) and area_id is distinct from a.id;
  return jsonb_build_object('area', public.tbl__area_json(a));
end $$;

do $$ declare f text; begin
  foreach f in array array['tbl_areas(jsonb)', 'tbl_area_save(jsonb)', 'tbl_area_set_active(jsonb)', 'tbl_area_reorder(jsonb)', 'tbl_area_delete(jsonb)', 'tbl_area_tables(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- tbl_floor: areas switched off are not offered
CREATE OR REPLACE FUNCTION public.tbl_floor(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_status text := nullif(p->>'status', ''); v_area uuid := nullif(p->>'area_id', '')::uuid;
  v_tz text := public.tbl_tz(v_loc);
begin
  if v_status is not null and v_status not in ('all', 'available', 'occupied', 'reserved', 'cleaning') then raise exception 'TBL_BAD_REQUEST: unknown filter'; end if;
  return (with s as (select * from public.tbl_states(v_org, v_loc)),
    tb as (select t.id, t.label, t.seats, t.area_id, a.name area_name, a.sort_order area_order, a.is_active area_on, t.sort_order, s.status, s.since, s.reserved_at, s.reservation_id,
                  public.tbl_merge_json(v_org, t.id) mg
             from public.dining_tables t join s on s.table_id = t.id left join public.dining_areas a on a.id = t.area_id)
  select jsonb_build_object(
    'location', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'timezone', v_tz) from public.locations where id = v_loc),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.sort_order, a.name), '[]'::jsonb) from public.dining_areas a
               where a.organization_id = v_org and coalesce(a.location_id, public.tbl_main(v_org)) = v_loc and a.is_active),
    'tables', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label, 'seats', coalesce((mg->>'combined_seats')::int, seats), 'own_seats', seats,
                 'area_id', area_id, 'area_name', area_name, 'status', status, 'since', since,
                 'elapsed_minutes', case when since is not null then greatest(0, floor(extract(epoch from now() - since) / 60))::int end,
                 'reserved_at', reserved_at, 'reserved_local', to_char(reserved_at at time zone v_tz, 'HH24:MI'), 'reservation_id', reservation_id, 'merge', mg)
                 order by coalesce(area_order, 0), sort_order, length(label), label), '[]'::jsonb)
               -- 0646: an area switched off is not offered: its free tables leave the floor (guests, a booking or cleaning keep them)
               from tb where (v_status is null or v_status = 'all' or status = v_status) and (v_area is null or area_id = v_area)
                 and (area_on is not false or status <> 'available')),
    'counts', (select jsonb_build_object('all', count(*) filter (where area_on is not false or status <> 'available'), 'available', count(*) filter (where status = 'available' and area_on is not false), 'occupied', count(*) filter (where status = 'occupied'),
                 'reserved', count(*) filter (where status = 'reserved'), 'cleaning', count(*) filter (where status = 'cleaning')) from tb),
    'rule', jsonb_build_object('merge', 'Tables must be in the same dining area to combine.', 'merge_min', 2, 'merge_max', 8),
    'can', jsonb_build_object('reserve', public.has_permission(v_org, 'order', 'place', v_loc) or public.has_permission(v_org, 'dining_tables', 'manage', v_loc),
                              'manage', public.tbl_can_manage(v_org, v_loc),
                              'order', public.has_permission(v_org, 'order', 'place', v_loc)),
    'now', now(), 'timezone', v_tz, 'local_today', to_char(now() at time zone v_tz, 'YYYY-MM-DD'), 'local_time', to_char(now() at time zone v_tz, 'HH24:MI')));
end $f$;
