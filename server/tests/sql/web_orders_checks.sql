-- Checks for 0662 (web orders through the customer server). Local dev DB only; runs inside one transaction and rolls back.
--   docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 < server/tests/sql/web_orders_checks.sql
-- Uses the local Niks Cafe (agent/demo/niks_cafe_local.sql) linked to One Local (agent/demo/niks_cafe_one_local_link.sql).
-- Prints "PASS <n>" lines; any failure stops with an error. Opening hours are opened for the run (rolled back), so it passes at night too.
\set org 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'
\set outlet '7b0b7ead-af89-43bb-bba5-dff5841a3558'
begin;
set local search_path = public, extensions;

create function pg_temp.ok(n int, cond boolean, what text) returns text language plpgsql as $$
begin if not coalesce(cond, false) then raise exception 'FAIL %: %', n, what; end if; return 'PASS ' || n || ' ' || what; end $$;
grant execute on function pg_temp.ok(int, boolean, text) to authenticated;
-- the error a call raises ('' when it does not raise)
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;

-- open all day for the run, accepting, nothing held
update org_listing_profiles set weekly_hours = null, open_days = null where organization_id = :'org';   -- no hours set = not restricted
update ol_merchant_channels set accepting = true, require_pos_heartbeat = false where organization_id = :'org';
update outlet_channels set accepting = true, paused_reason = null where location_id = :'outlet';

create temp table _ctx as
select (select user_id from org_users where organization_id = :'org' and status = 'active' limit 1) as owner,
       (select id from menu_items m where m.organization_id = :'org' and public.guest__orderable(m.id, :'outlet', public.guest__published(:'org')) order by m.price, m.id limit 1) as dish,
       (select id from menu_items m where m.organization_id = :'org' and public.guest__orderable(m.id, :'outlet', public.guest__published(:'org')) order by m.price, m.id offset 1 limit 1) as dish2,
       (select qr_token from dining_tables where organization_id = :'org' and is_active and qr_enabled and qr_token is not null order by label limit 1) as code1,
       (select qr_token from dining_tables where organization_id = :'org' and is_active and qr_enabled and qr_token is not null order by label offset 1 limit 1) as code2,
       encode(sha256('web-check-device-a'::bytea), 'hex') as dev_a,
       encode(sha256('web-check-device-b'::bytea), 'hex') as dev_b,
       ((gx_preorder_slots('{"slug": "niks-cafe"}')->'days'->0->'slots'->>0)) as slot;
grant select on _ctx to authenticated;
select pg_temp.ok(0, (select dish is not null and dish2 is not null and code1 is not null and code2 is not null and slot is not null and owner is not null from _ctx),
  'Niks Cafe has dishes, two QR tables, a pickup slot and an owner');

create temp table _s as select (guest_qr_open(jsonb_build_object('code', (select code1 from _ctx)))->>'session') as s1,
                               (guest_qr_open(jsonb_build_object('code', (select code2 from _ctx)))->>'session') as s2;

create function pg_temp.dine(p_key text, p_session text, p_dev text, p_qty int default 2) returns jsonb language sql as $$
  select ol_web_order_place(jsonb_build_object('customer_hash', p_dev, 'store_link', 'niks-cafe', 'mode', 'dine_in', 'table_session', p_session,
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', p_qty, 'notes', 'less sugar')),
    'guest_name', 'Asha', 'idempotency_key', p_key));
$$;

-- 1 dine-in with a real QR session: customer order + POS order with the table, at once
create temp table _d1 as select pg_temp.dine('web-check-0001', (select s1 from _s), (select dev_a from _ctx)) as r;
select pg_temp.ok(1, r->>'stage' = 'waiting_partner' and r->>'mode' = 'dine_in' and r->>'table_label' is not null and r->>'track' ~ '^[0-9a-f]{36}$'
                     and (r->>'replayed')::boolean = false and r->>'display_no' like 'OL-%' and jsonb_array_length(r->'lines') = 1, 'dine-in placed: ' || (r->>'display_no'))
  from _d1;
