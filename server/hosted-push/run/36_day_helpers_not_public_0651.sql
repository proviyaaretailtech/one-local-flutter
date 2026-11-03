-- ==========================================================================================================================
-- HOSTED: 0651 (the hosted part) The business day's internal helpers are no longer open to anyone (3 Nov 2026). One transaction: if it
-- stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- pos_day__can, pos_day__json, pos_day__today, pos_day__window_end and pos_day_cash_totals could be called by anyone, signed in or not
-- (anon = true in piece 34). They check nobody, and pos_day__json returns a store's whole business day (cash, who changed the opening
-- cash, stock counts) for a day id. Only the business day's own functions call them, so nothing else needs them. Nothing else changes:
-- the 19 functions, the tables and the two scheduled jobs stay as they are.
-- The last result is a fingerprint of each function (spaces evened out), to check the repo's copy (migration 0651) against hosted.
-- ==========================================================================================================================
begin;
revoke all on function public.pos_day__can(text), public.pos_day__json(uuid), public.pos_day__today(uuid), public.pos_day__window_end(uuid),
  public.pos_day_cash_totals(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.pos_day__can(text), public.pos_day__json(uuid), public.pos_day__today(uuid), public.pos_day__window_end(uuid),
  public.pos_day_cash_totals(uuid, timestamptz) to service_role;
commit;

select p.proname as name,
       left(md5(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')), 12) as fingerprint,
       has_function_privilege('anon', p.oid, 'execute') as anyone_can_run,
       has_function_privilege('authenticated', p.oid, 'execute') as signed_in_can_run
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and (p.proname like 'pos\_day\_%' or p.proname like 'acct\_delete\_%' or p.proname like 'acct\_deletion\_%')
 order by 1;
