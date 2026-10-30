-- 0623: the business's current plan for Subscription plans (founder, 29 Oct 2026: subscription plans in the restaurant POS, same prices as
-- the store). Read from the business's approved partner application (pos_only | pos_and_onelocal), for anyone signed in to the business,
-- not only the person who applied. Read only. Safe to run again.
create or replace function public.org_sell_plan(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object('plan', (select a.sell_plan from public.ol_partner_applications a where a.organization_id = v_org and a.sell_plan is not null
                                      order by (a.status = 'approved') desc, a.updated_at desc nulls last limit 1));
end $$;
revoke all on function public.org_sell_plan(jsonb) from public, anon;
grant execute on function public.org_sell_plan(jsonb) to authenticated;