select pg_temp.ok(1, x.source = 'web' and x.order_mode = 'dine_in' and x.status = 'placed' and x.track_hash = encode(sha256(convert_to(d.r->>'track', 'UTF8')), 'hex')
                     and x.store_id = 'niks-cafe' and x.city_id = 'latur' and x.organization_id = :'org' and x.payment_method = 'cod'
                     and o.channel = 'online' and o.placed_by = 'integration' and o.external_ref = 'onelocal:' || x.id and o.status = 'new'
                     and o.table_id = (select table_id from guest_qr_sessions where secret_hash = guest__hash((select s1 from _s)))
                     and o.location_id = :'outlet' and o.total = x.total and o.subtotal = x.subtotal and x.table_label = (select label from dining_tables where id = o.table_id),
  'ol_orders web/dine_in + POS order online with table, same money')
  from _d1 d join ol_orders x on x.id = (d.r->>'order_id')::uuid join orders o on o.id = x.pos_order_id;
select pg_temp.ok(1, (select notes from order_items i join ol_orders x on x.pos_order_id = i.order_id where x.id = (d.r->>'order_id')::uuid) = 'less sugar'
                     and exists (select 1 from order_events e join ol_orders x on x.pos_order_id = e.order_id where x.id = (d.r->>'order_id')::uuid and e.kind = 'placed' and e.message like '%web page%')
                     and exists (select 1 from domain_events v where v.aggregate_id = d.r->>'order_id' and v.event_type = 'ol_order.created'),
  'dish note kept, POS placed event and the domain event written') from _d1 d;

-- 2 idempotent replay: same device + key + body = same order, nothing new, no tracking link again
select pg_temp.ok(2, r->>'order_id' = (select r->>'order_id' from _d1) and (r->>'replayed')::boolean and r->'track' = 'null'::jsonb
                     and (select count(*) from ol_orders where idempotency_key = 'web-check-0001') = 1, 'replay answers the same order')
  from (select pg_temp.dine('web-check-0001', (select s1 from _s), (select dev_a from _ctx)) r) z;
-- 3 same key, another body: refused
select pg_temp.ok(3, pg_temp.err($q$select pg_temp.dine('web-check-0001', (select s1 from _s), (select dev_a from _ctx), 3)$q$) like 'OL_IDEMPOTENCY_MISMATCH%', 'same key, other order refused');
-- 3b another device may use the same key: its own order
select pg_temp.ok(3, (r->>'order_id') <> (select r->>'order_id' from _d1), 'same key on another device is another order')
  from (select pg_temp.dine('web-check-0001', (select s2 from _s), (select dev_b from _ctx), 1) r) z;

-- 4 pickup in an offered slot with a phone
create temp table _p1 as select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'pickup',
  'pickup_at', (select slot from _ctx), 'phone', '98765 43210', 'guest_name', 'Ravi', 'note', 'pack separately',
  'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish2 from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0002')) as r;
select pg_temp.ok(4, r->>'mode' = 'pickup' and (r->>'pickup_at')::timestamptz = (select slot from _ctx)::timestamptz and r->'table_label' = 'null'::jsonb
                     and o.table_id is null and o.customer_phone = '9876543210' and o.customer_name = 'Ravi' and o.notes like 'Web order · pickup %pack separately'
                     and x.order_mode = 'pickup' and x.pickup_at = (select slot from _ctx)::timestamptz, 'pickup placed: ' || (r->>'display_no'))
  from _p1 p join ol_orders x on x.id = (p.r->>'order_id')::uuid join orders o on o.id = x.pos_order_id;
-- 5 pickup rules: a phone, an offered time
select pg_temp.ok(5, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'pickup',
  'pickup_at', (select slot from _ctx), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0005'))$q$)
  like 'OL_BAD_REQUEST: enter a 10-digit mobile number%', 'pickup without a phone refused');
select pg_temp.ok(5, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'pickup',
  'pickup_at', '2020-01-01T10:00:00Z', 'phone', '9876543210', 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0006'))$q$)
  like 'OL_BAD_REQUEST: that pickup time is not available%', 'pickup at a time that is not offered refused');
select pg_temp.ok(5, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'dine_in',
  'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0007'))$q$)
  like 'OL_BAD_REQUEST: scan the table QR code%', 'dine-in without a table session refused');

