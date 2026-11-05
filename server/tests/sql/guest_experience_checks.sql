-- Checks for 0654 (guest experience builder). Local dev DB only; runs inside one transaction and rolls back.
--   docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 < server/tests/sql/guest_experience_checks.sql
-- Uses the local Niks Cafe (agent/demo/niks_cafe_local.sql). Prints "PASS <n>" lines; any failure stops with an error.
\set org 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'
begin;
set local search_path = public, extensions;
create temp table _ctx as select (select user_id from org_users where organization_id = :'org' and status = 'active' limit 1) as owner;
grant select on _ctx to authenticated;
delete from guest_experience_versions where organization_id = :'org';
delete from guest_experiences where organization_id = :'org';

create function pg_temp.ok(n int, cond boolean, what text) returns text language plpgsql as $$
begin if not coalesce(cond, false) then raise exception 'FAIL %: %', n, what; end if; return 'PASS ' || n || ' ' || what; end $$;
grant execute on function pg_temp.ok(int, boolean, text) to authenticated;

create function pg_temp.as_owner() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select owner from _ctx), 'role', 'authenticated')::text, true);
$$;
grant execute on function pg_temp.as_owner() to authenticated;

select pg_temp.as_owner();
set local role authenticated;

-- 1 builder opens with the default page
select pg_temp.ok(1, (b->'draft'->>'look') = 'bistro_dark' and (b->>'draft_version')::int = 0 and b->'live' = 'null'::jsonb, 'builder opens with defaults')
  from (select gx_builder_get('{}') b) x;

-- 2 markup refused
do $$ begin
  perform gx_draft_save(jsonb_build_object('expected_draft_version', 0, 'definition',
    jsonb_set((gx_builder_get('{}')->'draft'), '{blocks,0,props,headline}', '"<script>x</script>"')));
  raise exception 'FAIL 2: markup accepted';
exception when others then if sqlerrm not like 'GX_BAD_REQUEST%' then raise; end if; end $$;
select 'PASS 2 markup refused';

-- 3 colour-only change publishes at once (rules)
select gx_draft_save(jsonb_build_object('expected_draft_version', 0, 'definition',
  jsonb_set((gx_builder_get('{}')->'draft'), '{theme,accent}', '"#E4572E"')));
select pg_temp.ok(3, r->>'result' = 'auto_approved' and (r->'builder'->>'live_version')::int = 1, 'colour change live by rules') from (select gx_publish('{}') r) x;

-- 4 new wording goes to the AI step, not live yet
select gx_draft_save(jsonb_build_object('expected_draft_version', 1, 'definition',
  jsonb_set(jsonb_set((gx_builder_get('{}')->'draft'), '{theme,accent}', '"#E4572E"'), '{blocks,0,props,headline}', '"Fresh coffee, made slow"')));
select pg_temp.ok(4, r->>'result' = 'pending_ai' and (r->'builder'->>'live_version')::int = 1, 'wording waits for AI') from (select gx_publish('{}') r) x;

-- 5 restaurants cannot finish the AI step themselves
do $$ begin
  perform gx_ai_verdict(jsonb_build_object('id', gen_random_uuid(), 'verdict', 'ok'));
  raise exception 'FAIL 5: restaurant could call gx_ai_verdict';
exception when insufficient_privilege then null; end $$;
select 'PASS 5 AI verdict is server-only';

reset role;
-- 6 server: AI ok -> live
select pg_temp.ok(6, (gx_ai_verdict(jsonb_build_object('id', (select id from guest_experience_versions where organization_id = :'org' and status = 'pending_ai'),
  'verdict', 'ok', 'model', 'test')))->>'status' = 'ai_approved', 'AI ok publishes');
select pg_temp.ok(6, (select live_version from guest_experiences where organization_id = :'org') = 2, 'AI-approved version is live');

