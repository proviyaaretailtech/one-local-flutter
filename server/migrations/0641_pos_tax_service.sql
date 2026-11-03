-- 0641: the POS tax service, with GST charged on the service charge (founder, 3 Nov 2026: "GST isn't charged on the service charge.
-- ₹1,000 food with 10% service gave GST ₹50 and total ₹1,150; it should be ₹55 and ₹1,155 ... Should create a taxation service inside
-- pos"). Under GST a restaurant's service charge is part of what it sells, so it is taxed at the same rate as the food.
-- Before this the bill's money was worked out in five places, each with its own copy of the formula, and none taxed the service charge:
-- pos_place_order (counter and table orders, and the quote), tbl_order_reprice (any change to a table's order), rst_bill_coupon,
-- pos_adjust_bill (waive or restore the service charge) and svc_order_reprice (service businesses).
--   * pos_tax_bill(org, gross, discount, waive): the one tax service. GST on the food after the discount (taken out of menu prices that
--     include tax, added on top when they do not; none when the business is not GST-registered), the service charge on the food after the
--     discount (kept off when waived), GST on the service charge at the same rate (added on top: the service charge is never inside a menu
--     price), the CGST / SGST halves, round off and the total.
--   * pos_tax_service_charge(org, base, gst %, waive): the service charge and its GST, for the bills that keep their own food GST.
--   * orders.service_charge_gst: the GST on the service charge, inside gst_amount, so a waive or restore can take it out again and a bill can
--     show it. The money of a paid or cancelled order stays frozen (this column too).
--   * the five functions call the service; nothing else about them changes.
--   * open bills with a service charge, nothing paid and not split, are priced again so they carry the GST too. Paid bills are not touched.
-- Nothing changes for a business without a service charge. Safe to run again.

alter table public.orders add column if not exists service_charge_gst numeric(10,2) not null default 0;
do $$ begin
  alter table public.orders add constraint orders_service_charge_gst_sane check (service_charge_gst >= 0 and service_charge_gst <> 'NaN'::numeric);
exception when duplicate_object then null; end $$;

-- the service charge on [base] (the food after any discount) and its GST at [gst %]; waived: none, with what it would have been
create or replace function public.pos_tax_service_charge(p_org uuid, p_base numeric, p_gst_pct numeric, p_waive boolean default false) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with c as (select coalesce((select s.service_charge_pct from public.org_bill_settings s where s.organization_id = p_org), 0) as pct),
  f as (select round(greatest(coalesce(p_base, 0), 0) * c.pct / 100, 2) as full_sc, c.pct from c)
  select jsonb_build_object('service_charge_pct', f.pct, 'service_charge_full', f.full_sc,
    'service_charge', case when coalesce(p_waive, false) then 0 else f.full_sc end,
    'service_charge_gst', case when coalesce(p_waive, false) then 0 else round(f.full_sc * coalesce(p_gst_pct, 0) / 100, 2) end)
  from f;
$$;

-- The bill of [gross] (the dishes at their menu prices) less [discount]. Every amount in rupees with paise.
--   subtotal: the dishes before tax (with tax-inclusive prices, the GST taken out of them)
--   food_gst, service_charge, service_charge_gst, gst_amount (= food_gst + service_charge_gst), cgst / sgst (its halves)
--   raw (before round off), round_off, total
create or replace function public.pos_tax_bill(p_org uuid, p_gross numeric, p_discount numeric default 0, p_waive_sc boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_cfg public.org_bill_settings%rowtype; v_sub numeric(10,2) := coalesce(p_gross, 0); v_disc numeric(10,2) := coalesce(p_discount, 0);
  v_pct numeric; v_food numeric(10,2); v_s jsonb; v_gst numeric(10,2); v_raw numeric(10,2); v_total numeric(10,2); v_round boolean;
begin
  select * into v_cfg from public.org_bill_settings where organization_id = p_org;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.round_off_enabled := true; end if;
  -- 0371: not GST-registered charges no GST; menu prices that include GST have it taken out, not added on top
  v_pct := case when v_cfg.gst_registered is false then 0 else coalesce(v_cfg.sgst_pct, 0) + coalesce(v_cfg.cgst_pct, 0) end;
  if coalesce(v_cfg.prices_include_tax, false) and v_pct > 0 then
    v_food := round((v_sub - v_disc) * v_pct / (100 + v_pct), 2);
    v_sub := v_sub - v_food;   -- subtotal is stored before tax, so subtotal + GST still equals what the menu showed
  else
    v_food := round((v_sub - v_disc) * v_pct / 100, 2);
  end if;
  v_s := public.pos_tax_service_charge(p_org, v_sub - v_disc, v_pct, p_waive_sc);
  v_gst := v_food + (v_s->>'service_charge_gst')::numeric;
  v_raw := v_sub - v_disc + v_gst + (v_s->>'service_charge')::numeric;
  v_round := coalesce(v_cfg.round_off_enabled, true);
  v_total := case when v_round then round(v_raw) else v_raw end;
  return v_s || jsonb_build_object('gst_pct', v_pct, 'cgst_pct', case when v_pct = 0 then 0 else coalesce(v_cfg.cgst_pct, 0) end,
    'sgst_pct', case when v_pct = 0 then 0 else coalesce(v_cfg.sgst_pct, 0) end, 'prices_include_tax', coalesce(v_cfg.prices_include_tax, false),
    'subtotal', v_sub, 'discount', v_disc, 'food_gst', v_food, 'gst_amount', v_gst,
    'cgst', round(v_gst / 2, 2), 'sgst', v_gst - round(v_gst / 2, 2), 'raw', v_raw, 'round_off', v_total - v_raw, 'total', v_total);
end $$;

revoke all on function public.pos_tax_service_charge(uuid, numeric, numeric, boolean) from public, anon, authenticated;
revoke all on function public.pos_tax_bill(uuid, numeric, numeric, boolean) from public, anon, authenticated;

-- a table's order priced again from its dishes (after adding, cancelling, a discount): the tax service does the money
create or replace function public.tbl_order_reprice(p_order uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; v_sub numeric(10,2); v_disc numeric(10,2); t jsonb;
begin
  select * into o from public.orders where id = p_order;
  select coalesce(sum(i.unit_price * i.qty), 0) into v_sub from public.order_items i where i.order_id = p_order and i.status <> 'cancelled';
  v_disc := least(coalesce(o.discount, 0), v_sub);
  t := public.pos_tax_bill(o.organization_id, v_sub, v_disc, o.service_charge_waived);
  update public.orders set subtotal = (t->>'subtotal')::numeric, discount = v_disc, gst_pct = (t->>'gst_pct')::numeric, gst_amount = (t->>'gst_amount')::numeric,
         service_charge = (t->>'service_charge')::numeric, service_charge_gst = (t->>'service_charge_gst')::numeric,
         service_charge_waived_amount = case when o.service_charge_waived then (t->>'service_charge_full')::numeric else service_charge_waived_amount end,
         round_off = (t->>'round_off')::numeric, total = (t->>'total')::numeric, updated_at = now()
   where id = p_order;
end $$;

-- tbl_order_reprice is written out in full above; these keep their own steps and take the money from the tax service

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
  v_raw numeric(10,2); v_total numeric(10,2); v_round numeric(10,2) := 0; v_disc numeric(10,2) := 0; v_tax jsonb; v_scgst numeric(10,2) := 0;
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
    v_sub := v_sub + (coalesce((select mv.price from public.menu_item_variants mv where mv.id = nullif(v_line->>'variant_id', '')::uuid and mv.menu_item_id = v_item.id), v_item.price)
                      + (public.menu_line_extras(v_org, v_item.id, v_line)->>'extra')::numeric) * v_qty; v_n := v_n + v_qty;
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

  if v_waive then
    if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can remove the service charge'; end if;
    if coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
  end if;
  -- 0641: the POS tax service works out the bill: GST on the food (taken out of inclusive prices), the service charge, GST on the
  -- service charge, round off
  v_tax := public.pos_tax_bill(v_org, v_sub, v_disc, v_waive);
  v_gst_pct := (v_tax->>'gst_pct')::numeric; v_gst := (v_tax->>'gst_amount')::numeric; v_sub := (v_tax->>'subtotal')::numeric;
  v_sc := (v_tax->>'service_charge')::numeric; v_scgst := (v_tax->>'service_charge_gst')::numeric;
  v_waived := case when v_waive then (v_tax->>'service_charge_full')::numeric else 0 end;
  v_raw := (v_tax->>'raw')::numeric; v_total := (v_tax->>'total')::numeric; v_round := v_total - v_raw;

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
    update public.orders set service_charge_gst = v_scgst where id = v_id and v_scgst <> 0;
  if v_code is not null and v_disc > 0 then
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, v_cp.id, v_id, v_ckey);
  end if;
  -- 0624: add-ons and combos on each line; the combo dishes follow at ₹0
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name, add_ons)
  select v_id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price) + (e.x->>'extra')::numeric, nullif(l->>'notes',''), coalesce(mi.station,'main'), coalesce(mi.course,'eat'), mv.name,
         coalesce(e.x->'add_ons', '[]'::jsonb)
  from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid
  left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id
  cross join lateral (select public.menu_line_extras(v_org, mi.id, l) as x) e;
  perform public.order_combo_lines(v_id, v_org, p->'lines');
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
end $function$;

CREATE OR REPLACE FUNCTION public.rst_bill_coupon(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_code text := upper(nullif(btrim(coalesce(p->>'code', '')), '')); v_cp public.sell_coupons%rowtype;
  v_cfg public.org_bill_settings%rowtype; v_sub numeric(10,2); v_disc numeric(10,2); v_gst_pct numeric; v_gst numeric(10,2); v_sc numeric(10,2);
  v_scfull numeric(10,2); v_raw numeric(10,2); v_total numeric(10,2); v_ckey text; v_tax jsonb; v_scgst numeric(10,2);
begin
  v_o := public.rst_bill_lock(nullif(p->>'order_id', '')::uuid);
  if not public.rst_can_pay() then raise exception 'POS_FORBIDDEN: your role cannot change the bill'; end if;
  if v_code is null then raise exception 'POS_BAD_REQUEST: enter a discount code'; end if;
  if v_o.coupon_code is not null then
    if upper(v_o.coupon_code) = v_code then return public.rst_bill_order_json(v_o.id) || jsonb_build_object('replayed', true); end if;
    raise exception 'POS_WRONG_STATE: a discount code is already on this bill';
  end if;
  if v_o.status in ('paid', 'cancelled') then raise exception 'POS_WRONG_STATE: this bill is already %', v_o.status; end if;
  if exists (select 1 from public.payments where order_id = v_o.id) then raise exception 'POS_WRONG_STATE: a payment was already taken; a code can no longer be added'; end if;
  if exists (select 1 from public.rst_bill_splits where order_id = v_o.id and status = 'active') then raise exception 'POS_WRONG_STATE: the bill is split; add the code before splitting'; end if;
  if v_o.discount > 0 then raise exception 'POS_WRONG_STATE: this bill already has a discount'; end if;

  select coalesce(sum(i.unit_price * i.qty), 0) into v_sub from public.order_items i where i.order_id = v_o.id and i.status <> 'cancelled';
  select * into v_cfg from public.org_bill_settings where organization_id = v_o.organization_id;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;
  -- the coupon rules of pos_place_order (0380): active, dates, minimum bill, cap, use limits counted under the coupon row's lock
  select * into v_cp from public.sell_coupons where organization_id = v_o.organization_id and upper(code) = v_code and active
    and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
  if not found then raise exception 'POS_COUPON_UNKNOWN: this coupon code is not valid'; end if;
  if v_sub < v_cp.min_order then raise exception 'POS_COUPON_MIN: this coupon needs a bill of at least %', v_cp.min_order; end if;
  v_disc := case v_cp.kind when 'percent' then round(v_sub * v_cp.value / 100, 2) else v_cp.value end;
  if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if;
  v_disc := least(v_disc, v_sub);
  v_ckey := nullif(right(regexp_replace(coalesce(v_o.customer_phone, ''), '\D', '', 'g'), 10), '');
  if v_cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and released_at is null) >= v_cp.max_uses then
    raise exception 'POS_COUPON_LIMIT: this coupon has been used up'; end if;
  if v_cp.max_uses_per_customer is not null then
    if v_ckey is null then raise exception 'POS_COUPON_CUSTOMER: this coupon is limited per customer; enter the customer''s mobile number'; end if;
    if (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and customer_key = v_ckey and released_at is null) >= v_cp.max_uses_per_customer then
      raise exception 'POS_COUPON_LIMIT: this customer has already used this coupon'; end if;
  end if;
  -- 0641: the POS tax service (GST on the food and on the service charge, the service charge kept off when it was waived, round off)
  v_tax := public.pos_tax_bill(v_o.organization_id, v_sub, v_disc, v_o.service_charge_waived);
  v_gst_pct := (v_tax->>'gst_pct')::numeric; v_gst := (v_tax->>'gst_amount')::numeric; v_sub := (v_tax->>'subtotal')::numeric;
  v_scfull := (v_tax->>'service_charge_full')::numeric; v_sc := (v_tax->>'service_charge')::numeric; v_scgst := (v_tax->>'service_charge_gst')::numeric;
  v_raw := (v_tax->>'raw')::numeric; v_total := (v_tax->>'total')::numeric;
  if v_total <= 0 then raise exception 'POS_COUPON_ZERO: this coupon would make the bill free; use a smaller discount'; end if;
  if v_disc <= 0 then raise exception 'POS_COUPON_UNKNOWN: this coupon takes nothing off this bill'; end if;

  update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = v_cp.id;
  update public.orders set subtotal = v_sub, discount = v_disc, gst_pct = v_gst_pct, gst_amount = v_gst, service_charge = v_sc, service_charge_gst = v_scgst, round_off = v_total - v_raw,
         total = v_total, coupon_code = v_cp.code, service_charge_waived_amount = case when v_o.service_charge_waived then v_scfull else service_charge_waived_amount end
   where id = v_o.id;
  insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_o.organization_id, v_cp.id, v_o.id, v_ckey);
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, 'coupon_applied', 'Discount code ' || v_cp.code || ' took ' || v_disc || ' off ' || v_o.display_no, 'pos',
          jsonb_build_object('by', auth.uid(), 'coupon_id', v_cp.id, 'discount', v_disc, 'old_total', v_o.total, 'new_total', v_total));
  return public.rst_bill_order_json(v_o.id) || jsonb_build_object('replayed', false);