-- 6 a QR session of another restaurant is refused (the table never comes from the request)
create temp table _other as
select t.organization_id as org, t.location_id as loc, t.id as table_id, t.qr_token as code, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') as secret
  from dining_tables t where t.organization_id <> :'org' and t.is_active and t.qr_enabled and t.qr_token is not null and t.location_id is not null limit 1;
insert into guest_qr_sessions (organization_id, location_id, table_id, secret_hash, code_hash, expires_at)
select org, loc, table_id, guest__hash(secret), guest__hash(code), now() + interval '1 hour' from _other;
select pg_temp.ok(6, pg_temp.err($q$select pg_temp.dine('web-check-0008', (select secret from _other), (select dev_a from _ctx))$q$) like 'OL_SESSION_MISMATCH%',
  'another restaurant''s table session refused');
select pg_temp.ok(6, pg_temp.err($q$select pg_temp.dine('web-check-0009', repeat('ab', 32), (select dev_a from _ctx))$q$) like 'OL_SESSION_EXPIRED%', 'an unknown session refused');

-- 7 a page that is not live, an unknown link, a restaurant not linked to One Local, a paused restaurant
select pg_temp.ok(7, pg_temp.err(format($q$select ol_web_order_place(jsonb_build_object('customer_hash', %L, 'store_link', %L, 'mode', 'pickup', 'pickup_at', %L,
  'phone', '9876543210', 'lines', '[]'::jsonb, 'idempotency_key', 'web-check-0010'))$q$, (select dev_a from _ctx),
  (select store_slug from org_listing_profiles l where store_slug is not null and cardinality(guest__public_blockers(l.organization_id)) > 0 limit 1), (select slot from _ctx)))
  like 'OL_NOT_FOUND%', 'a page that is not live refused');
select pg_temp.ok(7, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'no-such-place', 'mode', 'dine_in',
  'idempotency_key', 'web-check-0011'))$q$)
  like 'OL_NOT_FOUND%', 'an unknown link refused');
update ol_stores set deleted_at = now() where id = 'niks-cafe';
select pg_temp.ok(7, pg_temp.err($q$select pg_temp.dine('web-check-0012', (select s1 from _s), (select dev_a from _ctx))$q$) like 'OL_NOT_ONE_LOCAL%', 'not linked to One Local refused');
update ol_stores set deleted_at = null where id = 'niks-cafe';
update ol_merchant_channels set accepting = false where organization_id = :'org';
select pg_temp.ok(7, pg_temp.err($q$select pg_temp.dine('web-check-0013', (select s1 from _s), (select dev_a from _ctx))$q$) like 'OL_NOT_ACCEPTING%', 'a paused restaurant refused');
update ol_merchant_channels set accepting = true where organization_id = :'org';
update outlet_channels set accepting = true, paused_reason = null where location_id = :'outlet';

-- 8 a dish out of stock (the stock switch) is refused; so is a dish switched off for One Local
update menu_items set is_available = false where id = (select dish2 from _ctx);
select pg_temp.ok(8, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'dine_in',
  'table_session', (select s1 from _s), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish2 from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0014'))$q$)
  like 'OL_ITEM_UNAVAILABLE%', 'out-of-stock dish refused');
update menu_items set is_available = true where id = (select dish2 from _ctx);
insert into item_channel_status (organization_id, menu_item_id, channel, is_available) values (:'org', (select dish2 from _ctx), 'one_local', false)
on conflict (menu_item_id, channel) do update set is_available = false, off_until = null;
select pg_temp.ok(8, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'dine_in',
  'table_session', (select s1 from _s), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish2 from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0015'))$q$)
  like 'OL_ITEM_UNAVAILABLE%', 'dish off for One Local refused');
delete from item_channel_status where menu_item_id = (select dish2 from _ctx) and channel = 'one_local';
select pg_temp.ok(8, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_a from _ctx), 'store_link', 'niks-cafe', 'mode', 'dine_in',
  'table_session', (select s1 from _s), 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish from _ctx), 'qty', 1, 'unit_price', 1)), 'idempotency_key', 'web-check-0016'))$q$)
  = '', 'a price in the request is ignored (the database prices the dish)');

