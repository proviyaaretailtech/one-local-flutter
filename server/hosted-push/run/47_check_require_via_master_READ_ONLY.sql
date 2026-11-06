-- HOSTED, READ ONLY (6 Nov 2026): does require_via_master exist, under any schema or argument list, and which functions call it?
-- Only reads the catalogue. Changes nothing. Expect a result table.
select 'exists' as what, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as name, pg_get_userbyid(p.proowner) as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where p.proname ilike '%via_master%' or p.proname ilike '%master_pause%' or p.proname ilike '%master%paus%'
union all
select 'calls it', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', pg_get_userbyid(p.proowner)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosrc like '%require_via_master%'
union all
select 'ledger', filename, coalesce(note, '') from public.schema_migrations_ledger
 where filename ~ '065[6-9]|066[0-9]'
order by 1, 2;
