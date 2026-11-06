-- LOCAL TEST DATA ONLY, never for hosted. Fills every tab of the Service POS Bill tab (Today) for Demo Services, for the time it is run.
-- Run again any day; on the same day it changes nothing already there. Run it early enough for the bookings to fall on the same day.
-- Run after service_demo_seed.sql:
--   docker cp db/seed/service_today_test_bookings.sql supabase_db_onelocal-dev:/tmp/t.sql
--   docker exec supabase_db_onelocal-dev psql -U supabase_admin -d postgres -f /tmp/t.sql
-- Every booking's customer starts with "Test".
begin;

create temp table ctx as
  select ou.user_id, ou.organization_id org, (date_bin('5 minutes', now(), timestamptz '2000-01-01') + interval '5 minutes') base, ((now() at time zone 'Asia/Kolkata')::date)::text tag
    from org_users ou join organizations o on o.id = ou.organization_id where o.name ilike '%demo serv%' and ou.status = 'active' order by ou.created_at limit 1;
grant select on ctx to authenticated;

-- the listings this business lacks: an event booked by the ticket, an activity, a room
create function pg_temp.listing(p_name text, p_from text, p_price numeric, p_cat text, p_fulfil text, p_cap int, p_mins int, p_listing jsonb) returns void language plpgsql as $$
declare v_from uuid; v_new uuid := gen_random_uuid(); v_org uuid := (select org from ctx); v_cols text;
begin
  if exists (select 1 from menu_items m where m.organization_id = v_org and m.name = p_name) then return; end if;
  select m.id into v_from from menu_items m join svc_services s on s.menu_item_id = m.id where m.organization_id = v_org and m.name = p_from;
  create temp table mi on commit drop as select * from menu_items where id = v_from;
  update mi set id = v_new, name = p_name, price = p_price;
  select string_agg(quote_ident(column_name), ', ') into v_cols from information_schema.columns where table_schema = 'public' and table_name = 'menu_items' and is_generated = 'NEVER';
  execute format('insert into menu_items (%1$s) select %1$s from mi', v_cols);
  drop table mi;
  create temp table sv on commit drop as select * from svc_services where menu_item_id = v_from;
  update sv set menu_item_id = v_new, listing_category = p_cat, fulfilment = p_fulfil, capacity = p_cap, duration_min = p_mins, buffer_min = 0, min_notice_min = 0, is_bookable = true, checklist = '{}',
                code = upper(left(p_cat, 3)) || '-T' || floor(random() * 900 + 100)::int, listing = p_listing;
  insert into svc_services select * from sv;
  drop table sv;
  insert into svc_provider_services (staff_id, menu_item_id, organization_id)
    select ps.staff_id, v_new, v_org from svc_provider_services ps where ps.menu_item_id = v_from;
end $$;
select pg_temp.listing('Music night', 'Yoga workshop', 200, 'events', 'event', 30, 120, '{"booking_type":"Entry","capacity":"30"}');
select pg_temp.listing('Pottery class', 'Yoga workshop', 500, 'activities', 'appointment', 8, 90, '{"booking_type":"Entry","capacity":"8"}');
select pg_temp.listing('Garden room', 'Consultation', 2000, 'stay', 'appointment', 2, 600,
  '{"booking_type":"Slot","unit_kind":"Room","units":[{"name":"Room 1"},{"name":"Room 2"}]}');
-- booked by the room for now: a "Nights" listing ties up one staff member for the whole stay, until the date range fix
update svc_services s set listing = '{"booking_type":"Slot","unit_kind":"Room","units":[{"name":"Room 1"},{"name":"Room 2"}]}'
  from menu_items m where m.id = s.menu_item_id and m.name = 'Garden room' and s.organization_id = (select org from ctx);

-- open all day and with no price rules only while these are booked; everything goes back below
create temp table keep_loc as select * from svc_location_hours;
create temp table keep_work as select id, start_time, end_time from svc_working_hours;
create temp table keep_sv as select menu_item_id, listing, min_notice_min from svc_services where organization_id = (select org from ctx);
update svc_location_hours set open_time = '00:00', close_time = '24:00', break_start = null, break_end = null;
update svc_working_hours set start_time = '00:00', end_time = '23:59';
update svc_services set min_notice_min = 0, listing = listing - 'rules' - 'gender_rule' - 'people_min' - 'people_max' - 'age_rule' where organization_id = (select org from ctx);

select set_config('request.jwt.claims', json_build_object('sub', user_id, 'org_id', org, 'role', 'authenticated')::text, true) from ctx;
set local role authenticated;

