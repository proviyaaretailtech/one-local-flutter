-- ==========================================================================================================================
-- HOSTED: 0645 A generated bill is locked; changing it needs an admin PIN and a note (3 Nov 2026). One transaction: if it stops with an
-- error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Owners/admins set a 6-digit PIN in Settings → Admin PIN. Discount, coupon, dish cancel on a generated bill, and cancelling an order after
-- its KOT, need it plus a note; each is logged and highlighted in the Leakage audit and on the owner's dashboard.
-- ==========================================================================================================================
begin;
-- 0645: a generated bill is locked; changing it needs an admin PIN and a note (founder, 3 Nov 2026: "A discount given after the bill is
-- generated is allowed but missing from the Leakage audit ... once a bill is generated it cannot be edited"; "Bill can be only edited with
-- admin key + a note and these entries should be highlighted on owners dashboard under revenue leakage reports. It should be also applicable
-- for when a cashier can cancel a whole order after its KOT went to the kitchen ... logged with their name"; generated bills show in reports
-- at once).
--   * Admin PIN: each owner / admin sets their own 6-digit PIN (rst_admin_pin_set); kept only as a bcrypt hash.
--   * rst_admin_pin_check: someone at the till types an admin's PIN; a right one gives a one-time pass for 5 minutes. Every try is kept;
--     5 wrong tries in 15 minutes lock that person out for the rest of the 15 minutes.
--   * A restaurant's generated bill (awaiting payment) can only be changed with a pass and a note: the discount (rst_bill_discount), a
--     coupon (rst_bill_coupon), the service charge (pos_adjust_bill), cancelling a dish (rst_items_cancel); and cancelling a whole order
--     (pos_set_order_status) needs the same once its KOT went to the kitchen or its bill was generated. Voiding a paid bill stays the
--     owner's (rst_bill_void, 0640).
--   * Each such change is an order_event 'admin_override' (what, the note, who did it, which admin's PIN) and an audit_logs row.
--   * Leakage audit (rst_report_audit): + 'overrides' (the admin PIN changes, highlighted); 'after_bill' also counts a discount, a removed
--     discount and a cancelled dish after the bill; 'unpaid' shows bills generated today at once (not only after the day ends).
--   * rst_home_insights: + 'leakage' {admin_changes today, the latest three} for the owner's dashboard.
-- Service businesses and stores are not changed. Safe to run again.

create table if not exists public.rst_admin_pins (
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null,
  pin_hash text not null,
  set_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);
alter table public.rst_admin_pins enable row level security;
revoke all on public.rst_admin_pins from public, anon, authenticated;

create table if not exists public.rst_admin_passes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  requested_by uuid not null,
  approver_id uuid,
  ok boolean not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  used_at timestamptz,
  used_for text,
  order_id uuid,
  note text
);
create index if not exists rst_admin_passes_tries on public.rst_admin_passes (organization_id, requested_by, created_at desc);
alter table public.rst_admin_passes enable row level security;
revoke all on public.rst_admin_passes from public, anon, authenticated;

create or replace function public.rst_admin__is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.has_org_role(array['org_owner', 'org_admin']);
$$;
revoke all on function public.rst_admin__is_admin() from public, anon, authenticated;

-- An owner or admin sets (or changes) their own PIN: {pin} — six digits, not all the same, not 123456 / 654321
create or replace function public.rst_admin_pin_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_pin text := coalesce(p->>'pin', '');
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.rst_admin__is_admin() then raise exception 'POS_FORBIDDEN: only the owner or an admin has an admin PIN'; end if;
  if v_pin !~ '^[0-9]{6}$' then raise exception 'POS_BAD_REQUEST: the admin PIN is 6 digits'; end if;
  if v_pin ~ '^(.)\1{5}$' or v_pin in ('123456', '654321', '012345', '543210') then raise exception 'POS_BAD_REQUEST: choose a PIN that is harder to guess'; end if;
  insert into public.rst_admin_pins (organization_id, user_id, pin_hash, set_at)
  values (v_org, auth.uid(), extensions.crypt(v_pin, extensions.gen_salt('bf', 8)), now())
  on conflict (organization_id, user_id) do update set pin_hash = excluded.pin_hash, set_at = now();
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (v_org, auth.uid(), 'rst.admin_pin_set', 'org_user', auth.uid()::text, null, jsonb_build_object('set_at', now()));
  return public.rst_admin_pin_status('{}'::jsonb);
