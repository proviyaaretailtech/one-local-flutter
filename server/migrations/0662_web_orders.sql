-- 0662 Web orders through the customer server: a guest on a restaurant's own page (table QR or brand page) orders, the order becomes a
-- One Local customer order (ol_orders, source 'web') and, in the same transaction, a normal POS order (channel online, external_ref
-- onelocal:<id>, the table for dine-in) so the existing Orders board, accept, KOT, bill and Master views work unchanged.
-- Spec: specs/guest-experience-builder/spec-part2-live-orders.md (contracts A and B). Local dev DB 2026-11-05.
--
--   ol_orders            + source ('app' | 'web'), order_mode (delivery | dine_in | pickup), table_label, pickup_at, track_hash (only the
--                          hash of the guest's tracking link is kept), web_request_hash (same request key, same order). Existing rows: app, delivery.
--   ol_create_restaurant_order   extended, not forked: it also writes the web fields, the table, a discount code, dish notes, and a web order
--                          is priced by the restaurant's own bill rules (tbl_order_reprice: GST, service charge, round off, discount code).
--   ol_web_order_place   service role only: store link -> business (must be live, linked to a One Local store), dine-in table from the QR
--                          session (never from the body), pickup slot from the pre-order slots, prices from the database. Idempotent per
--                          (device hash, request key).
--   ol_web_order_status / ol_web_order_bill   by the tracking link, or by order id + the same device hash. Bill: the POS order moves to
--                          awaiting payment through the status gate only once every dish is ready or served and nothing waits.
--   rst_channel_orders   a web order shows as source 'web' ("Web"), with its table label or pickup time. Accept is unchanged.
--   guest__menu          + offers: live discount codes (sell_coupons) and the storefront offers marked show_on_storefront.
--   gx_live_feed         service role only (POS guest door alias 'feed'): the last 20 minutes of the restaurant's dishes, no people, no money.
--   Money: a web order is the restaurant's own sale, paid to the restaurant at the table or counter: One Local accrues no commission and no
--   "restaurant due" on it (commission_quote, order_money_accrue). Dispatch: a web order never asks for a rider (delivery_orders_needing_rider).
-- Safe to run again.

begin;

-- ------------------------------------------------------------------------------------------------------------ ol_orders
alter table public.ol_orders add column if not exists source text not null default 'app'
  constraint ol_orders_source_check check (source in ('app', 'web'));
alter table public.ol_orders add column if not exists order_mode text not null default 'delivery'
  constraint ol_orders_order_mode_check check (order_mode in ('delivery', 'dine_in', 'pickup'));
alter table public.ol_orders add column if not exists table_label text
  constraint ol_orders_table_label_check check (table_label is null or char_length(table_label) <= 60);
alter table public.ol_orders add column if not exists pickup_at timestamptz;
alter table public.ol_orders add column if not exists track_hash text
  constraint ol_orders_track_hash_check check (track_hash is null or track_hash ~ '^[0-9a-f]{64}$');
alter table public.ol_orders add column if not exists web_request_hash text;
create unique index if not exists ol_orders_track_hash_uq on public.ol_orders (track_hash) where track_hash is not null;
create index if not exists ol_orders_web_recent on public.ol_orders (organization_id, created_at desc) where source = 'web';
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.ol_orders'::regclass and conname = 'ol_orders_web_shape') then
    alter table public.ol_orders add constraint ol_orders_web_shape check (
      source = 'app' or (order_mode in ('dine_in', 'pickup') and track_hash is not null
                         and (order_mode <> 'dine_in' or table_label is not null) and (order_mode <> 'pickup' or pickup_at is not null)));
  end if;
end $$;
comment on column public.ol_orders.source is '0662: app = the One Local app; web = a restaurant''s own guest page (table QR or brand page) through the customer server';
comment on column public.ol_orders.track_hash is '0662: sha256 of the guest''s tracking link (18 random bytes, hex); the link itself is never stored';

-- a web order is served at the table or picked up: it never asks for a rider
create or replace view public.delivery_orders_needing_rider as
 SELECT id AS ol_order_id,
    organization_id,
    store_id,
    status,
    payment_method,
    payment_status,
    created_at
   FROM public.ol_orders o
  WHERE (status <> ALL (ARRAY['cancelled'::text, 'delivered'::text])) AND created_at < (now() - '00:01:00'::interval) AND created_at > (now() - '24:00:00'::interval) AND (payment_method = 'cod'::text OR payment_status = 'paid'::text) AND NOT (EXISTS ( SELECT 1
           FROM public.delivery_jobs j
          WHERE j.ol_order_id = o.id)) AND o.order_mode = 'delivery'::text;

-- ------------------------------------------------------------------- ol_create_restaurant_order: the web fields (replace and assert)
do $$
declare v_src text := pg_get_functiondef('public.ol_create_restaurant_order(jsonb)'::regprocedure); v_n int := 0;
begin
  if v_src like '%0662: a web order%' then return; end if;
  -- 1 the discount a web order's code takes off
  if strpos(v_src, $r$  v_loc        uuid;
begin$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$  v_loc        uuid;
begin$r$, $r$  v_loc        uuid;
  v_disc       numeric(10,2) := 0;   -- 0662: a web order's discount code
begin$r$);
  -- 2 a dish note travels with the dish
  if strpos(v_src, $r$'qty', v_qty, 'station', v_item.station, 'course', v_item.course);$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$'qty', v_qty, 'station', v_item.station, 'course', v_item.course);$r$,
    $r$'qty', v_qty, 'station', v_item.station, 'course', v_item.course,
      'notes', nullif(left(btrim(regexp_replace(coalesce(v_line->>'notes', ''), '[[:cntrl:]]', ' ', 'g')), 140), ''));$r$);
  -- 3 the POS order: the table (dine-in) and the discount code
  if strpos(v_src, $r$                             subtotal, gst_pct, gst_amount, total, placed_by, notes, external_ref)
  values (v_org, v_loc, v_order_no, v_display, 'online', 'new', nullif(p->>'customer_name', ''), nullif(p->>'customer_phone', ''),
          v_subtotal, v_gst_pct, v_gst, v_total, 'integration', nullif(p->>'notes', ''), 'onelocal:' || v_ol_id)$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$                             subtotal, gst_pct, gst_amount, total, placed_by, notes, external_ref)
  values (v_org, v_loc, v_order_no, v_display, 'online', 'new', nullif(p->>'customer_name', ''), nullif(p->>'customer_phone', ''),
          v_subtotal, v_gst_pct, v_gst, v_total, 'integration', nullif(p->>'notes', ''), 'onelocal:' || v_ol_id)$r$,
    $r$                             subtotal, gst_pct, gst_amount, total, placed_by, notes, external_ref, table_id, coupon_code, discount_pct, discount)
  values (v_org, v_loc, v_order_no, v_display, 'online', 'new', nullif(p->>'customer_name', ''), nullif(p->>'customer_phone', ''),
          v_subtotal, v_gst_pct, v_gst, v_total, 'integration', nullif(p->>'notes', ''), 'onelocal:' || v_ol_id,
          nullif(p->>'table_id', '')::uuid, nullif(p->>'coupon_code', ''), nullif(p->>'discount_pct', '')::numeric,
          least(greatest(coalesce(nullif(p->>'discount', '')::numeric, 0), 0), v_subtotal))$r$);
  -- 4 dish notes on the POS dishes; a web order priced by the restaurant's own bill rules before anything else reads its money
  if strpos(v_src, $r$  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, station, course)
  select v_pos_id, (l->>'menu_item_id')::uuid, l->>'name', (l->>'qty')::int, (l->>'price')::numeric,
         coalesce(l->>'station', 'main'), coalesce(l->>'course', 'eat')
  from jsonb_array_elements(v_lines) l;$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, station, course)
  select v_pos_id, (l->>'menu_item_id')::uuid, l->>'name', (l->>'qty')::int, (l->>'price')::numeric,
         coalesce(l->>'station', 'main'), coalesce(l->>'course', 'eat')
  from jsonb_array_elements(v_lines) l;$r$, $r$  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, station, course, notes)
  select v_pos_id, (l->>'menu_item_id')::uuid, l->>'name', (l->>'qty')::int, (l->>'price')::numeric,
         coalesce(l->>'station', 'main'), coalesce(l->>'course', 'eat'), nullif(l->>'notes', '')
  from jsonb_array_elements(v_lines) l;

  -- 0662: a web order (the restaurant's own page) is the restaurant's bill: its GST, service charge, round off and discount code
  -- (tbl_order_reprice, the one restaurant pricing), so the customer order below carries the same money as the POS order
  if p->>'source' = 'web' then
    perform public.tbl_order_reprice(v_pos_id);
    select o.subtotal, o.discount, o.gst_amount, o.total into v_subtotal, v_disc, v_gst, v_total from public.orders o where o.id = v_pos_id;
  end if;$r$);
  -- 5 the POS event says where the order came from
  if strpos(v_src, $r$'Order ' || v_display || ' placed on One Local — ' || v_count || ' items', 'one_local',
          jsonb_build_object('source', 'one_local', 'ol_order_id', v_ol_id));$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$'Order ' || v_display || ' placed on One Local — ' || v_count || ' items', 'one_local',
          jsonb_build_object('source', 'one_local', 'ol_order_id', v_ol_id));$r$,
    $r$'Order ' || v_display || case when p->>'source' = 'web' then ' placed on the restaurant''s web page — ' else ' placed on One Local — ' end
          || v_count || ' items', 'one_local',
          jsonb_build_object('source', 'one_local', 'ol_order_id', v_ol_id, 'order_source', coalesce(nullif(p->>'source', ''), 'app'),
                             'order_mode', coalesce(nullif(p->>'order_mode', ''), 'delivery')));$r$);
  -- 6 the customer order: source, mode, table label, pickup time, the tracking hash, the store, the code
  if strpos(v_src, $r$                                organization_id, restaurant_deadline, city_id)
  values (v_ol_id, v_hash, nullif(p->>'user_id', '')::uuid, v_lines, v_subtotal, 0, v_fee, v_gst, v_total,
          'cod', 'placed', p->'delivery_address', v_key, v_pos_id, v_org, v_deadline, coalesce(p->>'city_id', 'latur'));$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$                                organization_id, restaurant_deadline, city_id)
  values (v_ol_id, v_hash, nullif(p->>'user_id', '')::uuid, v_lines, v_subtotal, 0, v_fee, v_gst, v_total,
          'cod', 'placed', p->'delivery_address', v_key, v_pos_id, v_org, v_deadline, coalesce(p->>'city_id', 'latur'));$r$,
    $r$                                organization_id, restaurant_deadline, city_id,
                                source, order_mode, table_label, pickup_at, track_hash, web_request_hash, store_id, coupon_code)
  values (v_ol_id, v_hash, nullif(p->>'user_id', '')::uuid, v_lines, v_subtotal, v_disc, v_fee, v_gst, v_total,
          'cod', 'placed', p->'delivery_address', v_key, v_pos_id, v_org, v_deadline, coalesce(p->>'city_id', 'latur'),
          coalesce(nullif(p->>'source', ''), 'app'), coalesce(nullif(p->>'order_mode', ''), 'delivery'), nullif(p->>'table_label', ''),
          nullif(p->>'pickup_at', '')::timestamptz, nullif(p->>'track_hash', ''), nullif(p->>'web_request_hash', ''),
          nullif(p->>'store_id', ''), nullif(p->>'coupon_code', ''));$r$);
  -- 7 the answer says the discount too
  if strpos(v_src, $r$'subtotal', v_subtotal, 'gst', v_gst,$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$'subtotal', v_subtotal, 'gst', v_gst,$r$, $r$'subtotal', v_subtotal, 'discount', v_disc, 'gst', v_gst,$r$);
  if v_n <> 7 or v_src not like '%0662: a web order%' then
    raise exception '0662: ol_create_restaurant_order has changed shape (% of 7 parts found); patch it by hand', v_n;
  end if;
  execute v_src;