-- 7 discount claim is held for a human, with money category
create function pg_temp.def_with(p_path text[], p_val jsonb) returns jsonb language sql as $$
  select jsonb_set((select definition from guest_experience_versions where organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd' order by version desc limit 1), p_path, p_val);
$$;
grant execute on function pg_temp.def_with(text[], jsonb) to authenticated;
select pg_temp.as_owner();
set local role authenticated;
select gx_draft_save(jsonb_build_object('expected_draft_version', 2, 'definition', pg_temp.def_with('{blocks,0,props,headline}', '"50% OFF today only"')));
select pg_temp.ok(7, r->>'result' = 'pending_human' and r->'version'->'categories' ? 'money', 'discount claim held (money)') from (select gx_publish('{}') r) x;

-- 8 phone number in wording is held (security); it replaces the waiting one
select gx_draft_save(jsonb_build_object('expected_draft_version', 3, 'definition', pg_temp.def_with('{blocks,0,props,subtext}', '"Call 98765 43210 to book"')));
select pg_temp.ok(8, r->>'result' = 'pending_human' and r->'version'->'categories' ? 'security', 'phone held (security)') from (select gx_publish('{}') r) x;
select pg_temp.ok(8, (select count(*) from guest_experience_versions where organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd' and status = 'superseded') = 1,
  'older waiting publish superseded');

reset role;
-- 9 Master: queue shows it, reject needs a note, approve makes it live
select pg_temp.ok(9, (gx_review_queue('{}')->>'waiting')::int >= 1, 'review queue lists the held publish');
do $$ begin
  perform gx_review_decide(jsonb_build_object('id', (select id from guest_experience_versions where status = 'pending_human' and organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'), 'action', 'reject'));
  raise exception 'FAIL 10: reject without a note';
exception when others then if sqlerrm not like 'GX_BAD_REQUEST%' then raise; end if; end $$;
select 'PASS 10 reject needs a note';
select pg_temp.ok(11, (gx_review_decide(jsonb_build_object('id', (select id from guest_experience_versions where status = 'pending_human' and organization_id = :'org'),
  'action', 'approve', 'actor_name', 'Test reviewer')))->>'status' = 'human_approved', 'human approve publishes');
select pg_temp.ok(11, (select live_version from guest_experiences where organization_id = :'org') = 4, 'human-approved version is live');

-- 12 switching dine-in off is a compliance hold
select pg_temp.as_owner();
set local role authenticated;
select gx_draft_save(jsonb_build_object('expected_draft_version', 4, 'definition',
  pg_temp.def_with('{blocks,1,props}', '{"dine_in": false, "pre_order": true, "dine_in_label": "Dine-in", "pre_order_label": "Pre-order"}')));
select pg_temp.ok(12, r->>'result' = 'pending_human' and r->'version'->'categories' ? 'compliance', 'order mode change held (compliance)') from (select gx_publish('{}') r) x;

-- 13 rollback to version 1 is immediate
select pg_temp.ok(13, r->>'result' = 'auto_approved' and (r->'builder'->>'live_version')::int = 6, 'rollback live at once') from (select gx_rollback('{"version": 1}') r) x;

-- 14 stranger cannot read drafts or versions
reset role;
set local role anon;
do $$ begin perform 1 from guest_experiences; raise exception 'FAIL 14: anon reads drafts'; exception when insufficient_privilege then null; end $$;
select 'PASS 14 anon cannot read drafts';
reset role;

-- 15 reserved store link refused
do $$ begin update org_listing_profiles set store_slug = 'privacy' where organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'; raise exception 'FAIL 15';
exception when others then if sqlerrm not like 'SF_BAD_REQUEST%' then raise; end if; end $$;
select 'PASS 15 reserved store link refused';

-- 16 public menu carries the live experience
select pg_temp.ok(16, (guest_menu_by_slug('{"slug": "niks-cafe"}')->'menu'->'experience'->'theme'->>'accent') = '#E4572E', 'public menu has the experience');

-- 17-19 pre-order: needs the block on; slot must be offered; staff accept -> pickup order
select pg_temp.as_owner();
set local role authenticated;
select gx_draft_save(jsonb_build_object('expected_draft_version', (gx_builder_get('{}')->>'draft_version')::int, 'definition',
  pg_temp.def_with('{blocks,1,props}', '{"dine_in": true, "pre_order": true, "dine_in_label": "Dine-in", "pre_order_label": "Pre-order"}')));
select gx_publish('{}');
reset role;
select gx_review_decide(jsonb_build_object('id', (select id from guest_experience_versions where organization_id = :'org' and status = 'pending_human'),
  'action', 'approve', 'actor_name', 'Test reviewer'));
select pg_temp.ok(17, jsonb_array_length(gx_preorder_slots('{"slug": "niks-cafe"}')->'days') >= 1, 'pre-order slots offered');
select pg_temp.ok(18, (gx_preorder_place(jsonb_build_object('slug', 'niks-cafe', 'idempotency_key', 'chk-pre-0001', 'guest_name', 'Asha', 'phone', '9876500011',
  'pickup_at', gx_preorder_slots('{"slug": "niks-cafe"}')->'days'->-1->'slots'->0,
  'lines', jsonb_build_array(jsonb_build_object('menu_item_id', (select id from menu_items where organization_id = :'org' and name = 'Cappuccino'), 'qty', 2)))))->>'status' = 'waiting',
  'pre-order waiting in the guest inbox');
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.ok(19, (guest_request_decide(jsonb_build_object('id', (select id from guest_order_requests where organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd' and kind = 'preorder' and idempotency_key = 'chk-pre-0001'),
  'action', 'accept'))->>'status') = 'accepted', 'staff accept makes an order');
reset role;
select pg_temp.ok(20, (select o.channel::text from orders o join guest_order_requests r on r.order_id = o.id where r.idempotency_key = 'chk-pre-0001') = 'pickup', 'it is a pickup order');

rollback;
