-- 0657 Payment and order rules hold for every caller (founder's finding, 2026-11-04): a signed-in cashier could call the database's
-- order writer and payment writer directly, skip the server and the bill step, record a payment as "other", and do it for an outlet
-- that is not theirs. The hosted copy (31 Oct) has the same grants. Local dev DB 2026-11-04.
--   1. The internal writers are no longer callable by signed-in users: pos_record_payment, pos_place_order, pos_adjust_bill,
--      pos_issue_table_qr, vinii_publish_storefront, inventory_record. Every app path reaches them through a checked wrapper
--      (rst_bill_pay, pos_checkout_pay, pos_split_pay, tbl_order_add, pos_counter_order, guest_request_decide, sf_publish, ...),
--      all SECURITY DEFINER, which still call them as their owner. No app or server code calls them by name (checked 2026-11-04).
--   2. The payment writer itself (the one place every payment is written) now also checks, whoever calls it:
--      - Master's pause (pos_capture);
--      - the order's outlet is one the caller may work in;
--      - the method is cash, UPI or card; "other" only for a delivery partner / prepaid settlement (Swiggy, Zomato, OneLocal app)
--        on a pickup or delivery order; "wallet" is not taken at the counter;
--      - a restaurant table order is paid only after its bill is generated (awaiting payment).
--   3. The order writer refuses an outlet the caller may not work in.
begin;

-- 1 ---------------------------------------------------------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p where p.pronamespace = 'public'::regnamespace
             and p.proname in ('pos_record_payment', 'pos_place_order', 'pos_adjust_bill', 'pos_issue_table_qr', 'vinii_publish_storefront', 'inventory_record') loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- 2 ---------------------------------------------------------------------------------------------------------------------------
do $$
declare v_src text := pg_get_functiondef('public.pos_record_payment'::regproc);
  v_role text := $r$  if not public.has_org_role(array['org_owner','org_admin','manager','biller','business_manager','location_manager','finance_manager']) then raise exception 'POS_FORBIDDEN: your role cannot take payments'; end if;$r$;
  v_meth text := $r$  if v_method not in ('cash','upi','card','wallet','other') then raise exception 'POS_BAD_REQUEST: unknown payment method'; end if;$r$;
  v_state text := $r$  if v_o.status in ('paid','cancelled') then raise exception 'POS_WRONG_STATE: this order is already %', v_o.status; end if;$r$;
begin
  if v_src like '%0657:%' then return; end if;
  if position(v_role in v_src) = 0 or position(v_meth in v_src) = 0 or position(v_state in v_src) = 0 then
    raise exception '0657: pos_record_payment has changed shape; patch it by hand'; end if;
  v_src := replace(v_src, v_role, v_role || $r$
  -- 0657: the same rules for every caller (a direct call cannot skip them)
  perform public.require_via_master('pos_capture');
  if not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_FORBIDDEN: this order belongs to an outlet you do not work in'; end if;$r$);
  v_src := replace(v_src, v_meth, $r$  if v_method not in ('cash','upi','card','other') then raise exception 'POS_BAD_REQUEST: choose cash, card or UPI'; end if;
  -- 0657: "other" is only a delivery partner's or a prepaid app's settlement on a pickup / delivery order, named in the reference
  if v_method = 'other' and not (v_o.channel::text in ('pickup', 'delivery') and btrim(coalesce(p->>'reference', '')) in ('Swiggy', 'Zomato', 'OneLocal app')) then
    raise exception 'POS_BAD_REQUEST: choose cash, card or UPI'; end if;$r$);
  v_src := replace(v_src, v_state, v_state || $r$
  -- 0657: a restaurant table order is paid only after its bill is generated
  if v_o.table_id is not null and v_o.status <> 'awaiting_payment' and public.pos_org_is_restaurant(v_o.organization_id) then
    raise exception 'POS_WRONG_STATE: generate the bill first'; end if;$r$);
  execute v_src;
end $$;

-- 3 ---------------------------------------------------------------------------------------------------------------------------
do $$
declare v_src text := pg_get_functiondef('public.pos_place_order'::regproc);
  v_old text := $r$  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;$r$;
begin
  if v_src like '%0657:%' then return; end if;
  if position(v_old in v_src) = 0 then raise exception '0657: pos_place_order has changed shape; patch it by hand'; end if;
  v_src := replace(v_src, v_old, v_old || $r$
  -- 0657: an order is placed only in an outlet the caller may work in
  if not public.location_is_allowed(v_org, v_loc) then raise exception 'POS_FORBIDDEN: this outlet is not one you work in'; end if;$r$);
  execute v_src;
end $$;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0657_payment_rules_enforced.sql', 'Order and payment writers not callable directly by signed-in users; payment writer checks Master pause, outlet, method and generated bill for every caller; order writer checks outlet (local dev DB 2026-11-04)')
on conflict do nothing;
commit;
