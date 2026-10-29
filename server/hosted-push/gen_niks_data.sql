-- Builds hosted-push/02_niks_cafe_data.sql from the LOCAL test DB (run by build.sh; reads only). For each table, in an order that
-- satisfies the foreign keys, it emits one statement that writes Niks Cafe's rows by primary key:
--   insert into public.T (cols) select cols from jsonb_populate_recordset(null::public.T, '<rows>') on conflict (pk) do update ...
-- Rows that point at a local person (updated_by, qr_issued_by) lose that link: the local test logins do not exist on hosted.
-- Dish photo links move from the local storage address to the hosted project.
\pset format unaligned
\pset tuples_only on
\set org '''bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'''

create or replace function pg_temp.push_rows(t text, filter text, merge boolean) returns text language plpgsql as $f$
declare
  cols text; pk text; upd text; rows jsonb;
begin
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
     and not (t = 'purchase_events' and a.attname = 'id');
  select string_agg(quote_ident(a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = ('public.' || t)::regclass and i.indisprimary;
  select string_agg(format('%1$I = excluded.%1$I', a.attname), ', ' order by a.attnum) into upd
    from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
     and a.attname not in (select a2.attname from pg_index i join pg_attribute a2 on a2.attrelid = i.indrelid and a2.attnum = any(i.indkey)
                            where i.indrelid = ('public.' || t)::regclass and i.indisprimary);
  execute format('select coalesce(jsonb_agg(to_jsonb(x) - ''updated_by'' - ''qr_issued_by''), ''[]'') from public.%I x where %s', t, filter) into rows;
  if jsonb_array_length(rows) = 0 then return format('-- %s: nothing to copy', t); end if;
  return format(E'-- %s: %s row(s)\ninsert into public.%I (%s)\nselect %s from jsonb_populate_recordset(null::public.%I, $rows$%s$rows$::jsonb) r\n%s;',
    t, jsonb_array_length(rows), t, cols, cols, t,
    replace(rows::text, 'http://127.0.0.1:54321/storage/', 'https://ywylhzcxuoeilygzdonx.supabase.co/storage/'),
    case when t = 'purchase_events' then 'where not exists (select 1 from public.purchase_events e where e.po_row_id = r.po_row_id and e.created_at = r.created_at)'
         when merge then format('on conflict (%s) do update set %s', pk, upd)
         else format('on conflict (%s) do nothing', pk) end);
end $f$;

select pg_temp.push_rows(t, format('organization_id = %L', :org), true)
  from unnest(array[
    'menu_categories', 'menu_items', 'menu_item_variants',
    'inventory_items', 'ingredient_profiles', 'menu_item_recipes',
    'menu_addon_groups', 'menu_addons', 'menu_item_addon_groups', 'menu_addon_recipes',
    'menu_combos', 'menu_combo_items', 'menu_combo_groups', 'menu_combo_group_combos', 'menu_item_combo_groups',
    'menu_item_channel_prices',
    'dining_tables',
    'pos_suppliers', 'pos_supplier_prices', 'pos_purchase_orders', 'pos_purchase_order_lines', 'purchase_events'
  ]) with ordinality as u(t, n)
 order by n;