-- 9 the POS Orders board lists the web order as Web, with its table; the pickup with its time
create function pg_temp.as_owner() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select owner from _ctx), 'role', 'authenticated')::text, true);
$$;
grant execute on function pg_temp.as_owner() to authenticated;
grant select on _d1, _p1, _s to authenticated;
create temp table _board (b jsonb); grant all on _board to authenticated;
create temp table _ids as select x.pos_order_id as pos1 from ol_orders x where x.id = (select (r->>'order_id')::uuid from _d1);
grant select on _ids to authenticated;
select pg_temp.as_owner();
set local role authenticated;
insert into _board select rst_channel_orders('{}');
select pg_temp.ok(9, exists (select 1 from _board, jsonb_array_elements(b->'orders') e where e->>'source' = 'web' and e->>'stage' = 'new' and e->>'mode' = 'dine_in'
                     and e->>'table_label' is not null and e->>'id' = (select pos1::text from _ids)),
  'board: dine-in web order, source web, stage new, table label');
select pg_temp.ok(9, exists (select 1 from _board, jsonb_array_elements(b->'orders') e where e->>'source' = 'web' and e->>'mode' = 'pickup' and e->>'pickup_at' is not null),
  'board: pickup web order with its time');
select pg_temp.ok(9, exists (select 1 from _board, jsonb_array_elements(b->'channels') c where c->>'key' = 'web' and c->>'label' = 'Web' and (c->>'new')::int >= 2),
  'board: a Web channel with its count');

-- 10 accept on the board (unchanged rst_channel_accept): the KOT fires, the customer order is accepted
select rst_channel_accept(jsonb_build_object('order_id', (select pos1 from _ids)));
reset role;
select pg_temp.ok(10, x.status = 'accepted' and o.status = 'sent_to_kitchen' and exists (select 1 from kot_tickets k where k.order_id = o.id and k.status <> 'cancelled')
                      and not exists (select 1 from order_items i where i.order_id = o.id and i.kot_ticket_id is null), 'accept fired the KOT')
  from ol_orders x join orders o on o.id = x.pos_order_id where x.id = (select (r->>'order_id')::uuid from _d1);

-- 11 the stages the guest sees, by the tracking link and by order id + device
create function pg_temp.st() returns jsonb language sql as $$ select ol_web_order_status(jsonb_build_object('track', (select r->>'track' from _d1))) $$;
select pg_temp.ok(11, pg_temp.st()->>'stage' = 'accepted' and pg_temp.st()->>'stage_label' = 'Accepted' and pg_temp.st()->'accepted_at' <> 'null'::jsonb
                      and (pg_temp.st()->>'eta_minutes')::int > 0 and (pg_temp.st()->>'can_request_bill')::boolean = false, 'accepted');
select pg_temp.ok(11, (ol_web_order_status(jsonb_build_object('order_id', (select r->>'order_id' from _d1), 'customer_hash', (select dev_a from _ctx))))->>'stage' = 'accepted',
  'status by order id with the same device');
select pg_temp.ok(11, pg_temp.err(format($q$select ol_web_order_status(jsonb_build_object('order_id', %L, 'customer_hash', %L))$q$,
  (select r->>'order_id' from _d1), (select dev_b from _ctx))) like 'OL_NOT_FOUND%', 'another device cannot read it');