end $function$;

CREATE OR REPLACE FUNCTION public.pos_adjust_bill(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_cfg public.org_bill_settings%rowtype; v_waive boolean := coalesce((p->>'waive_service_charge')::boolean,false);
  v_exp timestamptz := nullif(p->>'expected_updated_at','')::timestamptz; v_sc numeric(10,2); v_raw numeric(10,2); v_total numeric(10,2); v_paid numeric; v_s jsonb; v_food_gst numeric(10,2);
begin
  select * into v_o from public.orders where id = (p->>'order_id')::uuid for update;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id() then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can change the bill'; end if;
  if v_exp is not null and v_exp <> v_o.updated_at then raise exception 'POS_STALE: this order was changed on another device'; end if;
  if v_o.status in ('paid','cancelled') then raise exception 'POS_WRONG_STATE: this order is already %', v_o.status; end if;
  if v_waive and coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
  select * into v_cfg from public.org_bill_settings where organization_id = v_o.organization_id;
  if not found then v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;
  -- 0641: the service charge and its GST from the POS tax service; the food's GST stays as it is
  v_s := public.pos_tax_service_charge(v_o.organization_id, v_o.subtotal - v_o.discount, v_o.gst_pct, v_waive);
  v_sc := (v_s->>'service_charge')::numeric;
  v_food_gst := v_o.gst_amount - v_o.service_charge_gst;
  v_raw := v_o.subtotal - v_o.discount + v_food_gst + (v_s->>'service_charge_gst')::numeric + v_sc;
  v_total := case when v_cfg.round_off_enabled then round(v_raw) else v_raw end;
  select coalesce(sum(amount),0) into v_paid from public.payments where order_id = v_o.id;
  if v_paid > v_total then raise exception 'POS_OVERPAY: payments already exceed the new total'; end if;
  update public.orders set service_charge = v_sc, gst_amount = v_food_gst + (v_s->>'service_charge_gst')::numeric,
    service_charge_gst = (v_s->>'service_charge_gst')::numeric, round_off = v_total - v_raw, total = v_total, updated_at = now(),
    service_charge_waived = v_waive, waive_reason = case when v_waive then p->>'waive_reason' end,
    service_charge_waived_amount = case when v_waive then (v_s->>'service_charge_full')::numeric else 0 end
  where id = v_o.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, case when v_waive then 'service_charge_waived' else 'service_charge_restored' end,
          case when v_waive then 'Service charge removed: ' || (p->>'waive_reason') else 'Service charge restored' end, 'pos', jsonb_build_object('by', auth.uid()));
  return public.pos_order_json(v_o.id);
