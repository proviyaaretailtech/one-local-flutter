-- ==========================================================================================================================
-- HOSTED CHECK (read only): do the Day close (pos_day_*) and Delete account (acct_delete_*) functions exist on hosted? (3 Nov 2026)
-- The app and the server call them (Delete account opens from Manage account in every business, the restaurant's too; Day close from the
-- store's till), but no SQL for them is in the repo, in the local test database or in any local copy of hosted. The 31 Oct commit says
-- they were in C:\onelocal\hosted_pending_2026-10-31_FINAL.sql ("already applied"); that file is not on this computer.
-- This only reads the catalog. Nothing is written. Project ywylhzcxuoeilygzdonx. The result is one table: send it back as it is.
-- ==========================================================================================================================
with want(name, used_by) as (values
  ('acct_delete_preview',       'Manage account -> Delete account (every business)'),
  ('acct_delete_request',       'Manage account -> Delete account (every business)'),
  ('acct_delete_cancel',        'Manage account -> Delete account (every business)'),
  ('pos_day_today',             'Store till: business day'),
  ('pos_day_opening_set',       'Store till: business day'),
  ('pos_day_adjustment_decide', 'Store till: business day'),
  ('pos_day_cash_count',        'Store till: business day'),
  ('pos_day_close',             'Store till: business day'),
  ('pos_day_list',              'Store till: business day'),
  ('pos_day_get',               'Store till: business day'),
  ('pos_day_stock',             'Store till: business day')),
fns as (
  select p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef, md5(pg_get_functiondef(p.oid)) def_md5,
         has_function_privilege('authenticated', p.oid, 'execute') auth_can_run
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like 'pos\_day\_%' or p.proname like 'acct\_delete\_%' or p.proname like 'acct\_%delet%'))
select '1 function' as kind, w.name, w.used_by,
       case when f.proname is null then 'MISSING' else 'present' end as state,
       f.args, f.prosecdef as security_definer, f.auth_can_run, left(f.def_md5, 10) as def_md5
  from want w left join fns f on f.proname = w.name
union all
-- functions with these prefixes on hosted that the app does not call (another name or an older version)
select '2 other function', f.proname, null, 'present', f.args, f.prosecdef, f.auth_can_run, left(f.def_md5, 10)
  from fns f where f.proname not in (select name from want)
union all
-- tables a business day or an account deletion would keep its rows in
select '3 table', c.relname, null, 'present', null, null, null, null
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
   and (c.relname ~ '(business_day|pos_day|day_adjust|day_count|day_stock)' or c.relname ~ '(delet|erasure)' or (c.relname ~ 'day_close' and c.relname !~ '^rmoney_'))
union all
-- whether scheduled jobs (pg_cron) are installed: a deletion after the 30-day grace would need one
select '4 extension', e.extname, null, 'installed', e.extversion, null, null, null
  from pg_extension e where e.extname = 'pg_cron'
order by 1, 2;
