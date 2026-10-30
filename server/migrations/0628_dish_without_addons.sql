-- 0628: a dish without add-ons could not be ordered. 0624 wrote nullif(add_ons, '[]') into order_items.add_ons, which is NOT NULL
-- (default '[]'), so every plain dish was refused ("null value in column add_ons"), at a table and at the counter. Write '[]' instead.
-- The two functions that place dishes (pos_place_order, tbl_order_add) are rewritten in place from their live definitions.
do $$
declare r record; v_def text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('pos_place_order', 'tbl_order_add')
             and p.prosrc like '%nullif(e.x->''add_ons'', ''[]''::jsonb)%'
  loop
    v_def := replace(pg_get_functiondef(r.oid), 'nullif(e.x->''add_ons'', ''[]''::jsonb)', 'coalesce(e.x->''add_ons'', ''[]''::jsonb)');
    execute v_def;
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_proc where proname in ('pos_place_order', 'tbl_order_add') and prosrc like '%nullif(e.x->''add_ons''%') then
    raise exception '0628: a function still writes a null add_ons';
  end if;
end $$;
