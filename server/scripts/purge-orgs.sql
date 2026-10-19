-- DEV ONLY (local OrbStack). Removes the orders, lines, payments, holds and fulfilment rows of the test businesses named in the session
-- setting purge.orgs (comma-separated ids), then those businesses. Scoped so a stuck leftover elsewhere (database/purge_test_orders.sh
-- trips on old service-test rows) cannot keep this script's data behind. Used by scripts/orders-live-hold-e2e.mjs.
begin;
create temp table _t on commit drop as select id from public.orders where organization_id::text = any (string_to_array(current_setting('purge.orgs'), ','))
  and exists (select 1 from public.organizations g where g.id = orders.organization_id and g.name like 'Golden ZZ%');
do $$
declare r record; guarded text[] := '{}'; t text;
begin
  for r in select distinct c.conrelid::regclass::text as tbl from pg_constraint c where c.confrelid = 'public.orders'::regclass and c.contype = 'f' loop
    guarded := guarded || r.tbl;
  end loop;
  guarded := guarded || array['public.audit_logs', 'public.order_items', 'public.payments'];
  foreach t in array guarded loop execute format('alter table %s disable trigger user', t); end loop;
  for r in select distinct c.conrelid::regclass::text as tbl, a.attname as col from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.confrelid = 'public.payments'::regclass and c.contype = 'f' loop
    execute format('alter table %s disable trigger user', r.tbl);
    execute format('delete from %s where %I in (select id from public.payments where order_id in (select id from _t))', r.tbl, r.col);
    execute format('alter table %s enable trigger user', r.tbl);
  end loop;
  for r in select distinct c.conrelid::regclass::text as tbl, a.attname as col from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.confrelid = 'public.order_items'::regclass and c.contype = 'f' loop
    execute format('alter table %s disable trigger user', r.tbl);
    execute format('delete from %s where %I in (select id from public.order_items where order_id in (select id from _t))', r.tbl, r.col);
    execute format('alter table %s enable trigger user', r.tbl);
  end loop;
  for r in select c.conrelid::regclass::text as tbl, a.attname as col from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.confrelid = 'public.orders'::regclass and c.contype = 'f' order by (c.conrelid::regclass::text = 'public.order_items') loop
    execute format('delete from %s where %I in (select id from _t)', r.tbl, r.col);
  end loop;
  delete from public.orders where id in (select id from _t);
  create temp table _o on commit drop as select id from public.organizations where id::text = any (string_to_array(current_setting('purge.orgs'), ',')) and name like 'Golden ZZ%'
    and not exists (select 1 from public.orders o where o.organization_id = organizations.id);
  delete from public.audit_logs where organization_id in (select id from _o) or entity_id in (select id::text from _o);
  delete from public.menu_items where organization_id in (select id from _o);
  delete from public.organizations where id in (select id from _o);
  foreach t in array guarded loop execute format('alter table %s enable trigger user', t); end loop;
end $$;
commit;
select 'left: ' || count(*) || ' test businesses' from public.organizations where id::text = any (string_to_array(current_setting('purge.orgs'), ','));
