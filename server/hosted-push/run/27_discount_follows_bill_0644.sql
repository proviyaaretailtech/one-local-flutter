-- ==========================================================================================================================
-- HOSTED: 0644 A percentage discount follows the bill (3 Nov 2026). One transaction: if it stops with an error, nothing has changed.
-- Project ywylhzcxuoeilygzdonx. 10% of ₹820 = ₹82; with a ₹40 dish added it becomes ₹86 (10% of ₹860). A ₹ amount discount stays as it is.
-- Open unpaid bills with a % discount are priced again; paid bills are not touched.
-- ==========================================================================================================================
begin;
-- 0644: a percentage discount follows the bill (founder, 3 Nov 2026: "A 10% discount doesn't grow when dishes are added later. It stays at
-- ₹82 on ₹860 (9.5%), while the Discounts report still says 10%. Discount has to match total final amount").
-- A discount was kept only as rupees: tbl_order_reprice (adding dishes, cancelling one) kept the old amount, so 10% of ₹820 stayed ₹82 on a
-- ₹860 bill; the Discounts report printed the 10% asked for when it was given.
--   * orders.discount_pct: set when the discount is a percentage (manual %, or a % coupon), cleared for an amount
--   * tbl_order_reprice: a percentage is taken again of the dishes on the bill (a coupon's cap still applies); an amount stays as it is
--   * rst_bill_discount, rst_bill_coupon, pos_place_order: keep the percentage
--   * rst_report_discounts: 'pct' is the discount's real share of the dishes; 'given_pct' what was asked for
--   * open bills (unpaid, no payment, not split) with a percentage discount get it set and are priced again
-- An amount discount (₹ off) is not changed. Paid bills are not touched. Safe to run again.

alter table public.orders add column if not exists discount_pct numeric(5,2);
do $$ begin
  alter table public.orders add constraint orders_discount_pct_sane check (discount_pct is null or (discount_pct > 0 and discount_pct <= 100));
exception when duplicate_object then null; end $$;

-- a table's order priced again from its dishes: a percentage discount is worked out again (capped by its coupon), then the tax service (0641)
create or replace function public.tbl_order_reprice(p_order uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; v_sub numeric(10,2); v_disc numeric(10,2); v_cap numeric; t jsonb;
begin
  select * into o from public.orders where id = p_order;
  select coalesce(sum(i.unit_price * i.qty), 0) into v_sub from public.order_items i where i.order_id = p_order and i.status <> 'cancelled';
  if o.discount_pct is not null then
    v_disc := round(v_sub * o.discount_pct / 100, 2);
    if o.coupon_code is not null then
      select c.max_discount into v_cap from public.sell_coupons c where c.organization_id = o.organization_id and upper(c.code) = upper(o.coupon_code) limit 1;
      if v_cap is not null then v_disc := least(v_disc, v_cap); end if;
    end if;
  else
    v_disc := coalesce(o.discount, 0);
  end if;
  v_disc := least(v_disc, v_sub);
  t := public.pos_tax_bill(o.organization_id, v_sub, v_disc, o.service_charge_waived);
  update public.orders set subtotal = (t->>'subtotal')::numeric, discount = v_disc, gst_pct = (t->>'gst_pct')::numeric, gst_amount = (t->>'gst_amount')::numeric,
         service_charge = (t->>'service_charge')::numeric, service_charge_gst = (t->>'service_charge_gst')::numeric,
         service_charge_waived_amount = case when o.service_charge_waived then (t->>'service_charge_full')::numeric else service_charge_waived_amount end,
         round_off = (t->>'round_off')::numeric, total = (t->>'total')::numeric, updated_at = now()
   where id = p_order;
end $$;

CREATE OR REPLACE FUNCTION public.rst_bill_discount(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_o public.orders%rowtype; v_kind text := coalesce(nullif(p->>'kind', ''), 'amount'); v_value numeric; v_reason text := btrim(coalesce(p->>'reason', ''));
  v_gross numeric(10,2); v_amt numeric(10,2); v_pct numeric; v_limit numeric; v_manager boolean; v_new public.orders%rowtype;
begin
  v_o := public.rst_bill_lock(nullif(p->>'order_id', '')::uuid);
  if not public.rst_can_pay() then raise exception 'POS_FORBIDDEN: your role cannot change the bill'; end if;
  if v_kind not in ('amount', 'percent') then raise exception 'POS_BAD_REQUEST: choose ₹ or %%'; end if;
  begin v_value := (p->>'value')::numeric; exception when others then v_value := null; end;
  if v_value is null or v_value < 0 then raise exception 'POS_BAD_REQUEST: enter the discount'; end if;
  if v_o.status in ('paid', 'cancelled') then raise exception 'POS_WRONG_STATE: this bill is already %', v_o.status; end if;
  if exists (select 1 from public.payments where order_id = v_o.id) then raise exception 'POS_WRONG_STATE: a payment was already taken; the discount can no longer change'; end if;
  if exists (select 1 from public.rst_bill_splits where order_id = v_o.id and status = 'active') then raise exception 'POS_WRONG_STATE: the bill is split; give the discount before splitting'; end if;
  if v_o.coupon_code is not null then raise exception 'POS_WRONG_STATE: this bill has a discount code; it cannot take a manual discount too'; end if;

  select coalesce(sum(i.unit_price * i.qty), 0) into v_gross from public.order_items i where i.order_id = v_o.id and i.status <> 'cancelled';
  if v_gross <= 0 then raise exception 'POS_WRONG_STATE: add dishes before a discount'; end if;
  v_amt := case v_kind when 'percent' then round(v_gross * v_value / 100, 2) else round(v_value, 2) end;
  if v_amt > 0 and char_length(v_reason) < 3 then raise exception 'POS_BAD_REQUEST: say why (3 characters or more)'; end if;
  if char_length(v_reason) > 120 then raise exception 'POS_BAD_REQUEST: keep the reason under 120 characters'; end if;
  if v_amt >= v_gross then raise exception 'POS_BAD_REQUEST: the discount cannot take the whole bill; use a smaller discount'; end if;
  v_pct := round(v_amt * 100 / v_gross, 2);
  select coalesce((select manual_discount_limit_pct from public.org_bill_settings where organization_id = v_o.organization_id), 10) into v_limit;
  v_manager := public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager']);
  if v_pct > v_limit and not v_manager then
    raise exception 'POS_FORBIDDEN: more than % %% needs a manager; ask a manager to give this discount', trim(to_char(v_limit, 'FM990.##'));
  end if;
  if v_amt = coalesce(v_o.discount, 0) then return public.rst_bill_order_json(v_o.id) || jsonb_build_object('replayed', true); end if;

  -- 0644: a percentage is kept as one, so the discount follows the bill when dishes are added or cancelled; an amount stays an amount
  update public.orders set discount = v_amt, discount_pct = case when v_kind = 'percent' and v_amt > 0 then v_value end where id = v_o.id;
  perform public.tbl_order_reprice(v_o.id);
  select * into v_new from public.orders where id = v_o.id;
  if v_new.total <= 0 then raise exception 'POS_BAD_REQUEST: the discount cannot make the bill free; use a smaller discount'; end if;
  -- stamped with the exact clock time, so the newest discount on a bill is always the last one (several in one request stay in order)
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (v_o.organization_id, v_o.id, case when v_amt = 0 then 'manual_discount_removed' else 'manual_discount' end,
          case when v_amt = 0 then 'Manual discount taken off ' || coalesce(v_o.display_no, 'the bill')
               else 'Manual discount ' || v_amt || case when v_kind = 'percent' then ' (' || v_value || '%)' else '' end || ' on ' || coalesce(v_o.display_no, 'the bill') || ': ' || v_reason end,
          'pos', jsonb_build_object('by', auth.uid(), 'kind', v_kind, 'value', v_value, 'amount', v_amt, 'pct', v_pct, 'reason', nullif(v_reason, ''),
                                    'approved_by', case when v_pct > v_limit then auth.uid() end, 'limit_pct', v_limit,
                                    'old_total', v_o.total, 'new_total', v_new.total), clock_timestamp());
  return public.rst_bill_order_json(v_o.id) || jsonb_build_object('replayed', false);
end $f$;

CREATE OR REPLACE FUNCTION public.rst_bill_coupon(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
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
         total = v_total, coupon_code = v_cp.code, discount_pct = case when v_cp.kind = 'percent' then v_cp.value end, service_charge_waived_amount = case when v_o.service_charge_waived then v_scfull else service_charge_waived_amount end
   where id = v_o.id;
  insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_o.organization_id, v_cp.id, v_o.id, v_ckey);
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, 'coupon_applied', 'Discount code ' || v_cp.code || ' took ' || v_disc || ' off ' || v_o.display_no, 'pos',
          jsonb_build_object('by', auth.uid(), 'coupon_id', v_cp.id, 'discount', v_disc, 'old_total', v_o.total, 'new_total', v_total));
  return public.rst_bill_order_json(v_o.id) || jsonb_build_object('replayed', false);
end $f$;

CREATE OR REPLACE FUNCTION public.pos_place_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
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
    -- 0644: a percentage coupon is kept as a percentage, so the discount follows the bill
    if v_code is not null and v_cp.kind = 'percent' then update public.orders set discount_pct = v_cp.value where id = v_id; end if;
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
end $f$;

-- the Discounts report: each bill's real discount share

CREATE OR REPLACE FUNCTION public.rst_report_discounts(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record;
begin
  select * into w from public.rst_rep__window(p);
  return (
    with b as (select * from public.rst_rep__sales(v_org, v_locs, v_all, w.t_from, w.t_to)),
    disc as (
      select o.*, round(coalesce(o.service_charge_waived_amount, 0) * 100) waived_minor,
             case when o.discount_minor > 0 then (case when o.coupon_code is null then 'manual' else 'coupon' end) end disc_kind,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'coupon_applied' order by e.created_at desc limit 1) coupon_by,
             (select e.meta from public.order_events e where e.order_id = o.id and e.kind = 'manual_discount' order by e.created_at desc limit 1) manual,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'service_charge_waived' order by e.created_at desc limit 1) waive_by
        from b o where o.discount_minor > 0 or coalesce(o.service_charge_waived, false)),
    free as (
      select o.id oid, coalesce(o.display_no, o.order_no::text) bill, i.name, i.qty from b o join public.order_items i on i.order_id = o.id
       where i.status <> 'cancelled' and i.unit_price = 0 and coalesce(i.notes, '') not like 'Combo: %')
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'totals', jsonb_build_object(
        'discount_minor', (select coalesce(sum(discount_minor), 0) from disc),
        'manual_minor', (select coalesce(sum(discount_minor), 0) from disc where disc_kind = 'manual'),
        'coupon_minor', (select coalesce(sum(discount_minor), 0) from disc where disc_kind = 'coupon'),
        'waived_minor', (select coalesce(sum(waived_minor), 0) from disc),
        'bills', (select count(*) from disc), 'all_bills', (select count(*) from b), 'gross_minor', (select coalesce(sum(subtotal_minor), 0) from b),
        'free_dishes', (select coalesce(sum(qty), 0) from free)),
      'coupons', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'bills', c.n, 'amount_minor', c.amt) order by c.amt desc), '[]'::jsonb)
                    from (select coupon_code code, count(*) n, sum(discount_minor) amt from disc where disc_kind = 'coupon' group by 1) c),
      'bills', (select coalesce(jsonb_agg(jsonb_build_object('order_id', d.id, 'bill', coalesce(d.display_no, d.order_no::text), 'at', coalesce(d.paid_at, d.created_at),
                  'gross_minor', d.subtotal_minor, 'discount_minor', d.discount_minor, 'kind', d.disc_kind, 'coupon', d.coupon_code,
                  'coupon_by', public.money_person(v_org, nullif(d.coupon_by, '')::uuid),
                  'reason', d.manual->>'reason',
                  -- 0644: the discount's real share of the dishes on the bill (what was asked for is given_pct)
                  'pct', (select case when g.gross > 0 then round(d.discount_minor / 100.0 * 100 / g.gross, 1) end
                            from (select sum(i.unit_price * i.qty) gross from public.order_items i where i.order_id = d.id and i.status <> 'cancelled') g),
                  'given_pct', (d.manual->>'pct')::numeric,
                  'given_by', public.money_person(v_org, nullif(d.manual->>'by', '')::uuid),
                  'approved_by', public.money_person(v_org, nullif(d.manual->>'approved_by', '')::uuid),
                  'waived_minor', d.waived_minor, 'waive_reason', nullif(d.waive_reason, ''), 'waived_by', public.money_person(v_org, nullif(d.waive_by, '')::uuid))
                  order by coalesce(d.paid_at, d.created_at) desc), '[]'::jsonb) from disc d),
      'free', (select coalesce(jsonb_agg(jsonb_build_object('order_id', f.oid, 'bill', f.bill, 'name', f.name, 'qty', f.qty)), '[]'::jsonb) from free f),
      'not_recorded', '[]'::jsonb));
