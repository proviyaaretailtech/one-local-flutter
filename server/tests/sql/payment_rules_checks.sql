-- Checks for 0659 (payment and order rules for every caller). Local dev DB only; one transaction, rolled back.
--   docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 < server/tests/sql/payment_rules_checks.sql
-- Reproduces the founder's finding on the local Niks Cafe: a cashier (biller) calling the writers directly, paying a table order
-- whose bill was never generated, paying with "other", and paying an order of an outlet that is not theirs.
\set org 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'
begin;
set local search_path = public, extensions;
create function pg_temp.ok(n int, cond boolean, what text) returns text language plpgsql as $$
begin if not coalesce(cond, false) then raise exception 'FAIL %: %', n, what; end if; return 'PASS ' || n || ' ' || what; end $$;
grant execute on function pg_temp.ok(int, boolean, text) to authenticated;
create function pg_temp.refused(q text, pattern text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return sqlerrm ~ pattern or sqlstate = '42501'; end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;
create function pg_temp.who(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true); $$;
grant execute on function pg_temp.who(uuid) to authenticated;

-- a second outlet and a cashier who works only there
insert into locations (id, organization_id, name, code, kind, status, timezone, currency_code)
values ('7b0b7ead-0000-4000-8000-0000000000b2', :'org', 'Niks Cafe - Second (test)', 'ZZB2', 'restaurant', 'active', 'Asia/Kolkata', 'INR');
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values ('7b0b7ead-0000-4000-8000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-cashier-b2@example.test', now(), now());
insert into org_users (organization_id, user_id, role_id, email, full_name, status, location_id)
values (:'org', '7b0b7ead-0000-4000-8000-0000000000c1', (select id from roles where slug = 'biller'), 'zz-cashier-b2@example.test', 'ZZ cashier B2', 'active',
        '7b0b7ead-0000-4000-8000-0000000000b2');
create temp table _ctx as select (select user_id from org_users where organization_id = :'org' and role_id = (select id from roles where slug = 'org_owner') limit 1) owner,
  '7b0b7ead-0000-4000-8000-0000000000c1'::uuid cashier, (select id from dining_tables where organization_id = :'org' and label = 'T1') t1,
  (select id from menu_items where organization_id = :'org' and name = 'Cappuccino') dish;
grant select on _ctx to authenticated;

-- a table order at the main outlet, sent to the kitchen, bill NOT generated (made by the owner through the order writer)
select pg_temp.who((select owner from _ctx));
create temp table _o as select (pos_place_order(jsonb_build_object('organization_id', :'org', 'service_type', 'dine_in', 'table_id', (select t1 from _ctx),
  'idempotency_key', 'chk-0659-' || gen_random_uuid(), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1)))) ->> 'id')::uuid id;
grant select on _o to authenticated;

-- 1-2 the cashier cannot reach the writers directly
select pg_temp.who((select cashier from _ctx));
set local role authenticated;
select pg_temp.ok(1, pg_temp.refused(format($q$select pos_record_payment('{"order_id":"%s","amount":99,"method":"other","idempotency_key":"chk-direct-1"}')$q$, (select id from _o)), 'permission denied'),
  'cashier cannot call the payment writer directly');
select pg_temp.ok(2, pg_temp.refused(format($q$select pos_place_order('{"organization_id":"bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd","service_type":"pickup","lines":[{"menu_item_id":"%s","qty":1}]}')$q$, (select dish from _ctx)), 'permission denied'),
  'cashier cannot call the order writer directly');
-- 3 not their outlet: the checked pay path refuses too
select pg_temp.ok(3, pg_temp.refused(format($q$select pos_checkout_pay('{"order_id":"%s","method":"cash","tendered":200,"idempotency_key":"chk-pay-b2"}')$q$, (select id from _o)), 'outlet|not found|NOT_FOUND|FORBIDDEN'),
  'cashier of another outlet cannot take this payment');
reset role;

-- 4-6 the owner (any outlet): bill not generated -> refused; "other" -> refused; after Generate bill -> paid
select pg_temp.who((select owner from _ctx));
set local role authenticated;
select pg_temp.ok(4, pg_temp.refused(format($q$select pos_checkout_pay('{"order_id":"%s","method":"cash","tendered":200,"idempotency_key":"chk-pay-1"}')$q$, (select id from _o)), 'generate the bill first'),
  'a table order is not paid before its bill is generated');
select pg_temp.ok(5, pg_temp.refused(format($q$select pos_checkout_pay('{"order_id":"%s","method":"other","idempotency_key":"chk-pay-2"}')$q$, (select id from _o)), 'cash, card or UPI'),
  'method "other" is refused at the counter');
select pos_set_order_status(jsonb_build_object('order_id', (select id from _o), 'to', 'awaiting_payment'));
select pg_temp.ok(6, (rst_bill_pay(jsonb_build_object('order_id', (select id from _o), 'method', 'cash', 'tendered', 500, 'idempotency_key', 'chk-pay-3')) is not null), 'after Generate bill the payment is taken');
reset role;
select pg_temp.ok(6, (select status from orders where id = (select id from _o)) = 'paid', 'the order is paid');

-- 7 Master pause stops the restaurant payment path
select pg_temp.who((select owner from _ctx));
create temp table _o2 as select (pos_place_order(jsonb_build_object('organization_id', :'org', 'service_type', 'dine_in', 'table_id', (select t1 from _ctx),
  'idempotency_key', 'chk-0659b-' || gen_random_uuid(), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1)))) ->> 'id')::uuid id;
grant select on _o2 to authenticated;
select pos_set_order_status(jsonb_build_object('order_id', (select id from _o2), 'to', 'awaiting_payment'));
set local app.migration = '0659probe';
update master_runtime_state set payments_paused = true;
set local role authenticated;
select pg_temp.ok(7, pg_temp.refused(format($q$select rst_bill_pay('{"order_id":"%s","method":"cash","tendered":500,"idempotency_key":"chk-pay-4"}')$q$, (select id from _o2)), 'PAUSED'),
  'payments stop while Master has them paused');
reset role;

rollback;
