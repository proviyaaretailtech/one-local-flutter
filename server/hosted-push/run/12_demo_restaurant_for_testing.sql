-- Demo Restaurant (TEST) on hosted: an approved dummy restaurant with dummy data, for testing (founder, 30 Oct 2026).
-- 1. Sign in once on the app with a mobile number that is in no business yet (it creates the login), then close the app.
-- 2. Put that 10-digit number on the v_mobile line below, run this whole file in the SQL editor, then sign in again.
-- What it makes (one transaction: an error changes nothing):
--   * the business "Demo Restaurant (TEST)" (Restaurant), with that login as its owner;
--   * its partner application, the 4 checks set verified with the note "TEST - dummy restaurant, not verified", approved through
--     master_partner_application_decide by an active platform admin, like any approval;
--   * NO customer listing (ol_stores): customers never see it; an unfinished seller application of that number becomes the demo's;
--   * Niks Cafe's set-up copied with new ids: categories, dishes and sizes, ingredients, recipes, add-ons, combos, tables T1-T5,
--     suppliers and purchase orders; then opening stock for 100 of each dish;
--   * dummy activity as the owner: table orders at every kitchen stage, a takeaway, a delivery, and paid bills.
-- To remove it later: ask Claude for the purge script (the business id is in the "Done" message).
create temp table _map (old text primary key, new text not null) on commit drop;

-- a row of Niks Cafe as a row of the demo: every id in _map swapped, links to people dropped, QR tokens left empty
create function pg_temp.remap(j jsonb) returns jsonb language sql as $f$
  select jsonb_object_agg(e.key, case
           when e.key in ('updated_by', 'qr_issued_by', 'completed_by', 'changed_by', 'qr_token') then 'null'::jsonb
           when jsonb_typeof(e.value) = 'string' and m.new is not null then to_jsonb(m.new)
           else e.value end)
    from jsonb_each(j) e left join _map m on m.old = e.value #>> '{}'
$f$;

do $$
declare
  v_mobile text := '9XXXXXXXXX';  -- <<< the 10-digit mobile number
  v_src constant uuid := 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd';  -- Niks Cafe (test): the set-up is copied from it
  v_note constant text := 'TEST - dummy restaurant, not verified';
  stamp constant text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  v_tables constant text[] := array['menu_categories', 'menu_items', 'menu_item_variants', 'inventory_items', 'ingredient_profiles',
    'menu_item_recipes', 'menu_addon_groups', 'menu_addons', 'menu_item_addon_groups', 'menu_addon_recipes', 'menu_combos', 'menu_combo_items',
    'menu_combo_groups', 'menu_combo_group_combos', 'menu_item_combo_groups', 'menu_item_channel_prices', 'dining_tables', 'pos_suppliers',
    'pos_supplier_prices', 'pos_purchase_orders', 'pos_purchase_order_lines'];
  v_user auth.users%rowtype; v_other text; v_res jsonb; v_org uuid; v_loc uuid; v_src_loc uuid; v_app uuid; v_admin uuid;
  t text; v_cols text; v_kind text; v_n int;
  r jsonb; tk jsonb; v_order uuid;
  dish jsonb := '{}'; tbl jsonb := '{}';
