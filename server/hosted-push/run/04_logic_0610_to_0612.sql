-- ==========================================================================================================================
-- HOSTED PUSH piece 04 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0610_accept_orders.sql
-- 0610: accept delivery orders within a minute, and auto-accept (founder, 28 Oct 2026). Safe to run again.
--   * ol_merchant_channels.auto_accept (default off): when on, the Orders screen accepts each new order as it arrives.
--     The accept window is the existing accept_window_seconds (60 by default).
--   * rst_channel_accept({order_id}): accepts one new delivery order. A held POS order is sent to the kitchen (tbl_kot_fire, its KOT);
--     a OneLocal app order is also marked accepted (the customer's order moves on through the status gate). Safe to repeat.
--   * rst_auto_accept_set({on}): turns auto-accept on or off (a manager or owner).
--   * rst_channel_orders (0607) also answers accept_window and auto_accept.


alter table public.ol_merchant_channels add column if not exists auto_accept boolean not null default false;

create or replace function public.rst_channel_accept(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; v_kot jsonb; v_done boolean := false;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot accept orders'; end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  -- the kitchen gets it (a held order has no KOT yet)
  if o.status in ('new', 'in_billing') then
    v_kot := public.tbl_kot_fire(o.id);
    v_done := true;
  end if;
  -- a OneLocal app order: the customer's order is accepted too
  if x.id is not null and x.status = 'placed' then
    perform public.status_gate('ol_orders', x.id, 'restaurant_accept');
    update public.ol_orders set status = 'accepted', prep_minutes = coalesce(x.prep_minutes, 20), eta_minutes = coalesce(x.prep_minutes, 20) + 15 where id = x.id;
    v_done := true;
  end if;
  if v_done then
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'accepted', o.display_no || ' accepted' || case when coalesce((p->>'auto')::boolean, false) then ' automatically' else '' end, 'pos',
            jsonb_build_object('by', auth.uid(), 'auto', coalesce((p->>'auto')::boolean, false)));
  end if;
  return jsonb_build_object('order_id', o.id, 'accepted', true, 'already', not v_done, 'kot', v_kot);
end $$;

create or replace function public.rst_auto_accept_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_on boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager']) then
    raise exception 'POS_FORBIDDEN: only a manager can change auto-accept'; end if;
  begin v_on := (p->>'on')::boolean; exception when others then v_on := null; end;
  if v_on is null then raise exception 'POS_BAD_REQUEST: on is true or false'; end if;
  insert into public.ol_merchant_channels (organization_id, auto_accept, updated_by, updated_at) values (v_org, v_on, auth.uid(), now())
  on conflict (organization_id) do update set auto_accept = excluded.auto_accept, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('auto_accept', v_on);
end $$;

revoke all on function public.rst_channel_accept(jsonb) from public, anon;
grant execute on function public.rst_channel_accept(jsonb) to authenticated, service_role;
revoke all on function public.rst_auto_accept_set(jsonb) from public, anon;
grant execute on function public.rst_auto_accept_set(jsonb) to authenticated, service_role;

create or replace function public.rst_channel_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name, ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$;


-- ---- 0611_dish_sizes.sql
-- 0611: sizes for dishes (founder, 28 Oct 2026): Small, Medium and Large for the beverages, each with its own price, shown on the menu and
-- carried through every order. Sizes live in menu_item_variants (name, price, is_default, sort_order), which the menu already counted.
--   * pos_place_order / tbl_order_add: a line may carry "variant_id"; the line is priced at that size and keeps its name (order_items.variant_name).
--     A size that is not the dish's is refused. Without a size, a dish is priced as before.
--   * pos_sell_catalog (the Bill's menu): each dish answers its sizes.
--   * rst_menu (the Menu tab): each dish answers its sizes with prices.
--   * pos_order_view, pos_order_json, rst_channel_orders: a dish reads "Americano (Large)".
-- The kitchen card, the table's order and the bill already show the size (they read variant_name). The functions below are the live
-- definitions with only those changes. Safe to run again.


CREATE OR REPLACE FUNCTION public.pos_place_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_org uuid := (p->>'organization_id')::uuid; v_key text := nullif(p->>'idempotency_key','');
  v_channel text := p->>'service_type'; v_placed_by text := coalesce(nullif(p->>'placed_by',''),'pos');
  v_qty int; v_line jsonb; v_item public.menu_items%rowtype; v_sub numeric(10,2) := 0; v_n int := 0;
  v_cfg public.org_bill_settings%rowtype; v_gst_pct numeric; v_gst numeric(10,2); v_sc numeric(10,2) := 0; v_waived numeric(10,2) := 0;
  v_raw numeric(10,2); v_total numeric(10,2); v_round numeric(10,2) := 0; v_disc numeric(10,2) := 0;
  v_table public.dining_tables%rowtype; v_loc uuid; v_no bigint; v_display text; v_id uuid; v_status text; v_kot uuid; v_ex uuid;
  v_waive boolean := coalesce((p->>'waive_service_charge')::boolean, false);
  v_code text; v_cp public.sell_coupons%rowtype; v_ckey text;
begin
  if auth.uid() is null or v_org is null or v_org is distinct from public.current_org_id() then raise exception 'POS_FORBIDDEN: not your organization'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','biller','captain','business_manager','location_manager','operations_manager']) then
    raise exception 'POS_FORBIDDEN: your role cannot place orders'; end if;
  if v_channel not in ('dine_in','pickup','delivery') then raise exception 'POS_BAD_REQUEST: unknown service type'; end if;
  if v_placed_by not in ('pos','captain','guest','integration') then raise exception 'POS_BAD_REQUEST: unknown placed_by'; end if;
  if v_key is not null then
    select id into v_ex from public.orders where organization_id = v_org and idempotency_key = v_key;
    if found then return public.pos_order_json(v_ex) || jsonb_build_object('replayed', true); end if;
  end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'POS_EMPTY: add between 1 and 50 lines'; end if;
  v_code := upper(nullif(btrim(coalesce(p->>'coupon_code', '')), ''));

  if nullif(p->>'table_id','') is not null then
    select * into v_table from public.dining_tables where id = (p->>'table_id')::uuid and organization_id = v_org and is_active;
    if not found then raise exception 'POS_BAD_TABLE: table not found'; end if;
    v_loc := v_table.location_id;
  elsif v_channel = 'dine_in' then raise exception 'POS_BAD_TABLE: choose a table for a dine-in order'; end if;
  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;

  select * into v_cfg from public.org_bill_settings where organization_id = v_org;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    v_qty := (v_line->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'POS_BAD_QTY: quantities must be 1 to 99'; end if;
    select * into v_item from public.menu_items where id = (v_line->>'menu_item_id')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'POS_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name,'an item'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'POS_BAD_VARIANT: choose a size of %', v_item.name; end if;
    v_sub := v_sub + coalesce((select mv.price from public.menu_item_variants mv where mv.id = nullif(v_line->>'variant_id', '')::uuid and mv.menu_item_id = v_item.id), v_item.price) * v_qty; v_n := v_n + v_qty;
  end loop;

  -- 0380: a coupon code takes money off the bill. The rules live in sell_coupons; the discount is worked out here, never by the app.
  if v_code is not null then
    select * into v_cp from public.sell_coupons where organization_id = v_org and upper(code) = v_code and active
      and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
    if not found then raise exception 'POS_COUPON_UNKNOWN: this coupon code is not valid'; end if;
    if v_sub < v_cp.min_order then raise exception 'POS_COUPON_MIN: this coupon needs a bill of at least %', v_cp.min_order; end if;
    v_disc := case v_cp.kind when 'percent' then round(v_sub * v_cp.value / 100, 2) else v_cp.value end;
    if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if;
    v_disc := least(v_disc, v_sub);
    -- use limits, counted under the coupon row's lock (the select above), so two tills cannot both take the last use
    v_ckey := nullif(right(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), 10), '');   -- the last 10 digits, so +91 and 0 prefixes do not make a second customer
    if v_cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and released_at is null) >= v_cp.max_uses then
      raise exception 'POS_COUPON_LIMIT: this coupon has been used up'; end if;
    if v_cp.max_uses_per_customer is not null then
      if v_ckey is null then raise exception 'POS_COUPON_CUSTOMER: this coupon is limited per customer; enter the customer''s mobile number'; end if;
      if (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and customer_key = v_ckey and released_at is null) >= v_cp.max_uses_per_customer then
        raise exception 'POS_COUPON_LIMIT: this customer has already used this coupon'; end if;
    end if;
    update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = v_cp.id;
  end if;

  -- 0371: a shop that is not GST-registered charges no GST; when menu prices already include GST, the tax is taken out of them, not added on top
  v_gst_pct := case when v_cfg.gst_registered is false then 0 else v_cfg.sgst_pct + v_cfg.cgst_pct end;
  if coalesce(v_cfg.prices_include_tax, false) and v_gst_pct > 0 then
    v_gst := round((v_sub - v_disc) * v_gst_pct / (100 + v_gst_pct), 2);
    v_sub := v_sub - v_gst;   -- subtotal is stored before tax, so subtotal + GST still equals what the menu showed
  else
    v_gst := round((v_sub - v_disc) * v_gst_pct / 100, 2);
  end if;
  v_sc := round((v_sub - v_disc) * v_cfg.service_charge_pct / 100, 2);
  if v_waive then
    if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can remove the service charge'; end if;
    if coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
    v_waived := v_sc; v_sc := 0;
  end if;
  v_raw := v_sub - v_disc + v_gst + v_sc;
  v_total := case when v_cfg.round_off_enabled then round(v_raw) else v_raw end; v_round := v_total - v_raw;

  -- a coupon that makes the bill free is refused: a bill with nothing to pay cannot be completed at the counter
  if v_code is not null and v_total <= 0 then raise exception 'POS_COUPON_ZERO: this coupon would make the bill free; use a smaller discount'; end if;

  v_no := public.next_org_seq(v_org, 'order'); v_display := 'P-' || lpad(v_no::text, 5, '0');
  v_status := case when coalesce((p->>'fire_kot')::boolean, true) then 'sent_to_kitchen' else 'in_billing' end;
  insert into public.orders (organization_id, location_id, order_no, display_no, channel, status, table_id, customer_name, customer_phone, captain_name,
      subtotal, discount, gst_pct, gst_amount, service_charge, round_off, total, placed_by, guest_count, notes, idempotency_key,
      service_charge_waived, service_charge_waived_amount, waive_reason, created_by, coupon_code)
  values (v_org, v_loc, v_no, v_display, v_channel, v_status, v_table.id, nullif(p->>'customer_name',''), nullif(p->>'customer_phone',''), null,
      v_sub, v_disc, v_gst_pct, v_gst, v_sc, v_round, v_total, v_placed_by, coalesce(nullif(p->>'guest_count','')::int, 1), nullif(p->>'notes',''), v_key,
      v_waive, v_waived, case when v_waive then p->>'waive_reason' end, auth.uid(), case when v_disc > 0 then v_cp.code end)
  returning id into v_id;
  if v_code is not null and v_disc > 0 then
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, v_cp.id, v_id, v_ckey);
  end if;
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name)
  select v_id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price), nullif(l->>'notes',''), coalesce(mi.station,'main'), coalesce(mi.course,'eat'), mv.name
  from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid
  left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values
    (v_org, v_id, 'placed', 'Order ' || v_display || ' placed - ' || v_n || ' items', v_placed_by, jsonb_build_object('by', auth.uid()));
  if v_status = 'sent_to_kitchen' then
    insert into public.kot_tickets (organization_id, order_id, kot_no, station, status) values (v_org, v_id, public.next_org_seq(v_org,'kot'), 'main', 'new') returning id into v_kot;
    update public.order_items set kot_ticket_id = v_kot where order_id = v_id;
    insert into public.order_events (organization_id, order_id, kind, message, actor) values (v_org, v_id, 'kot_fired', 'KOT fired for ' || v_display, v_placed_by);
  end if;
  if v_waive then insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, v_id, 'service_charge_waived', 'Service charge removed: ' || (p->>'waive_reason'), v_placed_by, jsonb_build_object('amount', v_waived, 'by', auth.uid())); end if;
  return public.pos_order_json(v_id) || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'TBL_BAD_REQUEST: choose a size of %', v_item.name; end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name)
    select o.id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price), nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat'), mv.name
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org
      left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id;
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_res jsonb;
begin
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id()
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(v_o) - 'external_ref' - 'idempotency_key' - 'created_by',
    'table_label', (select t.label from public.dining_tables t where t.id = v_o.table_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'takeaway', i.is_takeaway, 'qty', i.qty,
                'unit_price', i.unit_price, 'status', i.status, 'picked_qty', l.picked_qty, 'missing_qty', l.missing_qty) order by i.created_at, i.id), '[]'::jsonb)
              from public.order_items i left join public.pos_fulfilment_lines l on l.order_item_id = i.id where i.order_id = v_o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', y.method, 'amount', y.amount, 'tendered', c.tendered, 'created_at', y.created_at) order by y.created_at), '[]'::jsonb)
                 from public.payments y left join public.pos_cash_tenders c on c.payment_id = y.id where y.order_id = v_o.id),
    'paid', (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id),
    'fulfilment', (select to_jsonb(f) - 'organization_id' from public.pos_fulfilments f where f.order_id = v_o.id),
    'next_events', (select coalesce(jsonb_agg(t.event order by t.event), '[]'::jsonb) from public.order_transitions t join public.pos_fulfilments f on f.order_id = v_o.id
                    where t.entity = 'pos_fulfilments' and t.from_status = f.stage and t.event <> 'cancel'),
    'online', (select jsonb_build_object('id', x.id, 'status', x.status, 'payment_method', x.payment_method, 'payment_status', x.payment_status,
                 'address', x.delivery_address, 'cancel_reason', x.cancel_reason, 'rider_name', x.rider_name, 'eta_minutes', x.eta_minutes)
               from public.ol_orders x where x.pos_order_id = v_o.id limit 1),
    'refunded', (select coalesce(sum(r.amount), 0) from public.ol_refunds r join public.ol_orders x on x.id = r.order_id where x.pos_order_id = v_o.id and r.status = 'processed'),
    'cancel_reason', (select e.meta->>'reason' from public.order_events e where e.order_id = v_o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_jsonb(o) - 'external_ref' - 'idempotency_key'
    || jsonb_build_object(
      'table', (select jsonb_build_object('id', t.id, 'label', t.label, 'seats', t.seats) from public.dining_tables t where t.id = o.table_id),
      'order_items', (select coalesce(jsonb_agg(jsonb_build_object('menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'qty', i.qty,
                       'unit_price', i.unit_price, 'notes', i.notes, 'status', i.status) order by i.created_at), '[]'::jsonb) from public.order_items i where i.order_id = o.id),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('amount', p.amount, 'method', p.method)), '[]'::jsonb) from public.payments p where p.order_id = o.id),
      'paid', (select coalesce(sum(p.amount), 0) from public.payments p where p.order_id = o.id))
  from public.orders o where o.id = p_order;