end $$;

-- Whether this person has a PIN, may set one, and how many admins of the business have one
create or replace function public.rst_admin_pin_status(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object('can_set', public.rst_admin__is_admin(),
    'has_pin', exists (select 1 from public.rst_admin_pins x where x.organization_id = v_org and x.user_id = auth.uid()),
    'set_at', (select x.set_at from public.rst_admin_pins x where x.organization_id = v_org and x.user_id = auth.uid()),
    'admins_with_pin', (select count(*) from public.rst_admin_pins x join public.org_users ou on ou.organization_id = x.organization_id and ou.user_id = x.user_id
                         join public.roles r on r.id = ou.role_id
                        where x.organization_id = v_org and ou.status = 'active' and r.slug in ('org_owner', 'org_admin')));
end $$;

-- Someone at the till types an admin's PIN: {pin}. Right: {ok: true, pass_id, approver, expires_at}; wrong: {ok: false, tries_left}.
-- Not an error, so the wrong try is kept and counted. Locked after 5 wrong tries in 15 minutes.
create or replace function public.rst_admin_pin_check(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_pin text := coalesce(p->>'pin', ''); v_wrong int; v_admin uuid; v_id uuid;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not exists (select 1 from public.org_users ou where ou.organization_id = v_org and ou.user_id = auth.uid() and ou.status = 'active') then
    raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select count(*) into v_wrong from public.rst_admin_passes x
   where x.organization_id = v_org and x.requested_by = auth.uid() and not x.ok and x.created_at > now() - interval '15 minutes';
  if v_wrong >= 5 then raise exception 'POS_RATE_LIMITED: too many wrong PINs; try again in 15 minutes'; end if;
  if not exists (select 1 from public.rst_admin_pins x where x.organization_id = v_org) then
    raise exception 'POS_WRONG_STATE: no admin PIN is set yet; the owner sets one in Settings → Admin PIN'; end if;
  if v_pin ~ '^[0-9]{6}$' then
    select x.user_id into v_admin from public.rst_admin_pins x
      join public.org_users ou on ou.organization_id = x.organization_id and ou.user_id = x.user_id and ou.status = 'active'
      join public.roles r on r.id = ou.role_id and r.slug in ('org_owner', 'org_admin')
     where x.organization_id = v_org and x.pin_hash = extensions.crypt(v_pin, x.pin_hash) limit 1;
  end if;
  insert into public.rst_admin_passes (organization_id, requested_by, approver_id, ok, expires_at)
  values (v_org, auth.uid(), v_admin, v_admin is not null, case when v_admin is not null then now() + interval '5 minutes' end) returning id into v_id;
  if v_admin is null then return jsonb_build_object('ok', false, 'tries_left', greatest(4 - v_wrong, 0)); end if;
  return jsonb_build_object('ok', true, 'pass_id', v_id, 'approver', public.money_person(v_org, v_admin), 'expires_at', now() + interval '5 minutes');
end $$;

-- The change a generated bill needs: a pass from rst_admin_pin_check (this person's, unused, under 5 minutes) and a note. Used up here,
-- recorded on the order and in the audit; answers the admin whose PIN it was. [p_what] is the sentence shown when the pass is missing.
create or replace function public.rst_admin__consume(o public.orders, p jsonb, p_action text, p_what text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pass uuid; v_note text := btrim(coalesce(p->>'admin_note', '')); x public.rst_admin_passes%rowtype;
  v_label text := case p_action when 'discount' then 'Discount changed after the bill' when 'coupon' then 'Coupon added after the bill'
    when 'service_charge' then 'Service charge changed after the bill' when 'item_cancel' then 'Dish cancelled after the bill'
    when 'order_cancel' then 'Order cancelled after its KOT or bill' else p_action end;
begin
  begin v_pass := nullif(p->>'admin_pass', '')::uuid; exception when others then v_pass := null; end;
  if v_pass is null then raise exception 'POS_ADMIN_PIN: %; enter an admin PIN and a note', p_what; end if;
  if char_length(v_note) not between 3 and 200 then raise exception 'POS_ADMIN_PIN: write a note for the admin change (3 to 200 characters)'; end if;
  select * into x from public.rst_admin_passes where id = v_pass and organization_id = o.organization_id for update;
  if not found or not x.ok or x.requested_by <> auth.uid() or x.used_at is not null or x.expires_at <= now() then
    raise exception 'POS_ADMIN_PIN: the admin PIN has expired or was already used; enter it again'; end if;
  update public.rst_admin_passes set used_at = now(), used_for = p_action, order_id = o.id, note = v_note where id = x.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (o.organization_id, o.id, 'admin_override', v_label || ' · ' || v_note, 'pos',
          jsonb_build_object('action', p_action, 'note', v_note, 'by', auth.uid(), 'approved_by', x.approver_id, 'pass_id', x.id,
                             'status', o.status, 'total', o.total), clock_timestamp());
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (o.organization_id, auth.uid(), 'rst.admin_override', 'order', o.id::text, jsonb_build_object('status', o.status, 'total', o.total),
          jsonb_build_object('action', p_action, 'note', v_note, 'approved_by', x.approver_id, 'pass_id', x.id));
  return x.approver_id;
end $$;

-- A restaurant's bill that is locked for [p_action]: generated (awaiting payment), or (whole-order cancel) already with the kitchen.
-- Then the pass and note are needed; otherwise nothing (null). Stores and service businesses are never asked.
create or replace function public.rst_admin__guard(o public.orders, p jsonb, p_action text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.pos_org_is_restaurant(o.organization_id) then return null; end if;
  if o.status = 'awaiting_payment' then
    return public.rst_admin__consume(o, p, p_action, 'this bill is generated, so it can only be changed with an admin PIN');
  end if;
  if p_action = 'order_cancel' and exists (select 1 from public.kot_tickets k where k.order_id = o.id) then
    return public.rst_admin__consume(o, p, p_action, 'this order went to the kitchen, so it can only be cancelled with an admin PIN');
  end if;
  return null;
end $$;

do $$ declare f text; begin
  foreach f in array array['rst_admin__consume(public.orders, jsonb, text, text)', 'rst_admin__guard(public.orders, jsonb, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['rst_admin_pin_set(jsonb)', 'rst_admin_pin_status(jsonb)', 'rst_admin_pin_check(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- the locked actions

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
  -- 0645: a generated bill is locked: an admin PIN and a note
  perform public.rst_admin__guard(v_o, p, 'discount');
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
  -- 0645: a generated bill is locked: an admin PIN and a note
  perform public.rst_admin__guard(v_o, p, 'coupon');
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

CREATE OR REPLACE FUNCTION public.pos_adjust_bill(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_o public.orders%rowtype; v_cfg public.org_bill_settings%rowtype; v_waive boolean := coalesce((p->>'waive_service_charge')::boolean,false);
  v_exp timestamptz := nullif(p->>'expected_updated_at','')::timestamptz; v_sc numeric(10,2); v_raw numeric(10,2); v_total numeric(10,2); v_paid numeric; v_s jsonb; v_food_gst numeric(10,2);
begin
  select * into v_o from public.orders where id = (p->>'order_id')::uuid for update;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id() then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can change the bill'; end if;
  if v_exp is not null and v_exp <> v_o.updated_at then raise exception 'POS_STALE: this order was changed on another device'; end if;
  if v_o.status in ('paid','cancelled') then raise exception 'POS_WRONG_STATE: this order is already %', v_o.status; end if;
  -- 0645: a restaurant's generated bill is locked: an admin PIN and a note
  perform public.rst_admin__guard(v_o, p, 'service_charge');
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
end $f$;

CREATE OR REPLACE FUNCTION public.rst_items_cancel(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare o public.orders%rowtype; c jsonb; v_reason text := btrim(coalesce(p->>'reason', '')); v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  v_begin jsonb; v_scope text; v_res jsonb; v_lines jsonb; v_admin uuid;
begin
  o := public.rst_adj__lock(nullif(p->>'order_id', '')::uuid);
  if not (public.has_permission(o.organization_id, 'order', 'update_status', o.location_id) or public.has_permission(o.organization_id, 'order', 'place', o.location_id)) then
    raise exception 'POS_FORBIDDEN: your role cannot change orders'; end if;
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an idempotency key is required'; end if;
  v_scope := 'rst_items_cancel:' || o.id;
  v_begin := public.idempotency_begin(v_scope, v_key, md5((p - 'idempotency_key')::text));
  if v_begin->>'state' = 'replay' then return (v_begin->'response') || jsonb_build_object('replayed', true); end if;
  if char_length(v_reason) not between 3 and 200 then raise exception 'POS_BAD_REQUEST: say why (3 to 200 characters)'; end if;
  -- the same dish asked as {item_id, qty} in any order is the same request
  begin
    select jsonb_agg(jsonb_build_object('item_id', (x->>'item_id')::uuid, 'qty', (x->>'qty')::int) order by x->>'item_id') into v_lines
      from jsonb_array_elements(case when jsonb_typeof(p->'items') = 'array' then p->'items' else '[]'::jsonb end) x;
  exception when others then raise exception 'POS_BAD_REQUEST: choose the dish and how many again'; end;
  c := public.rst_adj__cancel_check(o, coalesce(v_lines, '[]'::jsonb));
  -- 0645: on a generated bill an admin PIN and a note do it (no manager request)
  v_admin := public.rst_admin__guard(o, p, 'item_cancel');
  if (c->>'needs_manager')::boolean and not public.rst_adj__mgr() and v_admin is null then
    v_res := public.rst_adj__ask(o, 'item_cancel', jsonb_build_object('lines', v_lines, 'label', (select string_agg((l->>'qty') || '× ' || (l->>'name'), ', ') from jsonb_array_elements(c->'lines') l)), (c->>'value')::numeric, v_reason,
                                 array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'finance_manager']);
  else
    v_res := public.rst_adj__cancel_apply(o, c, v_reason, auth.uid(), null, v_key);
  end if;
  v_res := v_res || jsonb_build_object('order', public.rst_adj__view(o.id));
  perform public.idempotency_complete(v_scope, v_key, v_res - 'replayed');   -- a replay of this key says replayed: true
  return jsonb_build_object('replayed', false) || v_res;
end $f$;

CREATE OR REPLACE FUNCTION public.pos_set_order_status(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_o public.orders%rowtype; v_to text := p->>'to'; v_exp timestamptz := nullif(p->>'expected_updated_at','')::timestamptz; v_kot uuid;
  v_ok boolean; f public.pos_fulfilments%rowtype;
begin
  select * into v_o from public.orders where id = (p->>'order_id')::uuid for update;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id() then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_o.organization_id, 'order', 'update_status', v_o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot change order status'; end if;
  if v_exp is not null and v_exp <> v_o.updated_at then raise exception 'POS_STALE: this order was changed on another device'; end if;
  v_ok := (v_o.status, v_to) in (('new','in_billing'),('new','sent_to_kitchen'),('new','cancelled'),
    ('in_billing','sent_to_kitchen'),('in_billing','awaiting_payment'),('in_billing','cancelled'),
    ('sent_to_kitchen','ready'),('sent_to_kitchen','awaiting_payment'),('sent_to_kitchen','cancelled'),
    ('ready','delivered'),('ready','awaiting_payment'),('ready','cancelled'),('delivered','awaiting_payment'),('awaiting_payment','cancelled'),('paid','cancelled'));
  if not v_ok then raise exception 'POS_WRONG_STATE: cannot move an order from % to %', v_o.status, v_to; end if;
  if v_to = 'cancelled' then
    if coalesce(btrim(p->>'reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to cancel'; end if;
    -- 0645: a restaurant order with the kitchen or a generated bill: an admin PIN and a note, logged with who cancelled it
    if coalesce(current_setting('app.rst_cancel_ok', true), '') <> 'on' then perform public.rst_admin__guard(v_o, p, 'order_cancel'); end if;
    if (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id and method <> 'due')
       - (select coalesce(sum(amount), 0) from public.pos_refunds where order_id = v_o.id) > 0.005 then
      raise exception 'POS_HAS_PAYMENTS: refund the payments before cancelling'; end if;
    select * into f from public.pos_fulfilments where order_id = v_o.id for update;
    if found then
      if f.stage = 'dispatched' then raise exception 'POS_WRONG_STATE: bring the order back to the store before cancelling it'; end if;
      perform public.pos_fulfilment_arm(f.order_id, 'cancelled', f.version + 1);
      update public.pos_fulfilments set stage = 'cancelled', version = f.version + 1, exception = null, exception_note = null where order_id = f.order_id;
    end if;
    update public.order_items set status = 'cancelled' where order_id = v_o.id;
    update public.kot_tickets set status = 'cancelled', updated_at = now() where order_id = v_o.id and status not in ('delivered');
  elsif v_to = 'sent_to_kitchen' and not exists (select 1 from public.kot_tickets where order_id = v_o.id) then
    insert into public.kot_tickets (organization_id, order_id, kot_no, station, status) values (v_o.organization_id, v_o.id, public.next_org_seq(v_o.organization_id,'kot'), 'main', 'new') returning id into v_kot;
    update public.order_items set kot_ticket_id = v_kot where order_id = v_o.id and kot_ticket_id is null;
  elsif v_to = 'ready' then
    update public.kot_tickets set status = 'ready', updated_at = now() where order_id = v_o.id and status in ('new','preparing');
    update public.order_items set status = 'ready' where order_id = v_o.id and status in ('pending','preparing');
  end if;
  perform public.status_gate('orders', v_o.id, 'set_' || v_to);
  update public.orders set status = v_to, updated_at = now() where id = v_o.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_o.organization_id, v_o.id, 'status_' || v_to, v_o.display_no || ' -> ' || v_to, 'pos', jsonb_build_object('by', auth.uid(), 'from', v_o.status, 'reason', p->>'reason'));
  return public.pos_order_json(v_o.id);
end $f$;

CREATE OR REPLACE FUNCTION public.rst_adj__void_apply(o orders, p_reason text, p_method text, p_key text, p_asked_by uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare m jsonb := public.rst_adj__money(o.id); v_left numeric := (m->>'refundable')::numeric; r jsonb; v_new public.orders%rowtype;
  v_approver uuid := case when p_asked_by is distinct from auth.uid() then auth.uid() end; v_refund uuid;
begin
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this bill is already void'; end if;
  if o.channel in ('online', 'swiggy', 'zomato') then raise exception 'POS_WRONG_STATE: an app or aggregator order is changed on its own platform'; end if;
  -- money taken and not yet refunded goes back first (the shared refund, as a cancellation), then the order is cancelled
  if v_left > 0.005 then
    if p_method is null or p_method not in ('cash', 'upi', 'card', 'other') then
      raise exception 'POS_BAD_REQUEST: % was paid on this bill; choose how it goes back', v_left; end if;
    r := public.pos_refund(jsonb_build_object('order_id', o.id, 'amount', v_left, 'method', p_method, 'kind', 'cancel',
                                              'reason', 'Bill void: ' || p_reason, 'idempotency_key', 'void:' || p_key));
    v_refund := (r->>'refund_id')::uuid;
  end if;
  -- a served order is billed before it can be cancelled (the order's own steps)
  if o.status = 'delivered' then perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'awaiting_payment')); end if;
  -- 0645: the void was the owner's own decision (0640): its cancel needs no admin PIN
  perform set_config('app.rst_cancel_ok', 'on', true);
  perform public.pos_set_order_status(jsonb_build_object('order_id', o.id, 'to', 'cancelled', 'reason', 'Bill void: ' || p_reason));
  perform set_config('app.rst_cancel_ok', 'off', true);
  select * into v_new from public.orders where id = o.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta, created_at)
  values (o.organization_id, o.id, 'bill_voided', coalesce(o.display_no, 'Bill') || ' voided' || case when v_refund is not null then ', ' || v_left || ' refunded' else '' end || ': ' || p_reason,
          'pos', jsonb_build_object('order_id', o.id, 'bill_id', o.id, 'reason', p_reason, 'by', coalesce(p_asked_by, auth.uid()), 'approved_by', v_approver,
                                    'request_id', p_request, 'reference', p_key, 'refund_id', v_refund, 'refund_amount', case when v_refund is not null then v_left else 0 end,
                                    'refund_method', case when v_refund is not null then p_method end, 'total', o.total,
                                    'status_before', o.status, 'status_after', v_new.status, 'payment_before', m->>'payment_status'),
          clock_timestamp());
  perform public.rst_adj__audit(o.organization_id, 'rst.bill_void', o.id, m || jsonb_build_object('status', o.status),
    public.rst_adj__money(o.id) || jsonb_build_object('status', v_new.status, 'reason', p_reason, 'refund_id', v_refund, 'by', coalesce(p_asked_by, auth.uid()),
                                                      'approved_by', v_approver, 'request_id', p_request, 'reference', p_key));
  return jsonb_build_object('status', 'voided', 'order_id', o.id, 'refund_id', v_refund, 'refunded', case when v_refund is not null then v_left else 0 end,
                            'approved_by', v_approver);
end $f$;

-- the Leakage audit and the owner's dashboard

CREATE OR REPLACE FUNCTION public.rst_report_audit(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p);
  v_all boolean := nullif(p->>'location_id', '') is null and public.money_unbound(v_org); w record; v_today_start timestamptz;
begin
  if not public.has_permission(v_org, 'pos_audit_log', 'read', null) then raise exception 'MONEY_FORBIDDEN: your role cannot see the audit'; end if;
  select * into w from public.rst_rep__window(p);
  v_today_start := ((now() at time zone w.tz)::date)::timestamp at time zone w.tz;
  return (
    with mine as (select o.* from public.orders o where o.organization_id = v_org and (o.location_id = any (v_locs) or (o.location_id is null and v_all))),
    cancelled as (
      select o.*, (select coalesce(sum(round(i.unit_price * i.qty * 100)), 0) from public.order_items i where i.order_id = o.id) value_minor,
             exists (select 1 from public.order_events e where e.order_id = o.id and e.kind = 'kot_fired') kot_sent,
             public.order_cancel_info(o.id) info,
             (select e.meta->>'by' from public.order_events e where e.order_id = o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1) by_user
        from mine o where o.status = 'cancelled' and o.updated_at >= w.t_from and o.updated_at < w.t_to),
    unpaid as (
      -- 0645: a bill shows at once, by when it was generated (not when the order was opened, nor only after the day ends)
      select o.* from mine o, lateral (select coalesce((select max(e.created_at) from public.order_events e where e.order_id = o.id and e.kind = 'status_awaiting_payment'), o.created_at) as billed_at) g
       where o.status = 'awaiting_payment' and g.billed_at >= w.t_from and g.billed_at < w.t_to),
    ev as (
      select e.*, o.display_no, o.order_no from public.order_events e join mine o on o.id = e.order_id
       where e.created_at >= w.t_from and e.created_at < w.t_to),
    reprints as (select * from ev where kind like 'receipt\_%' or kind = 'kot_reprinted'),
    after_bill as (
      select * from ev where kind in ('items_added', 'coupon_applied', 'payment_cancelled', 'service_charge_waived', 'service_charge_restored', 'table_transferred',
                                     'manual_discount', 'manual_discount_removed', 'item_cancelled')
         and exists (select 1 from public.order_events b where b.order_id = ev.order_id and b.kind = 'status_awaiting_payment' and b.created_at < ev.created_at)),
    -- 0645: changes made with an admin PIN (a generated bill changed, an order cancelled after its KOT)
    overrides as (select * from ev where kind = 'admin_override'),
    refunds as (
      select r.*, o.display_no, o.order_no from public.pos_refunds r left join public.orders o on o.id = r.order_id
       where r.organization_id = v_org and r.created_at >= w.t_from and r.created_at < w.t_to
         and (coalesce(r.location_id, o.location_id) = any (v_locs) or (coalesce(r.location_id, o.location_id) is null and v_all)))
    select jsonb_build_object('from', w.d_from, 'to', w.d_to,
      'cancelled', jsonb_build_object('bills', (select count(*) from cancelled), 'value_minor', (select coalesce(sum(value_minor), 0) from cancelled),
        'after_kot', (select count(*) from cancelled where kot_sent),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', c.id, 'bill', coalesce(c.display_no, c.order_no::text), 'at', c.updated_at, 'channel', c.channel,
                   'value_minor', c.value_minor, 'kot_sent', c.kot_sent, 'by', coalesce(public.money_person(v_org, nullif(c.by_user, '')::uuid), c.info->>'by'),
                   'reason', c.info->>'reason') order by c.updated_at desc), '[]'::jsonb) from cancelled c)),
      'unpaid', jsonb_build_object('bills', (select count(*) from unpaid), 'value_minor', (select coalesce(sum(total_minor), 0) from unpaid),
        'list', (select coalesce(jsonb_agg(public.rst_rep__bill(u, w.tz) order by u.created_at desc), '[]'::jsonb) from unpaid u)),
      'reprints', jsonb_build_object('count', (select count(*) from reprints),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', r.order_id, 'bill', coalesce(r.display_no, r.order_no::text), 'at', r.created_at, 'kind', r.kind,
                   'what', r.message, 'by', public.money_person(v_org, nullif(r.meta->>'by', '')::uuid)) order by r.created_at desc), '[]'::jsonb) from reprints r)),
      'after_bill', jsonb_build_object('count', (select count(*) from after_bill),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', a.order_id, 'bill', coalesce(a.display_no, a.order_no::text), 'at', a.created_at, 'kind', a.kind,
                   'what', a.message, 'by', public.money_person(v_org, nullif(a.meta->>'by', '')::uuid)) order by a.created_at desc), '[]'::jsonb) from after_bill a)),
      'refunds', jsonb_build_object('count', (select count(*) from refunds), 'amount_minor', (select coalesce(sum(amount_minor), 0) from refunds),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', r.order_id, 'bill', coalesce(r.display_no, r.order_no::text), 'at', r.created_at, 'kind', r.kind,
                   'method', r.method, 'amount_minor', r.amount_minor, 'reason', r.reason, 'by', public.money_person(v_org, r.created_by)) order by r.created_at desc), '[]'::jsonb)
                 from refunds r)),
      'overrides', jsonb_build_object('count', (select count(*) from overrides),
        'list', (select coalesce(jsonb_agg(jsonb_build_object('order_id', x.order_id, 'bill', coalesce(x.display_no, x.order_no::text), 'at', x.created_at,
                   'action', x.meta->>'action', 'what', x.message, 'note', x.meta->>'note', 'by', public.money_person(v_org, nullif(x.meta->>'by', '')::uuid),
                   'approved_by', public.money_person(v_org, nullif(x.meta->>'approved_by', '')::uuid), 'total_minor', round(coalesce((x.meta->>'total')::numeric, 0) * 100))
                   order by x.created_at desc), '[]'::jsonb) from overrides x)),
      'not_recorded', jsonb_build_array('price_edit')));