end $$;

-- ------------------------------------------------- money: a web order is the restaurant's own sale (replace and assert)
do $$
declare v_src text := pg_get_functiondef('public.commission_quote(uuid)'::regprocedure);
begin
  if v_src not like '%ol.source = ''app''%' then
    v_src := replace(v_src, $r$if not exists (select 1 from public.ol_orders ol where ol.pos_order_id = o.id) then return; end if;$r$,
      $r$if not exists (select 1 from public.ol_orders ol where ol.pos_order_id = o.id and ol.source = 'app') then return; end if;   -- 0662: not on a web order (the restaurant's own page)$r$);
    if v_src not like '%ol.source = ''app''%' then raise exception '0662: commission_quote has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;
do $$
declare v_src text := pg_get_functiondef('public.order_money_accrue(uuid)'::regprocedure);
begin
  if v_src not like '%and source = ''app'' order by created_at limit 1%' then
    v_src := replace(v_src, $r$select * into v_ol from public.ol_orders where pos_order_id = o.id order by created_at limit 1;$r$,
      $r$select * into v_ol from public.ol_orders where pos_order_id = o.id and source = 'app' order by created_at limit 1;   -- 0662: a web order is the restaurant's own sale$r$);
    if v_src not like '%and source = ''app'' order by created_at limit 1%' then raise exception '0662: order_money_accrue has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------ web order helpers
-- the web order a guest may see: by its tracking link, or by its id with the same device
create or replace function public.ol__web_find(p jsonb, p_lock boolean default false) returns public.ol_orders
language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.ol_orders%rowtype; v_track text := btrim(coalesce(p->>'track', '')); v_id text := btrim(coalesce(p->>'order_id', ''));
  v_hash text := btrim(coalesce(p->>'customer_hash', ''));
begin
  if v_track <> '' then
    if v_track !~ '^[0-9a-f]{36}$' then raise exception 'OL_NOT_FOUND: this order link is not valid'; end if;
    if p_lock then select * into x from public.ol_orders where track_hash = public.guest__hash(v_track) and source = 'web' for update;
    else select * into x from public.ol_orders where track_hash = public.guest__hash(v_track) and source = 'web'; end if;
  elsif v_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and v_hash ~ '^[0-9a-f]{64}$' then
    if p_lock then select * into x from public.ol_orders where id = v_id::uuid and customer_hash = v_hash and source = 'web' for update;
    else select * into x from public.ol_orders where id = v_id::uuid and customer_hash = v_hash and source = 'web'; end if;
  end if;
  if x.id is null then raise exception 'OL_NOT_FOUND: this order was not found'; end if;
  return x;
end $$;

-- the guest's view of a web order: one stage from the customer order, the POS order, its dishes, a hold and a paused restaurant
create or replace function public.ol__web_order_json(x public.ol_orders) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; c public.ol_merchant_channels%rowtype; oc public.outlet_channels%rowtype;
  v_n int := 0; v_served int := 0; v_ready int := 0; v_prep int := 0; v_nokot int := 0; v_held boolean := false; v_stage text; v_label text;
  v_pause jsonb; v_acc timestamptz; v_eta int; v_bill jsonb; b jsonb; v_can boolean := false; v_paid boolean;
begin
  select * into o from public.orders where id = x.pos_order_id;
  select count(*) filter (where i.status <> 'cancelled'), count(*) filter (where i.status = 'delivered'),
         count(*) filter (where i.status in ('ready', 'delivered')), count(*) filter (where i.status = 'preparing'),
         count(*) filter (where i.status = 'pending' and i.kot_ticket_id is null)
    into v_n, v_served, v_ready, v_prep, v_nokot
    from public.order_items i where i.order_id = o.id;
  if v_prep = 0 and exists (select 1 from public.kot_tickets k where k.order_id = o.id and k.status = 'preparing') then v_prep := 1; end if;
  v_paid := o.status = 'paid' or o.paid_at is not null;
  -- held: a One Local risk hold, a POS hold for the kitchen, or dishes the restaurant has not sent to the kitchen yet
  v_held := exists (select 1 from public.ol_order_holds h where h.order_id = x.id and h.status = 'held')
         or (o.id is not null and public.pos_order_held_for_kitchen(o.id))
         or (x.status <> 'placed' and v_nokot > 0 and o.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready'));
  v_stage := case
    when x.status = 'cancelled' or o.status = 'cancelled' then
      case when x.cancel_code in ('rejected_by_partner', 'auto_cancelled', 'auto_cancelled_ghost') then 'declined' else 'cancelled' end
    when v_paid then 'paid'
    when o.status = 'awaiting_payment' then 'bill_ready'
    when x.status = 'placed' then case when v_held then 'on_hold' else 'waiting_partner' end
    when v_n > 0 and v_served = v_n then 'served'
    when o.status = 'delivered' then 'served'
    when (v_n > 0 and v_ready = v_n) or o.status = 'ready' then 'ready'
    when v_prep > 0 or v_ready > 0 then 'preparing'
    when v_held then 'on_hold'
    else 'accepted' end;
  select * into c from public.ol_merchant_channels where organization_id = x.organization_id;
  select * into oc from public.outlet_channels where location_id = o.location_id;
  if v_stage in ('waiting_partner', 'accepted', 'preparing', 'on_hold')
     and ((c.organization_id is not null and (not c.accepting or c.platform_hold)) or (oc.location_id is not null and not oc.accepting)) then
    v_pause := jsonb_build_object('reason', case when c.platform_hold then 'paused_by_one_local' when oc.location_id is not null and not oc.accepting
                                                 then coalesce(nullif(oc.paused_reason, ''), 'paused') else 'paused' end,
                                  'back_at', c.back_at);
  end if;
  v_label := case v_stage
    when 'waiting_partner' then case when v_pause is not null then 'Restaurant paused' else 'Sent' end
    when 'accepted' then 'Accepted' when 'preparing' then 'Preparing' when 'on_hold' then 'On hold'
    when 'ready' then case when x.order_mode = 'pickup' then 'Ready for pickup' else 'Ready' end
    when 'served' then case when x.order_mode = 'pickup' then 'Picked up' else 'Served' end
    when 'bill_ready' then 'Bill ready' when 'paid' then 'Paid' when 'declined' then 'Declined' else 'Cancelled' end;
  if x.status not in ('placed', 'cancelled') then
    v_acc := coalesce(x.restaurant_responded_at,
                      (select min(e.created_at) from public.order_events e where e.order_id = o.id and e.kind in ('accepted', 'kot_fired')));
  end if;
  if v_stage in ('accepted', 'preparing', 'on_hold') and x.prep_minutes is not null and v_acc is not null then
    v_eta := greatest(1, x.prep_minutes - floor(extract(epoch from (now() - v_acc)) / 60)::int);
  end if;
  v_can := v_stage in ('ready', 'served') and not v_held and v_n > 0 and v_ready = v_n and not v_paid
           and o.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready', 'delivered');
  if v_stage in ('bill_ready', 'paid') then
    b := public.rst_bill_order_json(o.id);
    v_bill := jsonb_build_object('display_no', b->'display_no',
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', l->'name', 'variant', l->'variant', 'qty', l->'qty', 'unit_price', l->'unit_price',
                  'line_total', l->'line_total')), '[]'::jsonb) from jsonb_array_elements(b->'items') l),
      'subtotal', b->'subtotal', 'discount', b->'discount', 'coupon_code', b->'coupon_code', 'gst_pct', b->'gst_pct', 'gst_amount', b->'gst_amount',
      'service_charge', b->'service_charge', 'round_off', b->'round_off', 'total', b->'total', 'paid', b->'paid', 'due', b->'due',
      'payment', case when x.order_mode = 'dine_in' then 'at_table' else 'at_counter' end);
  end if;
  return jsonb_build_object(
    'order_id', x.id, 'display_no', o.display_no, 'status', x.status, 'stage', v_stage, 'stage_label', v_label,
    'mode', x.order_mode, 'table_label', x.table_label, 'pickup_at', x.pickup_at,
    'restaurant', (select coalesce(nullif(l.public_name, ''), g.name) from public.organizations g left join public.org_listing_profiles l on l.organization_id = g.id
                    where g.id = x.organization_id),
    'placed_at', x.created_at, 'accepted_at', v_acc, 'eta_minutes', v_eta, 'held', v_held, 'restaurant_paused', v_pause,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'qty', i.qty,
                'status', case i.status when 'delivered' then 'served' when 'pending' then case when i.kot_ticket_id is null then 'waiting' else 'queued' end
                                       else i.status end) order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id),
    'total', coalesce(o.total, x.total), 'coupon_code', o.coupon_code, 'discount', coalesce(o.discount, 0),
    'bill', v_bill, 'can_request_bill', v_can);