$function$

;

CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $function$

;


-- ---- 0629_order_view_keeps_packed_photo.sql
-- 0629: one order's page (pos_order_view) as both sides changed it since 26 Oct 2026, merged:
--   * the store team (on hosted, "packed photo"): the packed-bag photo or why there is none, and whether the store asks for one;
--   * 0606 / 0611 (restaurant): each dish's name with its size, and whether it is a takeaway dish.
-- Only where the packed-photo tables exist (hosted); elsewhere the 0611 version stays.
do $do$
begin
  if to_regclass('public.order_packed_photos') is null or to_regclass('public.rr_store_settings') is null then
    raise notice '0629: no packed-photo tables here; pos_order_view left as it is';
    return;
  end if;
  execute $sql$
CREATE OR REPLACE FUNCTION public.pos_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_res jsonb;
begin
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id()
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(v_o) - 'external_ref' - 'idempotency_key' - 'created_by',
    'table_label', (select t.label from public.dining_tables t where t.id = v_o.table_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'takeaway', i.is_takeaway, 'qty', i.qty,
                'unit_price', i.unit_price, 'status', i.status, 'picked_qty', l.picked_qty, 'missing_qty', l.missing_qty) order by i.created_at, i.id), '[]'::jsonb)
              from public.order_items i left join public.pos_fulfilment_lines l on l.order_item_id = i.id where i.order_id = v_o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', y.method, 'amount', y.amount, 'tendered', c.tendered, 'created_at', y.created_at) order by y.created_at), '[]'::jsonb)
                 from public.payments y left join public.pos_cash_tenders c on c.payment_id = y.id where y.order_id = v_o.id),
    'paid', (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id),
    'fulfilment', (select to_jsonb(f) - 'organization_id' from public.pos_fulfilments f where f.order_id = v_o.id),
    'next_events', (select coalesce(jsonb_agg(t.event order by t.event), '[]'::jsonb) from public.order_transitions t join public.pos_fulfilments f on f.order_id = v_o.id
                    where t.entity = 'pos_fulfilments' and t.from_status = f.stage and t.event <> 'cancel'),
    'online', (select jsonb_build_object('id', x.id, 'status', x.status, 'payment_method', x.payment_method, 'payment_status', x.payment_status,
                 'address', x.delivery_address, 'cancel_reason', x.cancel_reason, 'rider_name', x.rider_name, 'eta_minutes', x.eta_minutes)
               from public.ol_orders x where x.pos_order_id = v_o.id limit 1),
    'refunded', (select coalesce(sum(r.amount), 0) from public.ol_refunds r join public.ol_orders x on x.id = r.order_id where x.pos_order_id = v_o.id and r.status = 'processed'),
    'cancel_reason', (select e.meta->>'reason' from public.order_events e where e.order_id = v_o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1),
    -- packed-order photos (0029 packed photo): the latest photo or the reason there is none, and whether the store asks for one
    'packed_photo', (select jsonb_build_object('id', ph.id, 'has_photo', ph.path is not null, 'skip_reason', ph.skip_reason, 'at', ph.created_at)
                     from public.order_packed_photos ph where ph.order_id = v_o.id order by ph.created_at desc limit 1),
    'photo_required', coalesce((select s.dispatch_photo from public.rr_store_settings s where s.organization_id = v_o.organization_id), true),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

  $sql$;
