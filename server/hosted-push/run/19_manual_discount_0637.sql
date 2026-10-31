-- ==========================================================================================================================
-- HOSTED: 0637 Manual discount at checkout (31 Oct 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- ₹ or % off a restaurant bill with a reason; above 10 % only a manager (recorded as approver); the Discounts report shows them.
-- ==========================================================================================================================
begin;
-- Stops here, changing nothing, if a function this relies on is missing (pieces 16 and 18 must be in).
do $$
declare v_missing text;
begin
  select string_agg(f, ', ') into v_missing
    from unnest(array['rst_bill_lock', 'rst_can_pay', 'tbl_order_reprice', 'rst_bill_order_json', 'rst_report_discounts', 'rst_rep__window', 'money_person', 'has_org_role']) f
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = f);
  if v_missing is not null then raise exception 'STOPPED, nothing changed: % missing on hosted', v_missing; end if;
  if position('customer_name' in pg_get_functiondef('public.rst_bill_order_json(uuid)'::regprocedure)) = 0 then
    raise exception 'STOPPED, nothing changed: run piece 16 first'; end if;
end $$;
-- 0637: a manual discount at checkout (founder, 31 Oct 2026: "Add a manual discount at checkout"). On a restaurant bill, before any
-- payment, the cashier takes ₹ or % off with a reason. Up to the business's limit (10 % unless set) anyone who may take payment can give
-- it; above it only a manager, owner or admin can, and they are recorded as the one who approved it. The discount is kept in ₹ (adding
-- dishes later keeps the same ₹ off), the bill is worked out again with the usual formula (GST, service charge, round off), and every
-- change is an order event with who, why and how much. 0 takes the manual discount off. A bill with a discount code takes no manual
-- discount (one discount per bill, as before). The bill now says whether its discount is manual, with the reason; the Discounts report
-- lists manual discounts with who gave them, why and who approved them.

alter table public.org_bill_settings add column if not exists manual_discount_limit_pct numeric(5,2) not null default 10
  check (manual_discount_limit_pct between 0 and 100);

create or replace function public.rst_bill_discount(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

  update public.orders set discount = v_amt where id = v_o.id;
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
end $$;
revoke all on function public.rst_bill_discount(jsonb) from public, anon;
grant execute on function public.rst_bill_discount(jsonb) to authenticated, service_role;

-- the bill says when its discount is manual: the reason, who gave it, who approved it, and the cashier's limit
create or replace function public.rst_bill_manual_discount(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select case when o.coupon_code is null and o.discount > 0 then
    (select jsonb_build_object('reason', e.meta->>'reason', 'kind', e.meta->>'kind', 'value', (e.meta->>'value')::numeric,
              'by', public.money_person(o.organization_id, nullif(e.meta->>'by', '')::uuid),
              'approved_by', public.money_person(o.organization_id, nullif(e.meta->>'approved_by', '')::uuid))
       from public.order_events e where e.order_id = o.id and e.kind = 'manual_discount' order by e.created_at desc limit 1) end
  from public.orders o where o.id = p_order;
$$;
revoke all on function public.rst_bill_manual_discount(uuid) from public, anon, authenticated;

do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.rst_bill_order_json(uuid)'::regprocedure);
  if position('rst_bill_manual_discount' in v_def) > 0 then return; end if;
  v_new := replace(v_def, '''coupon_code'', o.coupon_code,',
    '''coupon_code'', o.coupon_code, ''manual_discount'', public.rst_bill_manual_discount(o.id),
    ''discount_limit_pct'', coalesce((select s.manual_discount_limit_pct from public.org_bill_settings s where s.organization_id = o.organization_id), 10),');
  if v_new = v_def then raise exception '0637: rst_bill_order_json is not the expected definition'; end if;
  execute v_new;
end $$;

-- the Discounts report (0636) with manual discounts: kind, reason, who gave it and who approved it; manual and coupon totals apart
create or replace function public.rst_report_discounts(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
                  'reason', d.manual->>'reason', 'pct', (d.manual->>'pct')::numeric,
                  'given_by', public.money_person(v_org, nullif(d.manual->>'by', '')::uuid),
                  'approved_by', public.money_person(v_org, nullif(d.manual->>'approved_by', '')::uuid),
                  'waived_minor', d.waived_minor, 'waive_reason', nullif(d.waive_reason, ''), 'waived_by', public.money_person(v_org, nullif(d.waive_by, '')::uuid))
                  order by coalesce(d.paid_at, d.created_at) desc), '[]'::jsonb) from disc d),
      'free', (select coalesce(jsonb_agg(jsonb_build_object('order_id', f.oid, 'bill', f.bill, 'name', f.name, 'qty', f.qty)), '[]'::jsonb) from free f),
      'not_recorded', '[]'::jsonb));
end $$;

notify pgrst, 'reload schema';
commit;