end $$;

-- ------------------------------------------------------------------------------------------------ place
create or replace function public.ol_web_order_place(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_hash text := btrim(coalesce(p->>'customer_hash', '')); v_key text := btrim(coalesce(p->>'idempotency_key', ''));
  v_link text := lower(btrim(coalesce(p->>'store_link', ''))); v_mode text := coalesce(p->>'mode', '');
  v_phone text := regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'); v_name text; v_note text;
  v_code text := upper(nullif(btrim(coalesce(p->>'coupon_code', '')), ''));
  v_org uuid; st public.ol_stores%rowtype; v_loc uuid; v_tz text; v_live jsonb; v_reasons jsonb; s public.guest_qr_sessions%rowtype; t public.dining_tables%rowtype;
  v_at timestamptz; v_slots jsonb; v_chk jsonb; v_req text; x public.ol_orders%rowtype; v_made jsonb; v_track text; v_notes text;
  cp public.sell_coupons%rowtype; v_sub numeric(10,2); v_disc numeric(10,2); v_pct numeric; v_ckey text; o public.orders%rowtype;
begin
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'OL_BAD_REQUEST: this device is not recognised; reload the page'; end if;
  if v_key !~ '^[A-Za-z0-9_:.-]{8,200}$' then raise exception 'OL_BAD_REQUEST: the request key is missing'; end if;
  if v_mode not in ('dine_in', 'pickup') then raise exception 'OL_BAD_REQUEST: choose dine-in or pickup'; end if;
  v_req := public.guest__hash(concat_ws('|', v_link, v_mode, coalesce(p->>'table_session', ''), coalesce(p->>'pickup_at', ''),
    coalesce(p->'lines', 'null'::jsonb)::text, coalesce(p->>'guest_name', ''), v_phone, coalesce(p->>'note', ''), coalesce(v_code, '')));

  -- one request key at a time per device: the same order is answered again, never placed twice
  perform pg_advisory_xact_lock(hashtext('ol_web_order:' || v_hash || ':' || v_key));
  select * into x from public.ol_orders where customer_hash = v_hash and idempotency_key = v_key;
  if found then
    if x.source <> 'web' or x.web_request_hash is distinct from v_req then
      raise exception 'OL_IDEMPOTENCY_MISMATCH: this request key was already used for a different order'; end if;
    -- the tracking link is not kept: the device follows the order by its id
    return public.ol__web_order_json(x) || jsonb_build_object('track', null, 'replayed', true);
  end if;

  -- the restaurant: a live page, linked to a One Local store, taking orders now
  select organization_id into v_org from public.org_listing_profiles where store_slug = v_link;
  if v_org is null or cardinality(public.guest__public_blockers(v_org)) > 0 then
    raise exception 'OL_NOT_FOUND: this restaurant page is not taking orders right now'; end if;
  select * into st from public.ol_stores where organization_id = v_org and deleted_at is null order by (id = v_link) desc, created_at limit 1;
  if not found then raise exception 'OL_NOT_ONE_LOCAL: this restaurant does not take web orders yet'; end if;
  v_live := public.ol_restaurant_live(v_org);
  v_reasons := coalesce(v_live->'reasons', '[]'::jsonb);
  if v_reasons ?| array['suspended', 'not_approved', 'not_listed', 'platform_hold', 'paused', 'pos_offline', 'outside_hours'] then
    raise exception 'OL_NOT_ACCEPTING: %', case when v_reasons ? 'outside_hours' then 'the restaurant is closed now'
      when v_reasons ? 'pos_offline' then 'the restaurant is offline right now; please order with the staff'
      else 'the restaurant is not taking web orders right now' end;
  end if;

  v_name := nullif(btrim(regexp_replace(coalesce(p->>'guest_name', ''), '[[:cntrl:]]', ' ', 'g')), '');
  if char_length(v_name) > 40 then raise exception 'OL_BAD_REQUEST: a name can be up to 40 characters'; end if;
  v_note := nullif(btrim(regexp_replace(coalesce(p->>'note', ''), '[[:cntrl:]]', ' ', 'g')), '');
  if char_length(v_note) > 300 then raise exception 'OL_BAD_REQUEST: a note can be up to 300 characters'; end if;
  if char_length(v_phone) = 12 and v_phone like '91%' then v_phone := substr(v_phone, 3); end if;
  if v_phone <> '' and v_phone !~ '^[6-9][0-9]{9}$' then raise exception 'OL_BAD_REQUEST: enter a 10-digit mobile number'; end if;

  if v_mode = 'dine_in' then
    -- the table comes from the guest's QR session, never from the request
    if coalesce(p->>'table_session', '') = '' then raise exception 'OL_BAD_REQUEST: scan the table QR code to order to your table'; end if;
    begin
      s := public.guest__session(p->>'table_session');
    exception when raise_exception then
      raise exception 'OL_SESSION_EXPIRED: please scan the table code again';
    end;
    if s.organization_id is distinct from v_org then raise exception 'OL_SESSION_MISMATCH: this table code belongs to another restaurant; please scan it again'; end if;
    select * into t from public.dining_tables where id = s.table_id and organization_id = v_org;
    if not found or not t.is_active then raise exception 'OL_SESSION_EXPIRED: this table is no longer in use; please ask the staff'; end if;
    v_loc := s.location_id;
  else
    if v_phone = '' then raise exception 'OL_BAD_REQUEST: enter a 10-digit mobile number for pickup'; end if;
    begin v_at := (p->>'pickup_at')::timestamptz; exception when others then raise exception 'OL_BAD_REQUEST: pick a pickup time'; end;
    begin
      v_slots := public.gx_preorder_slots(jsonb_build_object('slug', v_link));
    exception when raise_exception then
      raise exception 'OL_BAD_REQUEST: this restaurant does not take pickup orders right now';
    end;
    if v_at is null or not exists (select 1 from jsonb_array_elements(v_slots->'days') dd, jsonb_array_elements_text(dd->'slots') sl where sl::timestamptz = v_at) then
      raise exception 'OL_BAD_REQUEST: that pickup time is not available any more, pick another'; end if;
    v_loc := (public.guest__public_outlet(v_org)).id;
  end if;
  if not exists (select 1 from public.outlet_channels c join public.locations l on l.id = c.location_id
                  where c.location_id = v_loc and c.organization_id = v_org and c.accepting and l.status = 'active') then
    raise exception 'OL_NOT_ACCEPTING: this outlet is not taking web orders right now'; end if;

  -- the dishes: what the guest page offers right now (published, in stock, on for the table QR, in its serving hours)
  begin
    v_chk := public.guest__lines(v_org, v_loc, p->'lines');
  exception when raise_exception then
    if sqlerrm like 'GUEST\_%' then raise exception '%', regexp_replace(sqlerrm, '^GUEST_', 'OL_'); end if;
    raise;
  end;

  -- a discount code: the coupon rules the restaurant bill uses (rst_bill_coupon): active, dates, minimum, use limits
  if v_code is not null then
    select * into cp from public.sell_coupons where organization_id = v_org and upper(code) = v_code and active
      and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
    if not found then raise exception 'OL_COUPON_UNKNOWN: this discount code is not valid'; end if;
    v_sub := (v_chk->>'estimated_total')::numeric;
    if v_sub < cp.min_order then raise exception 'OL_COUPON_MIN: this code needs an order of at least ₹%', trim(to_char(cp.min_order, 'FM9999990.00')); end if;
    if cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = cp.id and released_at is null) >= cp.max_uses then
      raise exception 'OL_COUPON_LIMIT: this code has been used up'; end if;
    v_ckey := nullif(right(v_phone, 10), '');
    if cp.max_uses_per_customer is not null then
      if v_ckey is null then raise exception 'OL_COUPON_CUSTOMER: this code is limited per customer; enter your mobile number'; end if;
      if (select count(*) from public.sell_coupon_redemptions where coupon_id = cp.id and customer_key = v_ckey and released_at is null) >= cp.max_uses_per_customer then
        raise exception 'OL_COUPON_LIMIT: you have already used this code'; end if;
    end if;
    v_pct := case when cp.kind = 'percent' then cp.value end;
    v_disc := case when cp.kind = 'percent' then round(v_sub * cp.value / 100, 2) else cp.value end;
    if cp.max_discount is not null then v_disc := least(v_disc, cp.max_discount); end if;
    v_disc := least(v_disc, v_sub);
  end if;

  select coalesce(timezone, 'Asia/Kolkata') into v_tz from public.locations where id = v_loc;
  v_notes := concat_ws(' · ', 'Web order', case when v_mode = 'dine_in' then 'dine-in, table ' || t.label
                                                else 'pickup ' || to_char(v_at at time zone coalesce(v_tz, 'Asia/Kolkata'), 'DD Mon HH24:MI') end,
                       case when v_phone <> '' then 'phone ' || v_phone end, v_note);
  v_track := encode(extensions.gen_random_bytes(18), 'hex');
  v_made := public.ol_create_restaurant_order(jsonb_build_object(
    'organization_id', v_org, 'customer_hash', v_hash, 'idempotency_key', v_key, 'location_id', v_loc, 'city_id', st.city_id,
    'customer_name', v_name, 'customer_phone', nullif(v_phone, ''), 'notes', v_notes, 'delivery_fee', 0,
    'lines', (select jsonb_agg(jsonb_build_object('menu_item_id', l->'menu_item_id', 'qty', l->'qty', 'notes', l->'notes')) from jsonb_array_elements(v_chk->'lines') l),
    'source', 'web', 'order_mode', v_mode, 'table_id', t.id, 'table_label', t.label, 'pickup_at', v_at,
    'track_hash', public.guest__hash(v_track), 'web_request_hash', v_req, 'store_id', st.id,
    'coupon_code', cp.code, 'discount_pct', v_pct, 'discount', v_disc));

  if v_code is not null then
    select * into o from public.orders where id = (v_made->>'pos_order_id')::uuid;
    if o.coupon_code is null or o.discount <= 0 then raise exception 'OL_COUPON_UNKNOWN: this code takes nothing off this order'; end if;
    if o.total <= 0 then raise exception 'OL_COUPON_ZERO: this code would make the order free; please ask the staff'; end if;
    update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = cp.id;
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, cp.id, o.id, v_ckey);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'coupon_applied', 'Discount code ' || cp.code || ' took ' || o.discount || ' off ' || o.display_no || ' (web order)', 'guest',
            jsonb_build_object('coupon_id', cp.id, 'discount', o.discount, 'new_total', o.total, 'ol_order_id', v_made->>'ol_order_id'));
  end if;

  select * into x from public.ol_orders where id = (v_made->>'ol_order_id')::uuid;
  return public.ol__web_order_json(x) || jsonb_build_object('track', v_track, 'replayed', false);