-- one booking: who, what, how many, when (minutes from now), the court or room, then how far along: confirmed, in (checked in), part (some of a group in), play (started)
create function pg_temp.bk(p_who text, p_listing text, p_people int, p_mins int, p_unit text, p_part text, p_state text) returns text language plpgsql security definer as $$
declare r jsonb; v_svc uuid; v_staff uuid; v_key text := 'today-' || (select tag from ctx) || '-' || p_who; a record;
begin
  select s.menu_item_id into v_svc from svc_services s join menu_items m on m.id = s.menu_item_id where s.organization_id = (select org from ctx) and m.name = p_listing;
  if p_unit is null then
    select ps.staff_id into v_staff from svc_provider_services ps join svc_providers pr on pr.staff_id = ps.staff_id and pr.is_bookable where ps.menu_item_id = v_svc
     order by ps.staff_id limit 1;
  end if;
  r := public.svc_book(jsonb_strip_nulls(jsonb_build_object('idempotency_key', v_key, 'customer_name', 'Test ' || p_who, 'customer_phone', '9876500044', 'service_id', v_svc, 'staff_id', v_staff,
    'unit', p_unit, 'part', p_part, 'starts_at', (select base from ctx) + make_interval(mins => p_mins),
    'service_address', case when p_listing in ('Plumber visit', 'AC service') then 'Flat 4, Test Road, Pune' end,
    'party', jsonb_build_object('guests', (select jsonb_agg(jsonb_build_object('g', 'any', 'a', '18_59')) from generate_series(1, p_people))))));
  if coalesce((r->>'replayed')::boolean, false) then return p_who || ': already there'; end if;
  select id, status, version into a from svc_appointments where id = (r->>'id')::uuid;
  if a.status = 'deposit_pending' then
    perform public.svc_appointment_act(jsonb_build_object('id', a.id, 'action', 'pay_deposit', 'method', 'upi', 'expected_version', a.version, 'idempotency_key', v_key || '-pay'));
    select id, status, version into a from svc_appointments where id = a.id;
  end if;
  if p_state = 'part' then
    perform public.svc_appointment_admit(jsonb_build_object('id', a.id, 'admitted', greatest(p_people - 1, 1), 'expected_version', a.version, 'idempotency_key', v_key || '-in'));
  elsif p_state in ('in', 'play') then
    perform public.svc_appointment_act(jsonb_build_object('id', a.id, 'action', 'check_in', 'expected_version', a.version, 'idempotency_key', v_key || '-in'));
    if p_state = 'play' then
      perform public.svc_appointment_act(jsonb_build_object('id', a.id, 'action', 'start', 'expected_version', a.version + 1, 'idempotency_key', v_key || '-start'));
    end if;
  end if;
  return p_who || ': ' || (r->>'display_no');
exception when others then return p_who || ': REFUSED ' || sqlerrm;
end $$;

-- Events
select pg_temp.bk('Asha', 'Music night', 4, 60, null, null, 'confirmed');
select pg_temp.bk('Ravi', 'Music night', 1, 60, null, null, 'confirmed');
select pg_temp.bk('Meena', 'Music night', 3, 60, null, null, 'part');
-- Activities
select pg_temp.bk('Neha', 'Pottery class', 2, 210, null, null, 'confirmed');
select pg_temp.bk('Kiran', 'Pottery class', 1, 210, null, null, 'in');
-- Play: someone playing, someone waiting, someone next, a free court
select pg_temp.bk('Riya', 'Badminton Court 1', 2, 0, 'Court A', null, 'play');
select pg_temp.bk('Sam', 'Badminton Court 1', 2, 200, 'Court A', null, 'confirmed');
select pg_temp.bk('Arjun', 'Badminton Court 1', 4, 0, 'Court B', null, 'in');
select pg_temp.bk('Tara', 'pickleball', 2, 45, 'Court 1', null, 'confirmed');
-- Service: waiting, checked in, in progress, at the customer's place
select pg_temp.bk('Priya', 'Manicure', 1, 30, null, null, 'confirmed');
select pg_temp.bk('Dev', 'Beard trim', 1, 15, null, null, 'in');
select pg_temp.bk('Isha', 'Hair colour', 1, 0, null, null, 'play');
select pg_temp.bk('Omar', 'Plumber visit', 1, 45, null, null, 'confirmed');
-- Stay: one arriving, one here (a booking lasts 12 hours at most until the date range fix)
select pg_temp.bk('Rohit', 'Garden room', 2, 30, 'Room 1', null, 'confirmed');
select pg_temp.bk('Anita', 'Garden room', 2, 0, 'Room 2', null, 'in');

reset role;
delete from svc_location_hours;
insert into svc_location_hours select * from keep_loc;
update svc_working_hours w set start_time = k.start_time, end_time = k.end_time from keep_work k where w.id = k.id;
update svc_services s set listing = k.listing, min_notice_min = k.min_notice_min from keep_sv k where s.menu_item_id = k.menu_item_id;
commit;

select coalesce(s.listing_category, case when s.fulfilment = 'event' then 'events' else 'service' end) tab, m.name, a.customer_name, a.status, a.display_no, a.unit, to_char(a.starts_at at time zone 'Asia/Kolkata', 'HH24:MI') at_time
  from svc_appointments a join svc_appointment_lines l on l.appointment_id = a.id and l.kind = 'service' join svc_services s on s.menu_item_id = l.menu_item_id join menu_items m on m.id = l.menu_item_id
 where a.customer_name in ('Test Asha','Test Ravi','Test Meena','Test Neha','Test Kiran','Test Riya','Test Sam','Test Arjun','Test Tara','Test Priya','Test Dev','Test Isha','Test Omar','Test Rohit','Test Anita')
   and (a.starts_at at time zone 'Asia/Kolkata')::date = (now() at time zone 'Asia/Kolkata')::date
 order by 1, a.starts_at;
