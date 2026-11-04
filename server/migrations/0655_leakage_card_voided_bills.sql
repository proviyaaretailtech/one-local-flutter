-- 0655 (4 Nov 2026): the owner's Revenue leakage card on Home also counts bills voided today, with their value, and shows them among
-- the latest changes (founder: "leakage audit is not showing anything even if i did the void billing"). An owner's own void needs no
-- admin PIN, so the card read "None today" after one. Read-only: only rst_home_insights changes.
begin;
CREATE OR REPLACE FUNCTION public.rst_home_insights(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
  v_res jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  v_res := (
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
                      and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          -- 0655: bills voided today (the owner's own voids need no admin PIN, so they were missing here)
          vd as (select e.*, od.display_no from public.order_events e join public.orders od on od.id = e.order_id
                    where e.organization_id = v_org and e.kind = 'bill_voided' and e.created_at >= v_since
                      and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id))
        select jsonb_build_object('admin_changes', (select count(*) from x),
          'voided', (select count(*) from vd), 'voided_minor', (select coalesce(sum(round(coalesce((meta->>'total')::numeric, 0) * 100)), 0) from vd),
          -- 0650: bills left open at Day end and ended days reopened, today
          'unsettled', (select count(*) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'unsettled_due_minor', (select coalesce(sum((e.meta->>'due_minor')::bigint), 0) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'reopened', (select count(*) from public.rmoney_day_reopens r where r.organization_id = v_org and r.reopened_at >= v_since
                         and (v_loc is null or r.location_id = v_loc)),
          'latest', (select coalesce(jsonb_agg(jsonb_build_object('bill', y.display_no, 'what', y.message, 'at', y.created_at,
                       'by', public.money_person(v_org, nullif(y.meta->>'by', '')::uuid), 'approved_by', public.money_person(v_org, nullif(y.meta->>'approved_by', '')::uuid))
                       order by y.created_at desc), '[]'::jsonb) from (select * from (select * from x union all select * from vd) xv order by created_at desc limit 3) y))) end
    )
  );
  -- 0652: a kitchen or captain login (no money:read, no payment:record) gets no sales, payments or refunds
  if not public.rst__sees_money(v_org) then v_res := public.rst__strip_money(v_res) || jsonb_build_object('money_hidden', true); end if;
  return v_res;
end $function$;
commit;