end $f$;

-- open bills with a percentage discount: keep it as a percentage and price them again (paid, part-paid and split bills keep their money)
do $$ declare r record; begin
  for r in
    select o.id,
           case when o.coupon_code is not null then (select c.value from public.sell_coupons c where c.organization_id = o.organization_id and upper(c.code) = upper(o.coupon_code) and c.kind = 'percent' limit 1)
                else (select (e.meta->>'value')::numeric from public.order_events e where e.order_id = o.id and e.kind = 'manual_discount' and e.meta->>'kind' = 'percent'
                       and not exists (select 1 from public.order_events z where z.order_id = o.id and z.kind in ('manual_discount', 'manual_discount_removed') and z.created_at > e.created_at)
                       order by e.created_at desc limit 1) end as pct
      from public.orders o
     where o.discount > 0 and o.discount_pct is null and o.paid_at is null and o.status not in ('paid', 'cancelled')
       and not exists (select 1 from public.payments y where y.order_id = o.id)
       and not exists (select 1 from public.rst_bill_splits s where s.order_id = o.id and s.status = 'active')
  loop
    continue when r.pct is null or r.pct <= 0 or r.pct > 100;
    update public.orders set discount_pct = r.pct where id = r.id;
    perform public.tbl_order_reprice(r.id);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