end $$;

-- ------------------------------------------------------------------------------------------------ status and bill
create or replace function public.ol_web_order_status(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  return public.ol__web_order_json(public.ol__web_find(p));
end $$;

create or replace function public.ol_web_order_bill(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.ol_orders%rowtype := public.ol__web_find(p, true); o public.orders%rowtype; j jsonb;
begin
  select * into o from public.orders where id = x.pos_order_id for update;
  if not found then raise exception 'OL_NOT_FOUND: this order was not found'; end if;
  if o.status in ('awaiting_payment', 'paid') or o.paid_at is not null then
    return public.ol__web_order_json(x) || jsonb_build_object('already', true);   -- asked before (or paid): the same bill
  end if;
  if x.status = 'cancelled' or o.status = 'cancelled' then raise exception 'OL_WRONG_STATE: this order was cancelled'; end if;
  if x.status = 'placed' then raise exception 'OL_BILL_NOT_YET: the restaurant has not accepted the order yet'; end if;
  j := public.ol__web_order_json(x);
  if not coalesce((j->>'can_request_bill')::boolean, false) then
    raise exception 'OL_BILL_NOT_YET: you can ask for the bill once every dish is ready or served'; end if;
  perform public.status_gate('orders', o.id, 'set_awaiting_payment');
  update public.orders set status = 'awaiting_payment', updated_at = now() where id = o.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (o.organization_id, o.id, 'bill_requested', 'The guest asked for the bill for ' || o.display_no || ' (web order)', 'guest',
          jsonb_build_object('ol_order_id', x.id, 'mode', x.order_mode, 'table_label', x.table_label));
  return public.ol__web_order_json(x) || jsonb_build_object('already', false);
end $$;

-- ------------------------------------------------------------------------------------------------ offers on the guest page
-- live discount codes (they work on a web order) and the storefront offers the restaurant chose to show (shown, not a code)
create or replace function public.gx__offers(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.sort, x.ends_at nulls last), '[]'::jsonb) from (
    select 0 as sort, c.ends_at, jsonb_build_object('id', c.id::text, 'source', 'coupon',
             'title', coalesce(nullif(btrim(c.label), ''), case c.kind when 'percent' then trim(to_char(c.value, 'FM990.##')) || '% off'
                                                                       else '₹' || trim(to_char(c.value, 'FM9999990.##')) || ' off' end),
             'code', c.code, 'kind', c.kind, 'value', c.value, 'min_order', c.min_order, 'max_discount', c.max_discount, 'ends_at', c.ends_at) as j
      from public.sell_coupons c
     where c.organization_id = p_org and c.active and (c.starts_at is null or c.starts_at <= now()) and (c.ends_at is null or c.ends_at > now())
       and (c.max_uses is null or (select count(*) from public.sell_coupon_redemptions r where r.coupon_id = c.id and r.released_at is null) < c.max_uses)
    union all
    select 1, o.end_date, jsonb_build_object('id', o.id, 'source', 'offer', 'title', o.title, 'code', null, 'kind', r.discount_type,
             'value', r.discount_value, 'min_order', o.min_order, 'max_discount', nullif(o.max_discount, 0), 'ends_at', o.end_date, 'message', r.message)
      from public.pos_offers o join public.pos_offer_rules r on r.organization_id = o.organization_id and r.offer_id = o.id
     where o.organization_id = p_org and o.deleted_at is null and o.status = 'active' and r.show_on_storefront
       and (o.start_date is null or o.start_date <= now()) and (o.end_date is null or o.end_date > now())
    limit 12) x;
$$;

do $$
declare v_src text := pg_get_functiondef('public.guest__menu'::regproc);
begin
  if v_src not like '%''offers'', public.gx__offers(p_org)%' then
    v_src := replace(v_src, $r$'experience', public.gx__public_def(p_org));$r$, $r$'experience', public.gx__public_def(p_org),
    'offers', public.gx__offers(p_org));$r$);
    if v_src not like '%''offers'', public.gx__offers(p_org)%' then raise exception '0662: guest__menu has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------ live feed
