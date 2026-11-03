-- ==========================================================================================================================
-- HOSTED: 0642 Manage reservations (3 Nov 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- The day's bookings (tbl_reservations_list), seat the guests (tbl_reserve_seat), cancel / no-show with a reason; the reserved table's
-- sheet shows its bookings with Seat, No-show and Cancel. Nothing is deleted.
-- ==========================================================================================================================
begin;
-- 0642: manage reservations (founder, 3 Nov 2026: "Reservations can be made but not listed, cancelled, marked no-show or seated. A reserved
-- table has nothing to tap."). tbl_reserve made bookings; tbl_reserve_cancel could cancel or mark a no-show but nothing in the app called it;
-- a booking was only ever seated by itself, when an order was started on its table (orders_seat_reservation).
--   * tbl_reservations_list: the bookings of one day at the outlet (the store's own calendar day), by status (upcoming / seated /
--     cancelled / no_show / all) with counts, each with its table, local time, whether it is late, and what this person may do.
--   * tbl_reserve_seat: the guests have arrived. The booking is seated at its table, or at another free table that fits them (the booking
--     moves there). Not more than two hours early; not at a table with an open bill.
--   * tbl_reserve_cancel: + a reason, and when it happened (outcome_reason, outcome_at).
--   * pos_reservations: + seated_at, outcome_reason, outcome_at; tbl_reservation_json shows them and the store's local date and time.
--   * orders_seat_reservation (an order started on the table seats its booking): + seated_at.
-- Nothing is deleted. Safe to run again.

alter table public.pos_reservations add column if not exists seated_at timestamptz;
alter table public.pos_reservations add column if not exists outcome_reason text;
alter table public.pos_reservations add column if not exists outcome_at timestamptz;

create or replace function public.tbl_reservation_json(r public.pos_reservations, p_label text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.row_id, 'table_id', r.table_id, 'table_label', p_label, 'guest_name', r.guest_name, 'phone', r.phone, 'guests', r.guests,
    'scheduled_at', r.scheduled_at, 'status', lower(r.status), 'notes', r.notes,
    'local_date', to_char(r.scheduled_at at time zone public.tbl_tz(coalesce(r.location_id, public.tbl_main(r.organization_id))), 'YYYY-MM-DD'),
    'local_time', to_char(r.scheduled_at at time zone public.tbl_tz(coalesce(r.location_id, public.tbl_main(r.organization_id))), 'HH24:MI'),
    'seated_at', r.seated_at, 'outcome_reason', r.outcome_reason, 'outcome_at', r.outcome_at,
    'late', lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending') and r.scheduled_at < now() - interval '15 minutes');
$$;

-- what may be done with a booking now: seat it (from two hours before), mark a no-show (once its time has passed), cancel it
create or replace function public.tbl__reservation_can(r public.pos_reservations, p_may boolean) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'seat', p_may and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending') and r.scheduled_at <= now() + interval '2 hours',
    'no_show', p_may and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending') and r.scheduled_at <= now(),
    'cancel', p_may and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending'));
$$;
revoke all on function public.tbl__reservation_can(public.pos_reservations, boolean) from public, anon, authenticated;

-- The bookings of one day ({location_id, date: YYYY-MM-DD in the store's calendar, default today; status}), earliest first
create or replace function public.tbl_reservations_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_tz text := public.tbl_tz(v_loc); v_day date;
  v_st text := coalesce(nullif(p->>'status', ''), 'upcoming'); v_from timestamptz; v_to timestamptz; v_may boolean;
begin
  if v_st not in ('upcoming', 'seated', 'cancelled', 'no_show', 'all') then raise exception 'TBL_BAD_REQUEST: unknown filter'; end if;
  begin v_day := coalesce(nullif(p->>'date', '')::date, (now() at time zone v_tz)::date);
  exception when others then raise exception 'TBL_BAD_REQUEST: choose the day again'; end;
  v_from := v_day::timestamp at time zone v_tz;
  v_to := (v_day + 1)::timestamp at time zone v_tz;
  v_may := public.has_permission(v_org, 'order', 'place', v_loc) or public.has_permission(v_org, 'dining_tables', 'manage', v_loc);
  return (
    with r as (
      select x.*, case when lower(x.status) in ('confirmed', 'reserved', 'booked', 'pending') then 'upcoming' else lower(x.status) end as bucket,
             (select d.label from public.dining_tables d where d.id::text = x.table_id and d.organization_id = v_org) as label
        from public.pos_reservations x
       where x.organization_id = v_org and x.deleted_at is null and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
         and x.scheduled_at >= v_from and x.scheduled_at < v_to)
    select jsonb_build_object('date', v_day, 'today', (now() at time zone v_tz)::date, 'local_time', to_char(now() at time zone v_tz, 'HH24:MI'),
      'can_reserve', v_may,
      'counts', jsonb_build_object('upcoming', (select count(*) from r where bucket = 'upcoming'), 'seated', (select count(*) from r where bucket = 'seated'),
                                   'cancelled', (select count(*) from r where bucket = 'cancelled'), 'no_show', (select count(*) from r where bucket = 'no_show'),
                                   'all', (select count(*) from r), 'late', (select count(*) from r where bucket = 'upcoming' and scheduled_at < now() - interval '15 minutes'),
                                   'guests', (select coalesce(sum(guests), 0) from r where bucket in ('upcoming', 'seated'))),
      'reservations', (select coalesce(jsonb_agg(public.tbl_reservation_json(r2, r.label) || jsonb_build_object('can', public.tbl__reservation_can(r2, v_may))
                                                 order by r.scheduled_at, r.created_at), '[]'::jsonb)
                         from r join public.pos_reservations r2 on r2.row_id = r.row_id
                        where v_st = 'all' or r.bucket = v_st)));
end $$;

-- The guests have arrived: {id, table_id (optional: seat them at another free table)}
create or replace function public.tbl_reserve_seat(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'reserve'); v_org uuid := public.current_org_id(); r public.pos_reservations%rowtype; t public.dining_tables%rowtype;
  s record; mg jsonb; v_seats int; v_to uuid; v_was text;
begin
  select * into r from public.pos_reservations where row_id = nullif(p->>'id', '')::uuid and organization_id = v_org and deleted_at is null
     and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: reservation not found'; end if;
  v_was := r.table_id;
  if lower(r.status) = 'seated' then raise exception 'TBL_CONFLICT: these guests are already seated'; end if;
  if lower(r.status) not in ('confirmed', 'reserved', 'booked', 'pending') then raise exception 'TBL_CONFLICT: this reservation is %', replace(lower(r.status), '_', '-'); end if;
  if r.scheduled_at > now() + interval '2 hours' then raise exception 'TBL_BAD_REQUEST: this booking is for later; guests can be seated from two hours before'; end if;
  v_to := coalesce(nullif(p->>'table_id', '')::uuid, nullif(r.table_id, '')::uuid);
  if v_to is null then raise exception 'TBL_BAD_REQUEST: choose a table for these guests'; end if;
  t := public.tbl_get(v_org, v_loc, v_to);
  select * into s from public.tbl_states(v_org, v_loc, t.id);
  if s.status = 'occupied' then raise exception 'TBL_CONFLICT: table % still has guests with an open bill; seat them at another table', t.label; end if;
  mg := public.tbl_merge_json(v_org, t.id);
  if mg is not null and not (mg->>'primary')::boolean then raise exception 'TBL_MERGED: this table is joined to another; seat them at the main table'; end if;
  v_seats := coalesce((mg->>'combined_seats')::int, t.seats);
  if r.guests > v_seats then raise exception 'TBL_CAPACITY: table % has % seats for % guests', t.label, v_seats, r.guests; end if;
  update public.pos_reservations set status = 'seated', seated_at = now(), table_id = t.id::text, updated_by = auth.uid(), outcome_at = now()
   where row_id = r.row_id returning * into r;
  return jsonb_build_object('reservation', public.tbl_reservation_json(r, t.label),
    'table', jsonb_build_object('id', t.id, 'label', t.label, 'seats', v_seats), 'moved', v_was is distinct from t.id::text);
end $$;

-- Cancel or mark a no-show ({id, outcome: cancelled | no_show, reason})
create or replace function public.tbl_reserve_cancel(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'reserve'); v_org uuid := public.current_org_id(); r public.pos_reservations%rowtype; v_label text;
  v_to text := coalesce(nullif(p->>'outcome', ''), 'cancelled'); v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
begin
  if v_to not in ('cancelled', 'no_show') then raise exception 'TBL_BAD_REQUEST: outcome must be cancelled or no_show'; end if;
  if length(coalesce(v_reason, '')) > 200 then raise exception 'TBL_BAD_REQUEST: keep the reason under 200 characters'; end if;
  select * into r from public.pos_reservations where row_id = (p->>'id')::uuid and organization_id = v_org and deleted_at is null and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: reservation not found'; end if;
  if lower(r.status) not in ('confirmed', 'reserved', 'booked', 'pending') then raise exception 'TBL_CONFLICT: this reservation is already %', replace(lower(r.status), '_', '-'); end if;
  if v_to = 'no_show' and r.scheduled_at > now() then raise exception 'TBL_BAD_REQUEST: a booking cannot be a no-show before its time'; end if;
  update public.pos_reservations set status = v_to, updated_by = auth.uid(), outcome_reason = v_reason, outcome_at = now() where row_id = r.row_id returning * into r;
  select label into v_label from public.dining_tables where id::text = r.table_id and organization_id = v_org;
  return jsonb_build_object('reservation', public.tbl_reservation_json(r, v_label));
end $$;

-- an order started on the table seats its booking (as before), and now says when
create or replace function public.orders_seat_reservation() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.pos_reservations set status = 'seated', seated_at = now(), outcome_at = now(), updated_by = coalesce(auth.uid(), updated_by)
   where row_id = (select r.row_id from public.pos_reservations r
                    where r.organization_id = new.organization_id and r.table_id = any(array(select u::text from unnest(public.tbl_group(new.organization_id, new.table_id)) u))
                      and r.deleted_at is null and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending')
                      and r.scheduled_at between now() - interval '30 minutes' and now() + interval '120 minutes'
                    order by abs(extract(epoch from r.scheduled_at - now())) limit 1);
  return null;
end $$;

revoke all on function public.tbl_reservations_list(jsonb) from public, anon;
revoke all on function public.tbl_reserve_seat(jsonb) from public, anon;
grant execute on function public.tbl_reservations_list(jsonb) to authenticated, service_role;
grant execute on function public.tbl_reserve_seat(jsonb) to authenticated, service_role;

-- tbl_view (the table sheet): its bookings now carry what may be done with them, so a reserved table can be seated, cancelled or marked a no-show
CREATE OR REPLACE FUNCTION public.tbl_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $tv$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype; s record; mg jsonb; v_main uuid; v_grp uuid[]; v_bill numeric;
  v_guests int; v_waiter text; v_allowed text[] := array[]::text[]; v_manage boolean; v_reserve boolean; v_order boolean; v_area text;
begin
  t := public.tbl_get(v_org, v_loc, (p->>'table_id')::uuid);
  select * into s from public.tbl_states(v_org, v_loc, t.id);
  mg := public.tbl_merge_json(v_org, t.id);
  v_main := coalesce((mg->>'primary_table_id')::uuid, t.id);
  v_grp := public.tbl_group(v_org, t.id);
  v_manage := public.tbl_can_manage(v_org, v_loc);
  v_reserve := public.has_permission(v_org, 'order', 'place', v_loc) or public.has_permission(v_org, 'dining_tables', 'manage', v_loc);
  v_order := public.has_permission(v_org, 'order', 'place', v_loc);
  select a.name into v_area from public.dining_areas a where a.id = t.area_id;
  select coalesce(sum(o.total), 0), max(o.guest_count) into v_bill, v_guests from public.orders o
   where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at);
  select coalesce((select ts.guest_count from public.table_sessions ts where ts.organization_id = v_org and ts.table_id = any(v_grp) and ts.status in ('open', 'billed') limit 1), v_guests) into v_guests;
  select coalesce(nullif(btrim(o.captain_name), ''), public.tbl_initials((select ou.full_name from public.org_users ou where ou.organization_id = v_org and ou.user_id = o.created_by limit 1)))
    into v_waiter from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by o.created_at desc limit 1;
  v_allowed := array['history'];
  if s.status = 'occupied' then v_allowed := array_prepend('open_order'::text, v_allowed); end if;
  if mg is null then
    if s.status = 'occupied' then
      if v_manage then v_allowed := v_allowed || array['transfer', 'merge']; end if;
    else
      if v_order then v_allowed := array_prepend('start_order'::text, v_allowed); end if;
      if v_manage then v_allowed := array_append(v_allowed, 'merge'::text); end if;
    end if;
    if v_reserve then v_allowed := array_append(v_allowed, 'reserve'::text); end if;
  else
    if (mg->>'primary')::boolean then
      if s.status <> 'occupied' and v_order then v_allowed := array_prepend('start_order'::text, v_allowed); end if;
      if v_reserve then v_allowed := array_append(v_allowed, 'reserve'::text); end if;
    end if;
    if v_manage then v_allowed := array_append(v_allowed, 'split'::text); end if;
  end if;
  return jsonb_build_object('table', jsonb_build_object('id', t.id, 'label', t.label, 'seats', coalesce((mg->>'combined_seats')::int, t.seats), 'own_seats', t.seats,
        'min_capacity', t.min_capacity, 'area_id', t.area_id, 'area_name', v_area, 'main_table_id', v_main),
    'status', s.status, 'since', s.since, 'elapsed_minutes', case when s.since is not null then greatest(0, floor(extract(epoch from now() - s.since) / 60))::int end,
    'reserved_at', s.reserved_at, 'merge', mg, 'channel', case when s.status = 'occupied' then 'dine_in' end,
    'guests', case when s.status = 'occupied' then v_guests end, 'waiter', case when s.status = 'occupied' then v_waiter end,
    'bill_total', v_bill,
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'total', o.total, 'created_at', o.created_at) order by o.created_at), '[]'::jsonb)
                 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    -- 0642: each booking with its phone, notes, local time and what may be done (seat, no-show, cancel); late bookings stay until handled
    'reservations', (select coalesce(jsonb_agg(public.tbl_reservation_json(r, (select d.label from public.dining_tables d where d.id::text = r.table_id))
                                               || jsonb_build_object('can', public.tbl__reservation_can(r, v_reserve)) order by r.scheduled_at), '[]'::jsonb)
                       from public.pos_reservations r
                      where r.row_id in (select x.row_id from public.pos_reservations x where x.organization_id = v_org and x.table_id = any(array(select u::text from unnest(v_grp) u))
                                           and x.deleted_at is null and lower(x.status) in ('confirmed', 'reserved', 'booked', 'pending')
                                           and x.scheduled_at > now() - interval '3 hours'
                                         order by x.scheduled_at limit 5)),
    'allowed', to_jsonb(v_allowed));
end $tv$;

notify pgrst, 'reload schema';
commit;