end $do$;

-- ---- 0612_size_recipes.sql
-- 0612: a size uses its recipe that many times (founder, 28 Oct 2026). The recipe on a dish is its Small; a size carries recipe_factor,
-- e.g. Small 1, Medium 2 (two Smalls), Large 3 (three Smalls). Safe to run again.
--   * menu_item_variants.recipe_factor (default 1, 0 to 20).
--   * order_stock_consume: a line of a size takes recipe x factor from stock when it goes to the kitchen (the line keeps its size's name).
--   * sell_return_restock: a returned line of a size puts recipe x factor back.
--   * pos_sell_catalog: each size answers its factor and how many of it can be made (the dish's count / factor, rounded down).
--   * rst_menu: each size answers its factor.
-- The functions below are the live definitions with only those changes.


alter table public.menu_item_variants add column if not exists recipe_factor numeric(6,2) not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'menu_item_variants_recipe_factor_check') then
    alter table public.menu_item_variants add constraint menu_item_variants_recipe_factor_check check (recipe_factor > 0 and recipe_factor <= 20);
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; r record; v_done numeric; v_seq integer; v_n integer := 0; v_k integer;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.status not in ('sent_to_kitchen', 'ready', 'paid', 'delivered') then return 0; end if;
  -- an order already reversed (cancelled earlier in this transaction) never consumes again
  if exists (select 1 from public.stock_movements where ref_type = 'orders' and (ref_id = p_order::text or ref_id like p_order::text || '#%') and kind = 'sale_reversal') then return 0; end if;
  -- one consumer per order at a time
  perform pg_advisory_xact_lock(hashtextextended('order_stock:' || p_order::text, 400));
  -- What the order needs per stock item, against what the ledger already took for it. The first consumption writes one row per item
  -- (ref_id = the order id); a line added or increased later is consumed as a further row for just the difference (ref_id = order id#n), so
  -- it is consumed once and a repeat run adds nothing (H-06). Cancel puts back every row, whichever consumption wrote it.
  for r in
    select rc.inventory_item_id, round(sum(oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100)), 3) as need
      from public.order_items oi
      join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
     where oi.order_id = o.id and oi.status <> 'cancelled'
     group by rc.inventory_item_id
  loop
    select coalesce(-sum(quantity), 0), count(*) into v_done, v_seq from public.stock_movements
     where ref_type = 'orders' and kind = 'sale' and inventory_item_id = r.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
    continue when r.need - v_done <= 0;
    insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
    values (o.organization_id, o.location_id, r.inventory_item_id, 'sale', -(r.need - v_done), 'orders',
            case when v_seq = 0 then o.id::text else o.id::text || '#' || v_seq end, o.display_no, o.created_by)
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  return v_n;
end $function$

;

CREATE OR REPLACE FUNCTION public.sell_return_restock(p_return uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.sell_returns%rowtype; o public.orders%rowtype; l record; rc record; v_sold numeric; v_back numeric; v_qty numeric; v_left numeric; v_take numeric;
  v_mid bigint; a record; v_bin uuid; v_n int := 0; v_expired boolean;
begin
  select * into r from public.sell_returns where id = p_return;
  select * into o from public.orders where id = r.order_id;
  if not found or o.location_id is null then return 0; end if;
  for l in select sl.id, sl.qty, i.menu_item_id, coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = i.menu_item_id and mv.name = i.variant_name limit 1), 1) as factor from public.sell_return_lines sl join public.order_items i on i.id = sl.order_item_id where sl.return_id = r.id and sl.restock loop
    for rc in select inventory_item_id, qty_per_unit from public.menu_item_recipes where menu_item_id = l.menu_item_id and organization_id = r.organization_id loop
      select coalesce(-sum(quantity), 0) into v_sold from public.stock_movements
       where ref_type = 'orders' and kind = 'sale' and inventory_item_id = rc.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
      continue when v_sold <= 0;
      select coalesce(sum(m.quantity), 0) into v_back from public.stock_movements m
       where m.ref_type = 'sell_returns' and m.kind = 'sale_reversal' and m.inventory_item_id = rc.inventory_item_id
         and m.ref_id in (select x.id::text from public.sell_return_lines x join public.sell_returns y on y.id = x.return_id where y.order_id = o.id);
      v_qty := least(round(l.qty * l.factor * rc.qty_per_unit, 3), v_sold - v_back);
      continue when v_qty <= 0;
      insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
      values (r.organization_id, o.location_id, rc.inventory_item_id, 'sale_reversal', v_qty, 'sell_returns', l.id::text, 'return ' || r.return_no, auth.uid())
      on conflict do nothing returning id into v_mid;
      continue when v_mid is null;
      v_left := v_qty;
      for a in select al.bin_id, al.lot_id, -sum(al.quantity) as taken from public.stock_allocations al join public.stock_movements s on s.id = al.movement_id
                where s.ref_type = 'orders' and s.kind = 'sale' and s.inventory_item_id = rc.inventory_item_id and (s.ref_id = o.id::text or s.ref_id like o.id::text || '#%')
                group by al.bin_id, al.lot_id having -sum(al.quantity) > 0 order by -sum(al.quantity) desc loop
        exit when v_left <= 0;
        v_take := least(v_left, a.taken);
        v_expired := a.lot_id is not null and exists (select 1 from public.inventory_lots lt where lt.id = a.lot_id and lt.expiry_date < current_date);
        v_bin := case when v_expired then public.inv_default_bin(r.organization_id, o.location_id, 'quarantine') else a.bin_id end;
        insert into public.stock_allocations (organization_id, movement_id, bin_id, lot_id, quantity) values (r.organization_id, v_mid, v_bin, a.lot_id, v_take);
        v_left := v_left - v_take;
      end loop;
      if v_left > 0 then
        insert into public.stock_allocations (organization_id, movement_id, bin_id, quantity) values (r.organization_id, v_mid, public.inv_default_bin(r.organization_id, o.location_id), v_left);
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default, 'recipe_factor', mv.recipe_factor,
                                  'can_make', floor(public.menu_can_make(v_org, i.id) / mv.recipe_factor)::int) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price, 'recipe_factor', mv.recipe_factor) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $function$

;


notify pgrst, 'reload schema';
commit;