-- what the restaurant's guests ordered in the last 20 minutes: dish, quantity, table label, how long ago, category. No names, phones or money.
create or replace function public.gx_live_feed(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_slug text := lower(btrim(coalesce(p->>'slug', ''))); v_org uuid; v_items jsonb; v_streaks jsonb;
begin
  select organization_id into v_org from public.org_listing_profiles where store_slug = v_slug;
  if v_org is null or cardinality(public.guest__public_blockers(v_org)) > 0 then raise exception 'GUEST_NOT_FOUND: this page is not available right now.'; end if;
  with it as materialized (
    select i.menu_item_id, i.name, i.qty, i.created_at, o.table_id, t.label as table_label, coalesce(c.name, 'Other') as category
      from public.orders o
      join public.order_items i on i.order_id = o.id
      left join public.dining_tables t on t.id = o.table_id
      left join public.menu_items m on m.id = i.menu_item_id
      left join public.menu_categories c on c.id = m.category_id
     where o.organization_id = v_org and o.created_at > now() - interval '12 hours' and o.status <> 'cancelled'
       and i.status <> 'cancelled' and i.created_at > now() - interval '20 minutes'
       and not (i.unit_price = 0 and coalesce(i.notes, '') like 'Combo: %')
  )
  select (select coalesce(jsonb_agg(jsonb_build_object('name', f.name, 'qty', f.qty, 'table_label', f.table_label,
                   'seconds_ago', greatest(0, floor(extract(epoch from (now() - f.created_at))))::int, 'category', f.category) order by f.created_at desc), '[]'::jsonb)
            from (select * from it order by created_at desc limit 30) f),
         (select coalesce(jsonb_agg(s.j order by s.n desc, s.kind_sort, s.label), '[]'::jsonb) from (
            select d.n, 0 as kind_sort, d.label, jsonb_build_object('label', d.n || ' tables ordered ' || d.name, 'count', d.n, 'kind', 'dish', 'name', d.name) as j
              from (select min(name) as name, count(distinct table_id) as n, min(name) as label from it where table_id is not null
                     group by coalesce(menu_item_id::text, name) having count(distinct table_id) >= 2) d
            union all
            select k.n, 1, k.category, jsonb_build_object('label', k.n || ' ' || k.category || ' ordered', 'count', k.n, 'kind', 'category', 'name', k.category)
              from (select category, sum(qty)::int as n from it group by category having sum(qty) >= 3) k
            order by 1 desc limit 5) s)
    into v_items, v_streaks;
  return jsonb_build_object('items', v_items, 'streaks', v_streaks, 'window_minutes', 20);
end $$;

-- ------------------------------------------------------------------- rst_channel_orders: web orders (replace and assert)
do $$
declare v_src text := pg_get_functiondef('public.rst_channel_orders(jsonb)'::regprocedure); v_n int := 0;
begin
  if v_src like '%0662: a web order%' then return; end if;
  if strpos(v_src, $r$o.external_ref, o.customer_phone,$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$o.external_ref, o.customer_phone,$r$, $r$o.external_ref, o.customer_phone, x.order_mode as web_mode, x.table_label, x.pickup_at,$r$);
  if strpos(v_src, $r$case when x.id is not null or o.channel = 'online' then 'onelocal'$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$case when x.id is not null or o.channel = 'online' then 'onelocal'$r$,
    $r$case when x.source = 'web' then 'web' when x.id is not null or o.channel = 'online' then 'onelocal'$r$);
  if strpos(v_src, $r$               when x.id is not null then case x.status when 'placed' then 'new'$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$               when x.id is not null then case x.status when 'placed' then 'new'$r$,
    $r$               -- 0662: a web order (dine-in or pickup) follows its POS order once accepted: kitchen, ready, bill, paid
               when x.source = 'web' then case when x.status = 'placed' then 'new' else case o.status when 'new' then 'new' when 'in_billing' then 'new'
                 when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready' when 'awaiting_payment' then 'ready' else 'delivered' end end
               when x.id is not null then case x.status when 'placed' then 'new'$r$);
  if strpos(v_src, $r$values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2)$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2)$r$,
    $r$values ('onelocal', 'OneLocal', 1.0), ('web', 'Web', 1.5), ('swiggy', 'Swiggy', 2)$r$);
  if strpos(v_src, $r$          'held', o.held
        ) order by$r$) > 0 then v_n := v_n + 1; end if;
  v_src := replace(v_src, $r$          'held', o.held
        ) order by$r$, $r$          'held', o.held,
          -- 0662: a web order from the restaurant's own page: dine-in at a table, or a pickup time
          'mode', o.web_mode, 'table_label', o.table_label, 'pickup_at', o.pickup_at
        ) order by$r$);
  if v_n <> 5 or v_src not like '%0662: a web order%' then raise exception '0662: rst_channel_orders has changed shape (% of 5 parts found); patch it by hand', v_n; end if;
  execute v_src;
end $$;

-- ------------------------------------------------------------------------------------------------------------ grants
revoke all on function public.ol_web_order_place(jsonb), public.ol_web_order_status(jsonb), public.ol_web_order_bill(jsonb),
  public.gx_live_feed(jsonb) from public, anon, authenticated;
grant execute on function public.ol_web_order_place(jsonb), public.ol_web_order_status(jsonb), public.ol_web_order_bill(jsonb),
  public.gx_live_feed(jsonb) to service_role;
revoke all on function public.ol__web_find(jsonb, boolean), public.ol__web_order_json(public.ol_orders), public.gx__offers(uuid)
  from public, anon, authenticated;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0662_web_orders.sql', 'Web orders through the customer server: ol_orders source/mode/table/pickup/track, ol_web_order_place/status/bill, Web on the Orders board, offers in the guest menu, gx_live_feed; web orders accrue no marketplace money and never ask for a rider (local dev DB 2026-11-05)')
on conflict do nothing;

commit;
