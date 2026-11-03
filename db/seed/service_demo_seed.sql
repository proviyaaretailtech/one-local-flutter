-- Demo Services: a test SERVICE business for the Service POS, covering every kind of service. LOCAL stack only, never hosted.
-- Run:  docker exec -i supabase_db_onelocal-dev psql -U supabase_admin -v ON_ERROR_STOP=1 < db/seed/service_demo_seed.sql
--       (supabase_admin: part 7 moves finished test visits into the past, which needs the database admin)
-- (Was glow_salon_test_seed.sql, a salon only; renamed 2 Nov 2026 when the founder asked for every kind of service at once.)
-- Safe to run again: each part is skipped when it is already there.
--
-- Test login (local web app, http://localhost:8132): Sign in -> "Use password"
--   email     owner.glowsalon@test.local
--   password  GlowSalon@2026
--   or, same box: mobile 9004222219, password 123456 (the user's chosen test number; a second owner login, part 5)
-- (test passwords for this local seed only; they are not used anywhere else)
--
-- Made the way the app makes it: partner_app_save_profile (partner_type 'service') -> approval (check_set x4 + decide, as a
-- platform admin) -> partner setup -> staff_save -> svc_service_save / svc_provider_save / svc_schedule_save as the owner.
begin;

-- 1. The owner's login (email + password).
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'owner.glowsalon@test.local',
       extensions.crypt('GlowSalon@2026', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Priya Kulkarni"}',
       now(), now(), '', '', '', '', '', '', '', ''
where not exists (select 1 from auth.users where email = 'owner.glowsalon@test.local');

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email', jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now(), now()
from auth.users u
where u.email = 'owner.glowsalon@test.local' and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');

-- 2. The partner application (service), then approval. Documents and PAN are skipped: this is a local test business.
do $$
declare v_uid uuid := (select id from auth.users where email = 'owner.glowsalon@test.local'); v_app uuid; v_admin uuid; k text;
begin
  if exists (select 1 from public.ol_partner_applications where applicant_user_id = v_uid and status = 'approved') then return; end if;
  perform public.partner_app_save_profile(v_uid, jsonb_build_object(
    'partner_type', 'service', 'business_name', 'Demo Services', 'owner_name', 'Priya Kulkarni', 'phone', '9000000101',
    'email', 'owner.glowsalon@test.local', 'selling_mode', 'physical', 'category', 'Repairs', 'subcategories', jsonb_build_array('AC repair')));
  perform public.partner_app_choose_plan(v_uid, 'pos_only');
  select id into v_app from public.ol_partner_applications where applicant_user_id = v_uid and status = 'draft';
  update public.ol_partner_applications
     set address = 'Shop 4, Lane 3, Kothrud, Pune, Maharashtra', address_line = 'Shop 4, Lane 3', locality = 'Kothrud', city_name = 'Pune',
         state = 'Maharashtra', pin_code = '411038', address_confirmed_at = now(), business_structure = 'Sole proprietorship', gst_registered = false,
         status = 'submitted', submitted_at = now()
   where id = v_app;
  insert into public.ol_partner_application_checks (application_id, kind)
  select v_app, x from unnest(array['individual_identity', 'business_identity', 'business_address', 'bank_ownership']) x on conflict do nothing;
  select user_id into v_admin from public.platform_admins where status = 'Active' order by created_at limit 1;
  foreach k in array array['individual_identity', 'business_identity', 'business_address', 'bank_ownership'] loop
    perform public.master_partner_application_check_set(v_app, k, 'verified', 'Local test business', v_admin);
  end loop;
  perform public.master_partner_application_decide(v_app, 'approve', 'Local test business (Demo Services seed)', v_admin);
end $$;

-- 3. Partner setup: plan (none published locally), one POS device, then complete, so the app opens the dashboard, not the setup steps.
do $$
declare v_uid uuid := (select id from auth.users where email = 'owner.glowsalon@test.local');
begin
  if coalesce((public.partner_setup_get(v_uid)->'progress'->>'completed')::boolean, false) then return; end if;
  perform public.partner_setup_confirm_plan(v_uid, null);
  perform public.partner_setup_register_pos(v_uid, jsonb_build_object('device_name', 'Front desk', 'peripherals', jsonb_build_array()));
  perform public.partner_setup_complete(v_uid);
end $$;

-- 4. Staff, services and hours, saved as the owner through the Service POS functions.
do $$
declare v_uid uuid := (select id from auth.users where email = 'owner.glowsalon@test.local');
  v_org uuid; v_loc uuid; v_neha uuid; v_ravi uuid; v_sana uuid; v_wash uuid; s record; v_ids jsonb := '{}';
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_org := public.current_org_id();
  if exists (select 1 from public.svc_services where organization_id = v_org) then return; end if;
  select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1;

  v_neha := (public.staff_save('{"name":"Neha Patil","mobile":"9000000102","role":"Senior stylist","salary_type":"monthly","pay":"25000"}')->>'id')::uuid;
  v_ravi := (public.staff_save('{"name":"Ravi Shinde","mobile":"9000000103","role":"Stylist","salary_type":"monthly","pay":"18000"}')->>'id')::uuid;
  v_sana := (public.staff_save('{"name":"Sana Shaikh","mobile":"9000000104","role":"Beautician","salary_type":"monthly","pay":"20000"}')->>'id')::uuid;
  perform public.svc_provider_save(jsonb_build_object('idempotency_key', 'glow-seed-prov-1', 'staff_id', v_neha, 'location_id', v_loc, 'title', 'Senior stylist', 'skills', 'Cuts, colour'));
  perform public.svc_provider_save(jsonb_build_object('idempotency_key', 'glow-seed-prov-2', 'staff_id', v_ravi, 'location_id', v_loc, 'title', 'Stylist', 'skills', 'Cuts, beard'));
  perform public.svc_provider_save(jsonb_build_object('idempotency_key', 'glow-seed-prov-3', 'staff_id', v_sana, 'location_id', v_loc, 'title', 'Beautician', 'skills', 'Facials, nails'));

  -- the add-on first, so services can offer it
  v_wash := (public.svc_service_save(jsonb_build_object('idempotency_key', 'glow-seed-svc-0', 'kind', 'addon', 'name', 'Hair wash', 'price', 150,
              'duration_min', 15, 'category', 'Hair', 'staff_ids', jsonb_build_array(v_neha, v_ravi)))->>'id')::uuid;
  for s in select * from (values
      (1, 'Haircut (women)', 600, 45, 10, 'Hair', jsonb_build_array(v_neha, v_ravi), true),
      (2, 'Haircut (men)', 300, 30, 5, 'Hair', jsonb_build_array(v_neha, v_ravi), true),
      (3, 'Beard trim', 150, 15, 5, 'Hair', jsonb_build_array(v_ravi), false),
      (4, 'Hair colour', 1800, 90, 15, 'Hair', jsonb_build_array(v_neha), true),
      (5, 'Facial', 1200, 60, 10, 'Skin', jsonb_build_array(v_sana), false),
      (6, 'Manicure', 500, 40, 5, 'Nails', jsonb_build_array(v_sana), false)) t(n, name, price, mins, buffer, cat, staff, wash) loop
    perform public.svc_service_save(jsonb_build_object('idempotency_key', 'glow-seed-svc-' || s.n, 'name', s.name, 'price', s.price, 'duration_min', s.mins,
      'buffer_min', s.buffer, 'category', s.cat, 'staff_ids', s.staff,
      'addon_ids', case when s.wash then jsonb_build_array(v_wash) else '[]'::jsonb end,
      'checklist', jsonb_build_array('Confirm the look with the customer', 'Clean the station')));
  end loop;

  -- open every day 10:00-20:00 with a 14:00-15:00 break (weekday 1 = Monday); staff hours inside that, Sana off on Monday
  perform public.svc_schedule_save(jsonb_build_object('idempotency_key', 'glow-seed-hours-2', 'location_id', v_loc, 'slot_minutes', 15,
    'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'open', '10:00', 'close', '20:00', 'break_start', '14:00', 'break_end', '15:00')) from generate_series(1, 7) d),
    'providers', jsonb_build_array(
      jsonb_build_object('staff_id', v_neha, 'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '10:00', 'end', '18:00')) from generate_series(1, 7) d)),
      jsonb_build_object('staff_id', v_ravi, 'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '12:00', 'end', '20:00')) from generate_series(1, 7) d)),
      jsonb_build_object('staff_id', v_sana, 'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '10:00', 'end', '19:00')) from generate_series(2, 7) d)))));
end $$;

-- 5. A second owner login by mobile number + password (user's choice, 2 Nov 2026): 9004222219 / 123456, through "Use password".
--    The number already had a bare local sign-up (no business) on this PC; it is reused, else made.
insert into auth.users (instance_id, id, aud, role, phone, encrypted_password, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '919004222219',
       extensions.crypt('123456', extensions.gen_salt('bf')), now(), '{"provider":"phone","providers":["phone"]}', '{}', now(), now(), '', '', '', '', '', '', '', ''
where not exists (select 1 from auth.users where phone = '919004222219');
update auth.users set encrypted_password = extensions.crypt('123456', extensions.gen_salt('bf')), phone_confirmed_at = coalesce(phone_confirmed_at, now()), updated_at = now()
 where phone = '919004222219';
insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'phone', jsonb_build_object('sub', u.id::text, 'phone', u.phone, 'phone_verified', true), now(), now(), now()
from auth.users u where u.phone = '919004222219' and not exists (select 1 from auth.identities i where i.user_id = u.id);
insert into public.org_users (organization_id, user_id, role_id, email, full_name, status)
select o.id, u.id, (select id from public.roles where slug = 'org_owner'), '', 'Demo Services owner (phone)', 'active'
from auth.users u, public.org_users ow join public.organizations o on o.id = ow.organization_id
where u.phone = '919004222219' and ow.user_id = (select id from auth.users where email = 'owner.glowsalon@test.local')
on conflict (organization_id, user_id) do nothing;

-- 2b. First made as "Glow Salon" (a salon only); it is a general test business for every kind of service now (2 Nov 2026).
update public.organizations o set name = 'Demo Services'
 where o.name = 'Glow Salon' and exists (select 1 from public.org_users ou join auth.users u on u.id = ou.user_id where ou.organization_id = o.id and u.email = 'owner.glowsalon@test.local');
update public.locations l set name = 'Demo Services - Main'
 where l.name = 'Glow Salon - Main' and l.organization_id = (select organization_id from public.org_users ou join auth.users u on u.id = ou.user_id where u.email = 'owner.glowsalon@test.local' limit 1);
-- (an approved application cannot be edited, so one made before the rename keeps "Glow Salon"; a fresh run of this seed applies as Demo Services)

-- 6. Every kind of service (2 Nov 2026): at the customer's place (AC, plumbing, cleaning), at the shop (consultation, pet grooming,
--    the beauty services above), a group workshop and an online consultation; two more staff; a ₹200 advance on bookings.
do $$
declare v_uid uuid := (select id from auth.users where email = 'owner.glowsalon@test.local'); v_org uuid; v_loc uuid; v_arjun uuid; v_meera uuid; s record;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_org := public.current_org_id();
  if exists (select 1 from public.svc_services sv join public.menu_items m on m.id = sv.menu_item_id where sv.organization_id = v_org and m.name = 'AC service') then return; end if;
  select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1;
  v_arjun := (public.staff_save('{"name":"Arjun Kumar","mobile":"9000000105","role":"Technician","salary_type":"monthly","pay":"22000"}')->>'id')::uuid;
  v_meera := (public.staff_save('{"name":"Meera Iyer","mobile":"9000000106","role":"Consultant","salary_type":"monthly","pay":"30000"}')->>'id')::uuid;
  perform public.svc_provider_save(jsonb_build_object('idempotency_key', 'demo-seed-prov-4', 'staff_id', v_arjun, 'location_id', v_loc, 'title', 'Technician',
    'skills', 'AC, plumbing', 'service_area', 'Kothrud, Karve Nagar, Warje, Erandwane'));
  perform public.svc_provider_save(jsonb_build_object('idempotency_key', 'demo-seed-prov-5', 'staff_id', v_meera, 'location_id', v_loc, 'title', 'Consultant',
    'skills', 'Consultations, cleaning, yoga, pet grooming'));
  for s in select * from (values
      (1, 'AC service', 800, 60, 30, 'Repairs', 'on_location', jsonb_build_array(v_arjun), jsonb_build_array('Check cooling and gas', 'Clean filters and coils', 'Test outlet temperature')),
      (2, 'Plumber visit', 300, 45, 30, 'Home skilled work', 'on_location', jsonb_build_array(v_arjun), jsonb_build_array('Find the leak', 'Fix and test')),
      (3, 'Home deep cleaning', 2500, 180, 30, 'Cleaning', 'on_location', jsonb_build_array(v_meera), jsonb_build_array('Kitchen', 'Bathrooms', 'Floors')),
      (4, 'Consultation', 500, 30, 10, 'Professional', 'appointment', jsonb_build_array(v_meera), jsonb_build_array('Note what the customer needs')),
      (5, 'Pet grooming', 900, 60, 15, 'Pet care', 'appointment', jsonb_build_array(v_meera), jsonb_build_array('Bath', 'Trim nails')),
      (6, 'Yoga workshop', 600, 90, 15, 'Education and fitness', 'event', jsonb_build_array(v_meera), jsonb_build_array('Mark attendance')),
      (7, 'Video consultation', 250, 15, 5, 'Health', 'on_demand', jsonb_build_array(v_meera), jsonb_build_array('Share notes with the customer'))
    ) t(n, name, price, mins, buffer, cat, ful, staff, checklist) loop
    perform public.svc_service_save(jsonb_build_object('idempotency_key', 'demo-seed-svc-' || s.n, 'name', s.name, 'price', s.price, 'duration_min', s.mins,
      'buffer_min', s.buffer, 'category', s.cat, 'fulfilment', s.ful, 'staff_ids', s.staff, 'checklist', s.checklist, 'capacity', case when s.ful = 'event' then 12 else 1 end));
  end loop;
  -- Arjun Mon-Sat, Meera every day, 10:00-20:00 (the location's 14:00-15:00 break still applies)
  perform public.svc_schedule_save(jsonb_build_object('idempotency_key', 'demo-seed-hours-3', 'location_id', v_loc, 'providers', jsonb_build_array(
    jsonb_build_object('staff_id', v_arjun, 'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '10:00', 'end', '20:00')) from generate_series(1, 6) d)),
    jsonb_build_object('staff_id', v_meera, 'hours', (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '10:00', 'end', '20:00')) from generate_series(1, 7) d)))));
  -- an advance of up to ₹200 on every booking (the app has no settings screen for it yet)
  insert into public.svc_settings (organization_id, deposit_amount) values (v_org, 200)
  on conflict (organization_id) do update set deposit_amount = 200, updated_at = now();
end $$;

-- 7. Customers and bookings in every state, through the app's booking functions (2 Nov 2026). Dates are relative to the day the seed runs;
--    run it during working hours (10:00-17:00), because past visits are first done as real visits in today's free times.
--    7a. Past visits (paid, no-show, cancelled): booked today, done, then moved back to their day. Moving them is the one step that is not the
--        app's: payments can never be edited, so it runs with triggers off (session_replication_role = replica, database admin only).
--    7b. Today: one visit in each state. 7c. The next days: upcoming bookings, one waiting for its advance, one cancelled.
create function pg_temp.d_svc(p_name text) returns uuid language sql as $f$
  select sv.menu_item_id from public.svc_services sv join public.menu_items m on m.id = sv.menu_item_id
   where sv.organization_id = public.current_org_id() and m.name = p_name $f$;
create function pg_temp.d_staff(p_name text) returns uuid language sql as $f$
  select id from public.pos_staff where organization_id = public.current_org_id() and full_name = p_name and deleted_at is null $f$;
create function pg_temp.d_at(p_day date, p_hm text) returns timestamptz language sql as $f$ select (p_day + p_hm::time) at time zone 'Asia/Kolkata' $f$;
create function pg_temp.d_key(p_what text) returns text language sql as $f$ select 'demo-' || md5(p_what || clock_timestamp()::text || random()::text) $f$;
-- the first free start on p_day for this provider and service
create function pg_temp.d_slot(p_svc text, p_staff text, p_day date) returns timestamptz language sql as $f$
  select (sl->>'starts_at')::timestamptz
    from jsonb_array_elements(public.svc_slots(jsonb_build_object('date', p_day::text, 'service_id', pg_temp.d_svc(p_svc), 'staff_id', pg_temp.d_staff(p_staff)))->'providers') pr,
         jsonb_array_elements(pr->'slots') sl
   where (pr->>'staff_id')::uuid = pg_temp.d_staff(p_staff) order by 1 limit 1 $f$;
create function pg_temp.d_book(p_cust text, p_phone text, p_svc text, p_staff text, p_at timestamptz, p_deposit text, p_addr text) returns jsonb language plpgsql as $f$
declare p jsonb := jsonb_build_object('idempotency_key', pg_temp.d_key(p_cust || p_svc), 'customer_name', p_cust, 'customer_phone', p_phone,
  'service_id', pg_temp.d_svc(p_svc), 'staff_id', pg_temp.d_staff(p_staff), 'starts_at', p_at, 'addon_ids', '[]'::jsonb);
begin
  if p_addr is not null then p := p || jsonb_build_object('service_address', p_addr); end if;
  if p_deposit is not null then p := p || jsonb_build_object('deposit', jsonb_build_object('method', p_deposit)); end if;
  return public.svc_book(p);
end $f$;
create function pg_temp.d_act(p_a jsonb, p_action text, p_extra jsonb) returns jsonb language plpgsql as $f$
begin
  return public.svc_appointment_act(jsonb_build_object('id', p_a->>'id', 'action', p_action, 'expected_version', (p_a->>'version')::int,
    'idempotency_key', pg_temp.d_key(p_action)) || coalesce(p_extra, '{}'::jsonb));
end $f$;
-- takes a booked visit as far as p_upto: checked_in, in_service or paid (checklist ticked, billed, paid by p_method)
create function pg_temp.d_run(p_a jsonb, p_upto text, p_method text) returns jsonb language plpgsql as $f$
declare a jsonb := p_a; v_code text := p_a->>'arrival_code'; v_due numeric;
begin
  a := pg_temp.d_act(a, 'check_in', case when v_code is null then null else jsonb_build_object('verification', 'otp', 'code', v_code) end);
  if p_upto = 'checked_in' then return a; end if;
  a := pg_temp.d_act(a, 'start', null);
  if p_upto = 'in_service' then return a; end if;
  a := public.svc_job_update(jsonb_build_object('id', a->>'id', 'expected_version', (a->>'version')::int, 'idempotency_key', pg_temp.d_key('job'),
    'done', to_jsonb(coalesce(public.svc_checklist((a->>'id')::uuid), '{}'::text[]))));
  v_due := (a->'bill'->>'due')::numeric;
  return public.svc_bill(jsonb_build_object('id', a->>'id', 'expected_version', (a->>'version')::int, 'idempotency_key', pg_temp.d_key('bill'),
    'method', case when v_due > 0 then p_method end,
    'tendered', case when v_due > 0 and p_method = 'cash' then ceil(v_due / 100) * 100 + 100 end));   -- cash: a round note, so there is change
end $f$;
-- moves one test visit (and its order, payments, refunds, events and ledger lines) to p_to, keeping their spacing
create function pg_temp.d_move(p_id uuid, p_to timestamptz) returns void language plpgsql as $f$
declare a public.svc_appointments; d interval;
begin
  select * into a from public.svc_appointments where id = p_id;
  d := p_to - a.starts_at;
  perform set_config('session_replication_role', 'replica', true);
  update public.svc_appointments set starts_at = starts_at + d, ends_at = ends_at + d, block_until = block_until + d, created_at = created_at + d,
    updated_at = updated_at + d, checked_in_at = checked_in_at + d, started_at = started_at + d, completed_at = completed_at + d, cancelled_at = cancelled_at + d
   where id = p_id;
  update public.orders set created_at = created_at + d, updated_at = updated_at + d, paid_at = paid_at + d where id = a.order_id;
  update public.payments set created_at = created_at + d where order_id = a.order_id;
  update public.pos_refunds set created_at = created_at + d where order_id = a.order_id;
  update public.order_events set created_at = created_at + d where order_id = a.order_id;
  update public.payment_ledger set created_at = created_at + d where order_id = a.order_id;
  perform set_config('session_replication_role', 'origin', true);
end $f$;

do $$
declare v_day date := (now() at time zone 'Asia/Kolkata')::date; r record; a jsonb; v_at timestamptz;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select id from auth.users where email = 'owner.glowsalon@test.local'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.svc_appointments where organization_id = public.current_org_id() and customer_phone = '9000000301') then return; end if;

  -- 7a. the last two weeks
  for r in select * from (values
      (1, '11:00', 'Neha Patil', 'Haircut (women)', 'Riya Sharma', '9000000301', 'paid', 'upi', null),
      (1, '12:30', 'Arjun Kumar', 'AC service', 'Amit Shah', '9000000302', 'paid', 'cash', 'C-201, Silver Oaks, Warje, Pune 411058'),
      (2, '10:30', 'Meera Iyer', 'Consultation', 'Priya Menon', '9000000303', 'paid', 'card', null),
      (2, '16:00', 'Ravi Shinde', 'Haircut (men)', 'Vikram Patel', '9000000304', 'paid', 'cash', null),
      (2, '17:00', 'Meera Iyer', 'Video consultation', 'Arun Das', '9000000314', 'paid', 'upi', null),
      (3, '15:30', 'Ravi Shinde', 'Haircut (men)', 'Sameer Ali', '9000000311', 'no_show', null, null),
      (4, '15:00', 'Arjun Kumar', 'Plumber visit', 'Rahul Joshi', '9000000306', 'paid', 'upi', 'Flat 4, Lane 6, Erandwane, Pune 411004'),
      (5, '10:00', 'Meera Iyer', 'Home deep cleaning', 'Kiran Rao', '9000000307', 'paid', 'upi', 'Row house 3, Paud Road, Pune 411038'),
      (5, '16:00', 'Neha Patil', 'Haircut (women)', 'Karan Singh', '9000000312', 'cancelled', null, null),
      (6, '10:00', 'Meera Iyer', 'Yoga workshop', 'Pooja Nair', '9000000313', 'paid', 'cash', null),
      (6, '17:00', 'Ravi Shinde', 'Beard trim', 'Vikram Patel', '9000000304', 'paid', 'cash', null),
      (7, '12:00', 'Neha Patil', 'Hair colour', 'Sneha Kulkarni', '9000000308', 'paid', 'card', null),
      (8, '11:00', 'Meera Iyer', 'Pet grooming', 'Rohan Mehta', '9000000309', 'paid', 'upi', null),
      (9, '16:30', 'Arjun Kumar', 'AC service', 'Neha Gupta', '9000000310', 'paid', 'upi', 'B-7, Green Park, Kothrud, Pune 411038'),
      (10, '10:30', 'Neha Patil', 'Haircut (women)', 'Riya Sharma', '9000000301', 'paid', 'upi', null),
      (12, '15:30', 'Meera Iyer', 'Consultation', 'Ishita Bose', '9000000318', 'paid', 'cash', null)
    ) t(days_ago, hm, staff, svc, cust, phone, outcome, method, addr) loop
    v_at := pg_temp.d_slot(r.svc, r.staff, v_day);
    if v_at is null then raise exception 'no free time today for % to make the past visits: run the seed between 10:00 and 17:00', r.staff; end if;
    a := pg_temp.d_book(r.cust, r.phone, r.svc, r.staff, v_at, 'upi', r.addr);
    if r.outcome = 'paid' then
      a := pg_temp.d_run(a, 'paid', r.method);
    elsif r.outcome = 'cancelled' then
      a := pg_temp.d_act(a, 'cancel', jsonb_build_object('reason', 'Customer changed plans', 'refund', true));
    end if;
    perform pg_temp.d_move((a->>'id')::uuid, pg_temp.d_at(v_day - r.days_ago, r.hm));
    if r.outcome = 'no_show' then
      perform pg_temp.d_act(public.svc_appointment_view(jsonb_build_object('id', a->>'id')), 'no_show', null);
    end if;
  end loop;

  -- 7b. today, one visit in each state
  for r in select * from (values
      ('Neha Patil', 'Haircut (women)', 'Meghna Shah', '9000000315', 'paid', 'upi', null),
      ('Arjun Kumar', 'AC service', 'Deepak Verma', '9000000316', 'in_service', 'upi', 'Flat 12, Sunrise Society, Karve Nagar, Pune 411052'),
      ('Ravi Shinde', 'Haircut (men)', 'Farhan Khan', '9000000317', 'checked_in', 'upi', null),
      ('Meera Iyer', 'Consultation', 'Ishita Bose', '9000000318', 'confirmed', 'upi', null),
      ('Ravi Shinde', 'Beard trim', 'Nikhil Jain', '9000000319', 'deposit_pending', null, null)
    ) t(staff, svc, cust, phone, upto, deposit, addr) loop
    v_at := pg_temp.d_slot(r.svc, r.staff, v_day);
    if v_at is null then raise notice 'no free time today for %: skipped', r.cust; continue; end if;
    a := pg_temp.d_book(r.cust, r.phone, r.svc, r.staff, v_at, r.deposit, r.addr);
    if r.upto in ('checked_in', 'in_service', 'paid') then a := pg_temp.d_run(a, r.upto, 'cash'); end if;
  end loop;

  -- 7c. the coming days (a booking that does not fit that day's hours is skipped, so the seed works on any weekday)
  for r in select * from (values
      (1, '10:30', 'Neha Patil', 'Hair colour', 'Sneha Kulkarni', '9000000308', 'upi', null, false),
      (1, '11:00', 'Arjun Kumar', 'AC service', 'Neha Gupta', '9000000310', 'upi', 'B-7, Green Park, Kothrud, Pune 411038', false),
      (1, '12:00', 'Sana Shaikh', 'Facial', 'Ananya Desai', '9000000305', 'upi', null, false),
      (1, '16:00', 'Meera Iyer', 'Yoga workshop', 'Pooja Nair', '9000000313', 'upi', null, false),
      (2, '10:00', 'Meera Iyer', 'Home deep cleaning', 'Kiran Rao', '9000000307', 'upi', 'Row house 3, Paud Road, Pune 411038', false),
      (2, '12:30', 'Ravi Shinde', 'Haircut (men)', 'Vikram Patel', '9000000304', 'upi', null, false),
      (2, '15:30', 'Arjun Kumar', 'Plumber visit', 'Rahul Joshi', '9000000306', 'upi', 'Flat 4, Lane 6, Erandwane, Pune 411004', false),
      (2, '17:00', 'Neha Patil', 'Haircut (women)', 'Karan Singh', '9000000312', 'upi', null, true),
      (3, '11:00', 'Meera Iyer', 'Pet grooming', 'Rohan Mehta', '9000000309', 'upi', null, false),
      (3, '17:00', 'Meera Iyer', 'Video consultation', 'Arun Das', '9000000314', 'upi', null, false),
      (4, '10:30', 'Sana Shaikh', 'Manicure', 'Priya Menon', '9000000303', null, null, false),
      (5, '11:30', 'Neha Patil', 'Haircut (women)', 'Riya Sharma', '9000000301', 'upi', null, false),
      (5, '16:30', 'Arjun Kumar', 'AC service', 'Amit Shah', '9000000302', 'upi', 'C-201, Silver Oaks, Warje, Pune 411058', false),
      (6, '12:00', 'Ravi Shinde', 'Beard trim', 'Sameer Ali', '9000000311', 'upi', null, false)
    ) t(days_ahead, hm, staff, svc, cust, phone, deposit, addr, cancel) loop
    begin
      a := pg_temp.d_book(r.cust, r.phone, r.svc, r.staff, pg_temp.d_at(v_day + r.days_ahead, r.hm), r.deposit, r.addr);
      if r.cancel then perform pg_temp.d_act(a, 'cancel', jsonb_build_object('reason', 'Customer will be out of town')); end if;
    exception when others then
      raise notice 'skipped % on day +%: %', r.cust, r.days_ahead, sqlerrm;
    end;
  end loop;
end $$;

-- 9. Jobs (2 Nov 2026): a weekly cleaning job with a team of two (4 visits), an AC + plumbing job in two days, one not scheduled yet.
do $$
declare v_day date := (now() at time zone 'Asia/Kolkata')::date;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select id from auth.users where email = 'owner.glowsalon@test.local'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.svc_jobs where organization_id = public.current_org_id()) then return; end if;
  perform public.svc_job_save(jsonb_build_object('idempotency_key', 'demo-seed-job-1', 'customer_name', 'Lata Deshmukh', 'customer_phone', '9000000321',
    'address', 'Bungalow 5, Law College Road, Pune 411004', 'title', 'Weekly home cleaning', 'instructions', 'Keys with the watchman. Start with the kitchen.',
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', pg_temp.d_svc('Home deep cleaning'), 'qty', 4)), 'discount_pct', 10,
    'team', jsonb_build_array(pg_temp.d_staff('Meera Iyer'), pg_temp.d_staff('Sana Shaikh')),
    'date', v_day + 6, 'start', '10:00', 'end', '13:00', 'arrival_window_min', 30, 'repeat', 'weekly', 'repeat_count', 4));
  perform public.svc_job_save(jsonb_build_object('idempotency_key', 'demo-seed-job-2', 'customer_name', 'Suresh Patil', 'customer_phone', '9000000320',
    'address', 'Shop 9, Karve Road, Pune 411004', 'title', 'AC service and leak repair',
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', pg_temp.d_svc('AC service'), 'qty', 2), jsonb_build_object('menu_item_id', pg_temp.d_svc('Plumber visit'), 'qty', 1)),
    'team', jsonb_build_array(pg_temp.d_staff('Arjun Kumar')), 'date', v_day + 2, 'start', '10:00', 'end', '13:00', 'arrival_window_min', 60));
  perform public.svc_job_save(jsonb_build_object('idempotency_key', 'demo-seed-job-3', 'customer_name', 'Rahul Joshi', 'customer_phone', '9000000306',
    'title', 'Bathroom fittings (to be scheduled)', 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', pg_temp.d_svc('Plumber visit'), 'qty', 3)), 'schedule_later', true));
exception when others then
  raise notice 'jobs skipped: %', sqlerrm;
end $$;

-- 10. Online bookings (2 Nov 2026): until the customer app can book, a few test bookings are marked as booked online, so the Service POS
--     shows both kinds. Test data only: the source is set directly (database admin, triggers off), not through a booking function.
do $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select id from auth.users where email = 'owner.glowsalon@test.local'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.svc_appointments where organization_id = public.current_org_id() and source = 'app') then return; end if;
  perform set_config('session_replication_role', 'replica', true);
  update public.svc_appointments set source = 'app'
   where organization_id = public.current_org_id() and customer_phone in ('9000000305', '9000000309', '9000000313', '9000000314', '9000000318', '9000000310');
  perform set_config('session_replication_role', 'origin', true);
end $$;

-- 8. Bills made in the Bill tab (not from a booking): one paid, one still due (2 Nov 2026).
do $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (select id from auth.users where email = 'owner.glowsalon@test.local'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.order_events e join public.orders o on o.id = e.order_id where e.kind = 'svc_invoice' and o.organization_id = public.current_org_id()) then return; end if;
  perform public.svc_invoice_pay(jsonb_build_object('idempotency_key', 'demo-seed-inv-1-pay', 'method', 'upi',
    'order_id', public.svc_invoice_create(jsonb_build_object('idempotency_key', 'demo-seed-inv-1', 'customer_name', 'Suresh Patil', 'customer_phone', '9000000320',
      'address', 'Shop 9, Karve Road, Pune 411004', 'title', 'AC repair at the shop',
      'lines', jsonb_build_array(jsonb_build_object('menu_item_id', pg_temp.d_svc('AC service'), 'qty', 2), jsonb_build_object('menu_item_id', pg_temp.d_svc('Plumber visit'), 'qty', 1)),
      'discount', 100, 'message', 'Thank you for your business.'))->>'id'));
  perform public.svc_invoice_create(jsonb_build_object('idempotency_key', 'demo-seed-inv-2', 'customer_name', 'Lata Deshmukh', 'customer_phone', '9000000321',
    'title', 'Monthly cleaning', 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', pg_temp.d_svc('Home deep cleaning'), 'qty', 1)), 'discount_pct', 10));
end $$;

commit;
