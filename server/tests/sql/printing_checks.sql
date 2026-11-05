-- Checks for 0660 (printing). Local dev DB only; one transaction, rolled back.
--   docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 < server/tests/sql/printing_checks.sql
\set org 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'
begin;
set local search_path = public, extensions;
create function pg_temp.ok(n int, cond boolean, what text) returns text language plpgsql as $$
begin if not coalesce(cond, false) then raise exception 'FAIL %: %', n, what; end if; return 'PASS ' || n || ' ' || what; end $$;
grant execute on function pg_temp.ok(int, boolean, text) to authenticated;
create function pg_temp.who(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true); $$;
grant execute on function pg_temp.who(uuid) to authenticated;

-- a kitchen printer for the bar station, a default kitchen printer for everything else, a bill printer; a kitchen-role user
insert into pos_printers (id, organization_id, name, printer_type, connection, address, paper_mm, copies, auto_cut, active, is_default)
values ('7b0b7ead-0000-4000-8000-0000000000d1', :'org', 'Bar printer', 'kot', 'lan', '127.0.0.1:9101', 80, 1, true, true, false),
       ('7b0b7ead-0000-4000-8000-0000000000d2', :'org', 'Kitchen printer', 'kot', 'lan', '127.0.0.1:9100', 80, 1, true, true, true),
       ('7b0b7ead-0000-4000-8000-0000000000d3', :'org', 'Bill printer', 'receipt', 'lan', '127.0.0.1:9102', 80, 1, true, true, true);
update menu_items set station = 'zzbar' where organization_id = :'org' and name = 'Cappuccino';
create temp table _st as select 'zzbar'::text bar_station, (select station from menu_items where organization_id = :'org' and name = 'Peri Peri Fries') food_station;
insert into pos_kitchen_stations (organization_id, key, name, active, printer_id)
select :'org', (select bar_station from _st), 'Bar', true, '7b0b7ead-0000-4000-8000-0000000000d1'
on conflict do nothing;
update pos_kitchen_stations set printer_id = '7b0b7ead-0000-4000-8000-0000000000d1'
 where organization_id = :'org' and key = (select bar_station from _st);
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values ('7b0b7ead-0000-4000-8000-0000000000c2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-kitchen@example.test', now(), now());
insert into org_users (organization_id, user_id, role_id, email, full_name, status)
values (:'org', '7b0b7ead-0000-4000-8000-0000000000c2', (select id from roles where slug = 'kitchen'), 'zz-kitchen@example.test', 'ZZ kitchen', 'active');
create temp table _ctx as select (select user_id from org_users where organization_id = :'org' and role_id = (select id from roles where slug = 'org_owner') limit 1) owner,
  (select id from dining_tables where organization_id = :'org' and label = 'T2') t2;
grant select on _ctx, _st to authenticated;

-- an order with a drink and a dish, sent to the kitchen
select pg_temp.who((select owner from _ctx));
create temp table _o as select (pos_place_order(jsonb_build_object('organization_id', :'org', 'service_type', 'dine_in', 'table_id', (select t2 from _ctx),
  'idempotency_key', 'chk-0660-' || gen_random_uuid(), 'lines', jsonb_build_array(
    jsonb_build_object('menu_item_id', (select id from menu_items where organization_id = :'org' and name = 'Cappuccino'), 'qty', 2, 'notes', 'less sugar'),
    jsonb_build_object('menu_item_id', (select id from menu_items where organization_id = :'org' and name = 'Peri Peri Fries'), 'qty', 1)))) ->> 'id')::uuid id;
grant select on _o to authenticated;

-- 1 kitchen staff (not a manager) can read where to print
select pg_temp.who('7b0b7ead-0000-4000-8000-0000000000c2');
set local role authenticated;
select pg_temp.ok(1, jsonb_array_length(pos_print_targets('{}')->'printers') = 3, 'kitchen staff see the printers to print on');
-- 2-3 the ticket is split by printer: the drink to the bar printer, the fries to the default kitchen printer
select pg_temp.ok(2, (select count(*) from jsonb_array_elements(pos_kot_print(jsonb_build_object('order_id', (select id from _o)))->'groups')) = 2, 'one ticket, one group per printer');
select pg_temp.ok(2, exists (select 1 from jsonb_array_elements(pos_kot_print(jsonb_build_object('order_id', (select id from _o)))->'groups') g
   where g->>'printer_id' = '7b0b7ead-0000-4000-8000-0000000000d2' and g->'items'->0->>'name' = 'Peri Peri Fries'), 'the fries go to the default kitchen printer');
select pg_temp.ok(3, exists (select 1 from jsonb_array_elements(pos_kot_print(jsonb_build_object('order_id', (select id from _o)))->'groups') g
   where g->>'printer_id' = '7b0b7ead-0000-4000-8000-0000000000d1' and g->'items'->0->>'name' = 'Cappuccino' and g->'items'->0->>'notes' = 'less sugar'),
  'the drink goes to the bar printer with its note');
-- 4 the print is recorded on the order
select pos_print_log(jsonb_build_object('kind', 'kot', 'outcome', 'printed', 'order_id', (select id from _o), 'printer_id', '7b0b7ead-0000-4000-8000-0000000000d1'));
reset role;
select pg_temp.ok(4, exists (select 1 from order_events where order_id = (select id from _o) and kind = 'kot_printed' and message like '%Bar printer%'), 'the print is on the order''s record');
-- 5 a stranger outside the business learns nothing
set local role anon;
do $$ begin perform pos_print_targets('{}'); raise exception 'FAIL 5'; exception when insufficient_privilege then null; end $$;
select 'PASS 5 anon cannot read printers';
reset role;
rollback;