end $function$;

CREATE OR REPLACE FUNCTION public.svc_order_reprice(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; v_cfg public.org_bill_settings%rowtype; v_gross numeric(10,2); v_gst0 numeric(10,2); v_sub numeric(10,2); v_gst numeric(10,2);
  v_sc numeric(10,2); v_raw numeric(10,2); v_total numeric(10,2); v_paid numeric; v_incl boolean; v_s jsonb;
begin
  select * into o from public.orders where id = p_order for update;
  if o.status in ('paid', 'cancelled') or o.paid_at is not null then raise exception 'SVC_WRONG_STATE: the order is already %', o.status; end if;
  select * into v_cfg from public.org_bill_settings where organization_id = o.organization_id;
  if not found then v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;
  v_incl := coalesce(v_cfg.prices_include_tax, false) and o.gst_pct > 0;
  select coalesce(sum(qty * unit_price), 0) into v_gross from public.order_items where order_id = p_order and status <> 'cancelled';
  if v_incl then v_gst0 := round(v_gross * o.gst_pct / (100 + o.gst_pct), 2); v_sub := v_gross - v_gst0; else v_sub := v_gross; v_gst0 := round(v_sub * o.gst_pct / 100, 2); end if;
  if o.discount > v_sub then raise exception 'SVC_BAD_REQUEST: the discount is more than the bill'; end if;
  v_gst := case when o.discount = 0 then v_gst0 else round((v_sub - o.discount) * o.gst_pct / 100, 2) end;
  -- 0641: the service charge and its GST from the POS tax service
  v_s := public.pos_tax_service_charge(o.organization_id, v_sub - o.discount, o.gst_pct, o.service_charge_waived);
  v_sc := (v_s->>'service_charge')::numeric;
  v_gst := v_gst + (v_s->>'service_charge_gst')::numeric;
  v_raw := v_sub - o.discount + v_gst + v_sc;
  v_total := case when coalesce(v_cfg.round_off_enabled, true) then round(v_raw) else v_raw end;
  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = p_order and method <> 'due';
  if v_paid > v_total then raise exception 'SVC_OVERPAY: payments already exceed the new total'; end if;
  update public.orders set subtotal = v_sub, gst_amount = v_gst, service_charge = v_sc, service_charge_gst = (v_s->>'service_charge_gst')::numeric, round_off = v_total - v_raw, total = v_total, updated_at = now() where id = p_order;
end $function$;

-- a paid or cancelled order keeps its GST on the service charge too

CREATE OR REPLACE FUNCTION public.orders_guard_money_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if (old.paid_at is not null or old.status = 'cancelled')
     and (new.total is distinct from old.total or new.subtotal is distinct from old.subtotal or new.gst_amount is distinct from old.gst_amount
          or new.gst_pct is distinct from old.gst_pct or new.discount is distinct from old.discount
          or new.service_charge_gst is distinct from old.service_charge_gst
          ) then   -- the *_minor columns are generated from these, so they are not compared (NULL inside a BEFORE trigger)
    raise exception 'OL_ORDER_FROZEN: the amounts of a paid or cancelled order cannot be changed' using errcode = '23514';
  end if;
  return new;
end $function$;

-- open bills that carry a service charge, with nothing paid and no split, priced again so they carry its GST (paid bills keep their money)
do $$ declare r record; begin
  for r in select o.id from public.orders o
            where o.service_charge > 0 and o.paid_at is null and o.status not in ('paid', 'cancelled')
              and not exists (select 1 from public.payments y where y.order_id = o.id)
              and not exists (select 1 from public.rst_bill_splits s where s.order_id = o.id and s.status = 'active')
              and exists (select 1 from public.order_items i where i.order_id = o.id)
  loop
    perform public.tbl_order_reprice(r.id);
  end loop;
end $$;
