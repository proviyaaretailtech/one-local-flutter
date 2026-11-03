-- ==========================================================================================================================
-- HOSTED EXPORT (read only): the Day close and Delete account SQL that is on hosted but in no file of the repo (3 Nov 2026).
-- Piece 34 found all of it on hosted: 11 functions the app calls, 8 helpers, acct_deletion_purge and 3 tables. This returns their full
-- definitions, the tables' columns, constraints, indexes and row security, and whether a scheduled job runs the purge, so they can be
-- kept in the repo (and the local test database) exactly as they are on hosted. Nothing is written. Project ywylhzcxuoeilygzdonx.
-- In the SQL editor: run it, then "Export" -> "Copy as CSV" (or Download CSV) and send that file: the definitions are long.
-- ==========================================================================================================================
with fns as (
  select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like 'pos\_day\_%' or p.proname like 'pos\_day\_\_%' or p.proname like 'acct\_delete\_%'
                                   or p.proname like 'acct\_deletion\_%')),
tabs as (
  select c.oid, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('pos_business_days', 'pos_day_cash_adjustments', 'pos_day_stock_snapshots', 'money_store_day_close')
      or (n.nspname = 'public' and c.relkind = 'r' and c.relname ~ '(account_delet|acct_delet|deletion_request)'))
select 1 as part, 'function' as kind, f.proname as name, pg_get_functiondef(f.oid) as definition
  from fns f
union all
-- who may run each function (the grants the editor would need to repeat)
select 2, 'grants', f.proname,
       'authenticated=' || has_function_privilege('authenticated', f.oid, 'execute') || ' anon=' || has_function_privilege('anon', f.oid, 'execute')
       || ' service_role=' || has_function_privilege('service_role', f.oid, 'execute')
  from fns f
union all
select 3, 'table columns', t.relname,
       (select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end
                            || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), ''), E',\n' order by a.attnum)
          from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
         where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped)
  from tabs t
union all
select 4, 'table constraints', t.relname, (select string_agg(c.conname || ': ' || pg_get_constraintdef(c.oid), E'\n' order by c.conname) from pg_constraint c where c.conrelid = t.oid)
  from tabs t
union all
select 5, 'table indexes', t.relname, (select string_agg(i.indexdef, E';\n' order by i.indexname) from pg_indexes i where i.schemaname = 'public' and i.tablename = t.relname)
  from tabs t
union all
select 6, 'table security', t.relname,
       'rls=' || (select c.relrowsecurity from pg_class c where c.oid = t.oid)
       || coalesce(E'\n' || (select string_agg(p.polname || ' ' || pg_get_expr(p.polqual, p.polrelid), E'\n') from pg_policy p where p.polrelid = t.oid), '')
       || E'\nauthenticated select=' || has_table_privilege('authenticated', t.oid, 'select')
  from tabs t
union all
-- the purge after the 30-day grace: is it scheduled?
select 7, 'cron job', j.jobname, j.schedule || ' | active=' || j.active || ' | ' || j.command
  from cron.job j
union all
select 7, 'cron job', '(none)', 'no scheduled job at all'
 where not exists (select 1 from cron.job)
order by 1, 3;
