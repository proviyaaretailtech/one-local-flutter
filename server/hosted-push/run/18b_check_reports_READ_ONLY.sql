-- ==========================================================================================================================
-- HOSTED CHECK (read only): the seven restaurant reports (0636) against plain sums of the same bills. Run after piece 18 and after making
-- the test bills. It runs the reports as the owner of the business named below, compares, and ROLLS BACK: nothing is written.
-- The result is one table of PASS / FAIL rows. Business: Niks Cafe; period: today (India time). Change the name below to check another.
-- ==========================================================================================================================
begin;
create temp table chk_args as
select o.id org, (select ou.user_id from public.org_users ou join public.roles r on r.id = ou.role_id
                   where ou.organization_id = o.id and r.slug = 'org_owner' and ou.status = 'active' limit 1) owner,
       (now() at time zone 'Asia/Kolkata')::date d
  from public.organizations o where o.name = 'Niks Cafe' limit 1;
create temp table chk (n serial, result text, what text, report numeric, bills numeric);
grant all on chk_args, chk to authenticated; grant all on sequence chk_n_seq to authenticated;

-- the plain sums, straight from the bills (no report code)
create temp table plain as
select (select count(*) from public.orders o where o.organization_id = a.org and o.status in ('paid', 'delivered')
          and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) bills,
       (select coalesce(sum(subtotal_minor), 0) from public.orders o where o.organization_id = a.org and o.status in ('paid', 'delivered')
          and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) gross,
       (select coalesce(sum(discount_minor), 0) from public.orders o where o.organization_id = a.org and o.status in ('paid', 'delivered')
          and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) disc,
       (select coalesce(sum(gst_amount_minor), 0) from public.orders o where o.organization_id = a.org and o.status in ('paid', 'delivered')
          and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) gst,
       (select coalesce(sum(total_minor), 0) from public.orders o where o.organization_id = a.org and o.status in ('paid', 'delivered')
          and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) total,
       (select coalesce(sum(x.amount_minor), 0) from public.payments x where x.organization_id = a.org and x.method <> 'due'
          and (x.created_at at time zone 'Asia/Kolkata')::date = a.d) collected,
       (select coalesce(sum(r.amount_minor), 0) from public.pos_refunds r where r.organization_id = a.org and (r.created_at at time zone 'Asia/Kolkata')::date = a.d) refunds,
       (select count(*) from public.orders o where o.organization_id = a.org and o.status = 'cancelled' and (o.updated_at at time zone 'Asia/Kolkata')::date = a.d) cancelled,
       (select coalesce(sum(round(i.unit_price * i.qty * 100)), 0) from public.orders o join public.order_items i on i.order_id = o.id and i.status <> 'cancelled'
          where o.organization_id = a.org and o.status in ('paid', 'delivered') and (coalesce(o.paid_at, o.created_at) at time zone 'Asia/Kolkata')::date = a.d) items
  from chk_args a;
grant select on plain to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true) is null from chk_args;
set local role authenticated;
create temp table rep as
select public.rst_report_sales('{}') s, public.rst_report_items('{}') i, public.rst_report_categories('{}') c, public.rst_report_payments('{}') p,
       public.rst_report_cashiers('{}') k, public.rst_report_discounts('{}') ds, public.rst_report_audit('{}') au;
insert into chk (result, what, report, bills)
select case when x.r is not distinct from x.b then 'PASS' else 'FAIL' end, x.what, x.r, x.b from rep, plain, lateral (values
  ('Sales: completed bills', (s->'totals'->>'bills')::numeric, plain.bills),
  ('Sales: gross', (s->'totals'->>'gross_minor')::numeric, plain.gross),
  ('Sales: discounts', (s->'totals'->>'discount_minor')::numeric, plain.disc),
  ('Sales: net = gross − discounts', (s->'totals'->>'net_minor')::numeric, plain.gross - plain.disc),
  ('Sales: GST', (s->'totals'->>'gst_minor')::numeric, plain.gst),
  ('Sales: bill total', (s->'totals'->>'total_minor')::numeric, plain.total),
  ('Sales: refunds', (s->'totals'->>'refunds_minor')::numeric, plain.refunds),
  ('Sales: collected', (s->'totals'->>'collected_minor')::numeric, plain.collected),
  ('Sales: cancelled bills', (s->'cancelled'->>'bills')::numeric, plain.cancelled),
  ('Items: total = dishes sold', (i->>'total_minor')::numeric, plain.items),
  ('Items: total = gross', (i->>'total_minor')::numeric, plain.gross),
  ('Categories: total = gross', (c->>'total_minor')::numeric, plain.gross),
  ('Payments: collected', (p->>'collected_minor')::numeric, plain.collected),
  ('Payments: methods add up', (select coalesce(sum((m->>'amount_minor')::numeric), 0) from jsonb_array_elements(p->'methods') m where m->>'method' <> 'due'), plain.collected),
  ('Payments: refunds', (p->'refunds'->>'amount_minor')::numeric, plain.refunds),
  ('Cashiers: add up to collected', (select coalesce(sum((m.value)::numeric), 0) from jsonb_array_elements(k->'cashiers') x, jsonb_each_text(x->'methods') m where m.key <> 'due'), plain.collected),
  ('Discounts: total', (ds->'totals'->>'discount_minor')::numeric, plain.disc),
  ('Audit: cancelled bills', (au->'cancelled'->>'bills')::numeric, plain.cancelled),
  ('Audit: refunds', (au->'refunds'->>'amount_minor')::numeric, plain.refunds)
) x(what, r, b);
reset role;
select result, what, case when what like '%bills' then report::text else '₹' || round(report / 100.0, 2) end as in_the_report,
       case when what like '%bills' then bills::text else '₹' || round(bills / 100.0, 2) end as from_the_bills from chk order by n;
rollback;