select pg_temp.ok(11, pg_temp.err($q$select ol_web_order_status('{"track": "0123456789abcdef0123456789abcdef0123"}')$q$) like 'OL_NOT_FOUND%', 'a made-up tracking link finds nothing');
update order_items set status = 'preparing' where order_id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1));
select pg_temp.ok(11, pg_temp.st()->>'stage' = 'preparing' and pg_temp.st()->'lines'->0->>'status' = 'preparing', 'preparing');
-- 12 the bill is refused while a dish is still cooking
select pg_temp.ok(12, pg_temp.err($q$select ol_web_order_bill(jsonb_build_object('track', (select r->>'track' from _d1)))$q$) like 'OL_BILL_NOT_YET%', 'no bill while cooking');
select pg_temp.ok(12, pg_temp.err($q$select ol_web_order_bill(jsonb_build_object('track', (select r->>'track' from _p1)))$q$) like 'OL_BILL_NOT_YET%', 'no bill before the restaurant accepts');
update order_items set status = 'ready' where order_id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1));
select pg_temp.ok(13, pg_temp.st()->>'stage' = 'ready' and (pg_temp.st()->>'can_request_bill')::boolean, 'ready, the bill can be asked for');
update order_items set status = 'delivered' where order_id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1));
select pg_temp.ok(13, pg_temp.st()->>'stage' = 'served' and pg_temp.st()->'lines'->0->>'status' = 'served', 'served');
-- 14 ask for the bill: the POS order waits for payment (status gate), the bill comes back; asking again is the same bill
select pg_temp.ok(14, r->>'stage' = 'bill_ready' and r->>'stage_label' = 'Bill ready' and (r->>'already')::boolean = false and r->'bill'->>'payment' = 'at_table'
                      and (r->'bill'->>'total')::numeric > 0 and jsonb_array_length(r->'bill'->'lines') = 1 and (r->'bill'->>'due')::numeric = (r->'bill'->>'total')::numeric,
  'bill ready, total ' || (r->'bill'->>'total')) from (select ol_web_order_bill(jsonb_build_object('track', (select r->>'track' from _d1))) r) z;
select pg_temp.ok(14, (select status from orders where id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1))) = 'awaiting_payment'
                      and exists (select 1 from order_events e where e.order_id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1)) and e.kind = 'bill_requested'),
  'POS order awaiting payment, bill_requested logged');
select pg_temp.ok(14, (ol_web_order_bill(jsonb_build_object('track', (select r->>'track' from _d1))))->>'already' = 'true', 'asking again: the same bill');

-- 15 the live feed: dishes with the table, no people, no money; a dish two tables ordered is a streak
select pg_temp.ok(15, exists (select 1 from jsonb_array_elements(f->'items') i where i->>'name' = (select name from menu_items where id = (select dish from _ctx))
                              and i->>'table_label' is not null and (i->>'seconds_ago')::int >= 0 and i ? 'category')
                      and not exists (select 1 from jsonb_array_elements(f->'items') i where i ?| array['customer', 'customer_name', 'phone', 'guest_name', 'total', 'price', 'unit_price', 'amount'])
                      and f::text not like '%Asha%' and f::text not like '%9876543210%' and f::text not like '%Ravi%',
  'feed shows the dish and table, no names, phones or amounts') from (select gx_live_feed('{"slug": "niks-cafe"}') f) z;
select pg_temp.ok(15, exists (select 1 from jsonb_array_elements(f->'streaks') s where s->>'kind' = 'dish' and (s->>'count')::int >= 2
                              and s->>'label' like '% tables ordered %'), 'streak: two tables ordered the same dish') from (select gx_live_feed('{"slug": "niks-cafe"}') f) z;
select pg_temp.ok(15, pg_temp.err($q$select gx_live_feed('{"slug": "no-such-place"}')$q$) like 'GUEST_NOT_FOUND%', 'feed of an unknown page refused');

-- 16 offers in the guest menu; a code applies on a web order (the restaurant's coupon rules), both orders carry the same money
insert into sell_coupons (organization_id, code, label, kind, value, min_order, active) values (:'org', 'WEBTEN', 'Web 10% off', 'percent', 10, 0, true);
select pg_temp.ok(16, exists (select 1 from jsonb_array_elements(guest_menu(jsonb_build_object('session', (select s1 from _s)))->'offers') o
                              where o->>'code' = 'WEBTEN' and o->>'kind' = 'percent' and (o->>'value')::numeric = 10 and o->>'title' = 'Web 10% off' and o ? 'ends_at' and o ? 'min_order'),
  'guest menu lists the live code');
select pg_temp.ok(16, jsonb_typeof(guest_menu_by_slug('{"slug": "niks-cafe"}')->'menu'->'offers') = 'array', 'public menu link carries offers too');
create temp table _c1 as select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_b from _ctx), 'store_link', 'niks-cafe', 'mode', 'pickup',
  'pickup_at', (select slot from _ctx), 'phone', '9876500000', 'coupon_code', 'webten',
  'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish2 from _ctx), 'qty', 2)), 'idempotency_key', 'web-check-0017')) as r;