end $f$;

CREATE OR REPLACE FUNCTION public.rst_home_insights(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $f$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.total, o.channel,
             case when o.channel = 'dine_in' then 'dine_in' when o.channel = 'pickup' then 'takeaway' else 'delivery' end as served
        from public.orders o
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
    ), li as (
      select i.menu_item_id, i.name, i.qty, i.unit_price from public.order_items i join o on o.id = i.order_id where i.status <> 'cancelled'
    ), dishes as materialized (
      select m.id, m.name, m.is_available, m.image_url, m.description,
             public.menu_can_make(v_org, m.id) as can_make,
             exists (select 1 from public.menu_item_recipes r where r.menu_item_id = m.id and r.organization_id = v_org) as has_recipe,
             (public.mb_recipe_json(v_org, m.id)->>'food_cost_pct')::numeric as food_pct
        from public.menu_items m where m.organization_id = v_org
    )
    select jsonb_build_object(
      'mix', jsonb_build_object(
        'orders', (select count(*) from o),
        'sales', (select coalesce(sum(total), 0) from o),
        'avg_bill', (select coalesce(round(avg(total), 2), 0) from o),
        'by', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label,
                  'orders', (select count(*) from o where o.served = k.key), 'sales', (select coalesce(sum(o.total), 0) from o where o.served = k.key)) order by k.sort)
               from (values ('dine_in', 'Dine in', 1), ('takeaway', 'Takeaway', 2), ('delivery', 'Delivery', 3)) k(key, label, sort))),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', x.method, 'amount', x.amount, 'count', x.n) order by x.amount desc), '[]')
                     from (select pm.method, sum(pm.amount) as amount, count(*) as n from public.payments pm
                            where pm.organization_id = v_org and pm.created_at >= v_since and pm.amount > 0
                              and (v_loc is null or exists (select 1 from public.orders x where x.id = pm.order_id and x.location_id = v_loc))
                            group by pm.method) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'sales', t.sales) order by t.qty desc, t.sales desc), '[]')
                from (select li.name, sum(li.qty) as qty, sum(li.qty * li.unit_price) as sales from li group by li.name order by 2 desc, 3 desc limit 5) t),
      'menu', jsonb_build_object(
        'dishes', (select count(*) from dishes),
        'low', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'can_make', d.can_make) order by d.can_make, d.name), '[]')
                  from (select * from dishes where can_make is not null and can_make < 10 order by can_make, name limit 5) d),
        'out', (select count(*) from dishes where not is_available or can_make = 0),
        'food_cost_avg', (select round(avg(food_pct), 1) from dishes where food_pct is not null),
        'high_cost', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'pct', round(d.food_pct, 1)) order by d.food_pct desc), '[]')
                        from (select * from dishes where food_pct > 45 order by food_pct desc limit 5) d),
        'no_recipe', (select count(*) from dishes where not has_recipe),
        'no_photo', (select count(*) from dishes where coalesce(btrim(image_url), '') = ''),
        'no_description', (select count(*) from dishes where coalesce(btrim(description), '') = '')),
      'ready', (select count(*) from public.order_items i join o on o.id = i.order_id where i.status = 'ready'),
      -- 0645: revenue leakage: changes made today with an admin PIN (the owner's and the managers' who may see the audit)
      'leakage', case when public.has_permission(v_org, 'pos_audit_log', 'read', null) then (
        with x as (select e.*, od.display_no from public.order_events e join public.orders od on od.id = e.order_id
                    where e.organization_id = v_org and e.kind = 'admin_override' and e.created_at >= v_since
                      and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id))
        select jsonb_build_object('admin_changes', (select count(*) from x),
          'latest', (select coalesce(jsonb_agg(jsonb_build_object('bill', y.display_no, 'what', y.message, 'at', y.created_at,
                       'by', public.money_person(v_org, nullif(y.meta->>'by', '')::uuid), 'approved_by', public.money_person(v_org, nullif(y.meta->>'approved_by', '')::uuid))
                       order by y.created_at desc), '[]'::jsonb) from (select * from x order by created_at desc limit 3) y))) end
    )
  );
end $f$;

notify pgrst, 'reload schema';
commit;