begin
  -- ---- who
  if v_mobile !~ '^[6-9][0-9]{9}$' then raise exception 'Put the 10-digit mobile number in v_mobile first.'; end if;
  select * into v_user from auth.users where phone in ('91' || v_mobile, '+91' || v_mobile) order by created_at limit 1;
  if not found then raise exception 'No login with +91 % yet: sign in once on the app with it, then run this again.', v_mobile; end if;
  select string_agg(o.name, ', ') into v_other from public.org_users ou join public.organizations o on o.id = ou.organization_id
   where ou.user_id = v_user.id and ou.status = 'active';
  if v_other is not null then raise exception '+91 % already belongs to %: the app would open that one. Use another number.', v_mobile, v_other; end if;
  select user_id into v_admin from public.platform_admins where status = 'Active' order by created_at limit 1;
  if v_admin is null then raise exception 'No active platform admin to approve the application.'; end if;
  if not exists (select 1 from public.menu_items where organization_id = v_src) then raise exception 'Niks Cafe has no menu to copy.'; end if;
  select id into v_src_loc from public.locations where organization_id = v_src order by (code = 'MAIN') desc, created_at limit 1;

  -- ---- the business (pending until approved) and its owner
  v_res := public.master_create_organization(jsonb_build_object('name', 'Demo Restaurant (TEST)', 'slug', 'demo-restaurant-test-' || stamp,
    'business_domain', 'Restaurant', 'type', 'franchise', 'contact_phone', v_mobile, 'control_status', 'Pending'));
  v_org := (v_res->>'organization_id')::uuid;
  select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1;
  insert into public.org_users (organization_id, user_id, role_id, email, full_name, status)
  values (v_org, v_user.id, (select id from public.roles where slug = 'org_owner'),
          coalesce(nullif(v_user.email, ''), v_mobile || '@phone.onelocal.invalid'), 'Demo Owner (TEST)', 'active');

  -- ---- its application (shaped like Niks Cafe's), the 4 checks verified as TEST, then approved like any other
  -- an unfinished seller application of this number (from "Become a seller") becomes the demo's: one open application per number and city
  select id into v_app from public.ol_partner_applications
   where phone = v_mobile and status in ('draft', 'submitted', 'reviewing') and organization_id is null order by created_at desc limit 1;
  if v_app is not null then
    if exists (select 1 from public.ol_partner_application_documents d where d.application_id = v_app and d.status <> 'verified') then
      raise exception '+91 % has an unfinished seller application with documents still to check: use another number.', v_mobile;
    end if;
    update public.ol_partner_applications a
       set business_name = 'Demo Restaurant (TEST)', business_type = 'restaurant', partner_type = 'restaurant',
           owner_name = coalesce(nullif(btrim(a.owner_name), ''), 'Demo Owner (TEST)'),
           address = coalesce(a.address, n.address), pin_code = coalesce(a.pin_code, n.pin_code), city_id = coalesce(a.city_id, n.city_id),
           notes = v_note, organization_id = v_org, applicant_user_id = v_user.id,
           status = case when a.status = 'draft' then 'submitted' else a.status end
      from (select address, pin_code, city_id from public.ol_partner_applications where organization_id = v_src order by created_at desc limit 1) n
     where a.id = v_app;
  else
  v_app := gen_random_uuid();
  insert into public.ol_partner_applications
  select (jsonb_populate_record(null::public.ol_partner_applications, to_jsonb(a) || jsonb_build_object(
            'id', v_app, 'reference', 'OLP-DEMO' || right(stamp, 6), 'submit_key', 'sql_demo_restaurant_' || stamp,
            'business_name', 'Demo Restaurant (TEST)', 'business_type', 'restaurant', 'partner_type', 'restaurant',
            'owner_name', 'Demo Owner (TEST)', 'phone', v_mobile, 'email', null, 'gstin', null, 'fssai', null,
            'notes', v_note, 'status', 'submitted', 'organization_id', v_org, 'applicant_user_id', v_user.id,
            'reviewed_by', null, 'reviewed_at', null, 'review_note', null, 'created_at', now(), 'updated_at', now()))).*
    from public.ol_partner_applications a where a.organization_id = v_src order by a.created_at desc limit 1;
  if not found then raise exception 'Niks Cafe has no application to copy the shape from.'; end if;
  end if;
  insert into public.ol_partner_application_checks (application_id, kind, status, note, decided_by, decided_at)
  select v_app, k, 'verified', v_note, v_admin, now()
    from unnest(array['individual_identity', 'business_identity', 'business_address', 'bank_ownership']) k
  on conflict do nothing;
  update public.ol_partner_application_checks set status = 'verified', note = v_note, decided_by = v_admin, decided_at = now()
   where application_id = v_app and status <> 'verified';
  perform public.master_partner_application_decide(v_app, 'approve', v_note, v_admin);

  -- ---- Niks Cafe's set-up, copied with new ids (every id of a copied row gets a new one; references follow it)
  insert into _map values (v_src::text, v_org::text), (v_src_loc::text, v_loc::text) on conflict do nothing;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then continue; end if;
    for v_kind in select a.attname from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attname in ('id', 'row_id')
                    and a.atttypid = 'uuid'::regtype and not a.attisdropped loop
      execute format('insert into _map select %I::text, gen_random_uuid()::text from public.%I where organization_id = $1 on conflict do nothing', v_kind, t)
        using v_src;
    end loop;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then continue; end if;
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols from pg_attribute a
     where a.attrelid = ('public.' || t)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
    execute format('insert into public.%1$I (%2$s) select %2$s from jsonb_populate_recordset(null::public.%1$I,
                      (select coalesce(jsonb_agg(pg_temp.remap(to_jsonb(x))), ''[]'') from public.%1$I x where organization_id = $1)) on conflict do nothing',
                   t, v_cols) using v_src;
  end loop;

  -- ---- opening stock: what 100 of every dish needs (with wastage), at the main outlet
  insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, unit_cost_minor, ref_type, ref_id, note)
  select v_org, v_loc, n.item, 'receipt', n.need, coalesce(p.cost_minor, 0), 'opening_stock', 'demo-100', 'Opening stock for 100 of each dish (TEST)'
    from (select mr.inventory_item_id as item, ceil(sum(100 * mr.qty_per_unit * (1 + mr.wastage_pct / 100)) * 1000) / 1000 as need
            from public.menu_item_recipes mr where mr.organization_id = v_org group by mr.inventory_item_id) n
    left join public.ingredient_profiles p on p.inventory_item_id = n.item
   where n.need > 0;
  set constraints all immediate;

  -- ---- dummy activity, as the owner (the same calls the app makes)
  select jsonb_object_agg(name, id) into dish from public.menu_items where organization_id = v_org;
  select jsonb_object_agg(label, id) into tbl from public.dining_tables where organization_id = v_org;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user.id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- paid bills first: T2 (cash) and T3 (UPI) eat and pay
  foreach t in array array['T2', 'T3'] loop
    r := public.tbl_order_add(jsonb_build_object('table_id', tbl->>t, 'send', true, 'guest_count', 2, 'idempotency_key', 'demo-' || t || '-paid-' || stamp,
           'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Veg Cheesy Pasta', 'qty', 1), jsonb_build_object('menu_item_id', dish->>'Cappuccino', 'qty', 2))));
    v_order := (r->'order'->>'id')::uuid;
    if v_order is null then v_order := (select o.id from public.orders o where o.organization_id = v_org and o.table_id = (tbl->>t)::uuid order by o.created_at desc limit 1); end if;
    for tk in select x from jsonb_array_elements(public.kds_queue('{}'::jsonb)->'tickets') x where x->>'order_id' = v_order::text loop
      perform public.kds_ticket_act(jsonb_build_object('ticket_id', tk->>'id', 'station', tk->>'station', 'action', 'ready', 'expected_version', tk->>'version', 'idempotency_key', 'demo-rd-' || (tk->>'id')));
    end loop;
    for tk in select x from jsonb_array_elements(public.kds_queue('{}'::jsonb)->'tickets') x where x->>'order_id' = v_order::text loop
      perform public.kds_ticket_act(jsonb_build_object('ticket_id', tk->>'id', 'station', tk->>'station', 'action', 'serve', 'expected_version', tk->>'version', 'idempotency_key', 'demo-sv-' || (tk->>'id')));
    end loop;
    perform public.pos_set_order_status(jsonb_build_object('order_id', v_order, 'to', 'awaiting_payment'));  -- Generate bill
    perform public.rst_bill_pay(jsonb_build_object('order_id', v_order, 'method', case t when 'T2' then 'cash' else 'upi' end,
              'tendered', case t when 'T2' then 1000 end, 'idempotency_key', 'demo-pay-' || t || '-' || stamp));
  end loop;

  -- T1: just sent (New)
  perform public.tbl_order_add(jsonb_build_object('table_id', tbl->>'T1', 'send', true, 'guest_count', 2, 'idempotency_key', 'demo-T1-' || stamp,
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Americano', 'qty', 2, 'notes', 'Less sugar'), jsonb_build_object('menu_item_id', dish->>'Brownie Pancake', 'qty', 1))));
  -- T4: being cooked (Preparing)
  r := public.tbl_order_add(jsonb_build_object('table_id', tbl->>'T4', 'send', true, 'guest_count', 4, 'idempotency_key', 'demo-T4-' || stamp,
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Peri Peri Fries', 'qty', 2), jsonb_build_object('menu_item_id', dish->>'Ice Mint Mocha', 'qty', 1))));
  tk := (select x from jsonb_array_elements(public.kds_queue('{}'::jsonb)->'tickets') x where x->>'id' = r->'kot'->>'ticket_id');
  perform public.kds_ticket_act(jsonb_build_object('ticket_id', tk->>'id', 'station', tk->>'station', 'action', 'start', 'expected_version', tk->>'version', 'idempotency_key', 'demo-T4s-' || stamp));
  -- T5: ready to serve
  r := public.tbl_order_add(jsonb_build_object('table_id', tbl->>'T5', 'send', true, 'guest_count', 2, 'idempotency_key', 'demo-T5-' || stamp,
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Ice Blue', 'qty', 2), jsonb_build_object('menu_item_id', dish->>'Salted Fries', 'qty', 1))));
  tk := (select x from jsonb_array_elements(public.kds_queue('{}'::jsonb)->'tickets') x where x->>'id' = r->'kot'->>'ticket_id');
  perform public.kds_ticket_act(jsonb_build_object('ticket_id', tk->>'id', 'station', tk->>'station', 'action', 'ready', 'expected_version', tk->>'version', 'idempotency_key', 'demo-T5r-' || stamp));
  -- a takeaway and a delivery from the counter (New)
  perform public.pos_counter_order(jsonb_build_object('service_type', 'pickup', 'send', true, 'customer_name', 'Rahul (test)', 'customer_phone', '9876500011',
    'idempotency_key', 'demo-tk-' || stamp, 'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Paneer Subway', 'qty', 1), jsonb_build_object('menu_item_id', dish->>'Cappuccino', 'qty', 1))));
  perform public.pos_counter_order(jsonb_build_object('service_type', 'delivery', 'send', true, 'customer_name', 'Sneha (test)', 'customer_phone', '9876500022',
    'address', 'Flat 4, Shivaji Nagar, Latur', 'idempotency_key', 'demo-dl-' || stamp,
    'lines', jsonb_build_array(jsonb_build_object('menu_item_id', dish->>'Veg Grilled Subway', 'qty', 1), jsonb_build_object('menu_item_id', dish->>'Americano', 'qty', 1, 'notes', 'No ice'))));

  execute 'reset role';
  select count(*) into v_n from public.menu_items where organization_id = v_org;
  raise notice 'Done: Demo Restaurant (TEST) %, approved, owner +91 %, % dishes. Sign out and sign in again.', v_org, v_mobile, v_n;
end $$;