select pg_temp.ok(16, o.coupon_code = 'WEBTEN' and o.discount = round(o.subtotal * 0.10, 2) and x.discount = o.discount and x.total = o.total and x.coupon_code = 'WEBTEN'
                      and (c.r->>'discount')::numeric = o.discount and exists (select 1 from sell_coupon_redemptions s where s.order_id = o.id),
  'code applied: discount ' || o.discount || ', total ' || o.total)
  from _c1 c join ol_orders x on x.id = (c.r->>'order_id')::uuid join orders o on o.id = x.pos_order_id;
select pg_temp.ok(16, pg_temp.err($q$select ol_web_order_place(jsonb_build_object('customer_hash', (select dev_b from _ctx), 'store_link', 'niks-cafe', 'mode', 'pickup',
  'pickup_at', (select slot from _ctx), 'phone', '9876500000', 'coupon_code', 'NOPE123',
  'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select dish2 from _ctx), 'qty', 1)), 'idempotency_key', 'web-check-0018'))$q$) like 'OL_COUPON_UNKNOWN%',
  'an unknown code refused');

-- 17 money and dispatch: a web order is the restaurant's own sale and never asks for a rider
select pg_temp.ok(17, not exists (select 1 from commission_quote((select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _d1)))), 'no commission quote on a web order');
update ol_orders set created_at = now() - interval '5 minutes' where id = (select (r->>'order_id')::uuid from _p1);
select pg_temp.ok(17, not exists (select 1 from delivery_orders_needing_rider where ol_order_id = (select (r->>'order_id')::uuid from _p1)), 'a web order never waits for a rider');

-- 18 the restaurant declines: the guest sees declined; a paused outlet shows on a waiting order
select order_transition((select (r->>'order_id')::uuid from _c1), 'restaurant_reject', 'system', null, '{}'::jsonb);
select pg_temp.ok(18, (ol_web_order_status(jsonb_build_object('track', (select r->>'track' from _c1))))->>'stage' = 'declined'
                      and (select status from orders where id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _c1))) = 'cancelled'
                      and not exists (select 1 from sell_coupon_redemptions s where s.order_id = (select pos_order_id from ol_orders where id = (select (r->>'order_id')::uuid from _c1)) and s.released_at is null),
  'declined: POS order cancelled, the code given back');
update outlet_channels set accepting = false, paused_reason = 'person' where location_id = :'outlet';
select pg_temp.ok(18, s->>'stage' = 'waiting_partner' and s->>'stage_label' = 'Restaurant paused' and s->'restaurant_paused'->>'reason' = 'person',
  'a waiting order says the restaurant is paused') from (select ol_web_order_status(jsonb_build_object('track', (select r->>'track' from _p1))) s) z;
update outlet_channels set accepting = true, paused_reason = null where location_id = :'outlet';

-- 19 only the server may call these
select pg_temp.ok(19, not has_function_privilege('anon', 'public.ol_web_order_place(jsonb)', 'execute')
                      and not has_function_privilege('authenticated', 'public.ol_web_order_place(jsonb)', 'execute')
                      and not has_function_privilege('authenticated', 'public.ol_web_order_status(jsonb)', 'execute')
                      and not has_function_privilege('anon', 'public.ol_web_order_bill(jsonb)', 'execute')
                      and not has_function_privilege('anon', 'public.gx_live_feed(jsonb)', 'execute')
                      and has_function_privilege('service_role', 'public.ol_web_order_place(jsonb)', 'execute')
                      and has_function_privilege('service_role', 'public.gx_live_feed(jsonb)', 'execute'), 'service role only');
select pg_temp.ok(19, (select count(*) from ol_orders where source = 'app' and order_mode = 'delivery') = (select count(*) from ol_orders where source = 'app'),
  'existing orders stay app / delivery');

rollback;
