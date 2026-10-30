-- 0632: a barcode scanner at Inventory (founder, 30 Oct 2026). Ingredients carry their barcode (inventory_items.barcode, already
-- unique per business): ing_list answers it and a scanned code finds its ingredient; ing_save sets it ('' clears it) and says
-- clearly when another item already has that code. Rewritten in place from 0600's definitions (the same on hosted).
do $$
declare v_def text; v_new text;
begin
  -- ing_list: the barcode on each ingredient; a search equal to a barcode finds it
  v_def := pg_get_functiondef('public.ing_list(jsonb)'::regprocedure);
  if position('''barcode'', r.barcode' in v_def) = 0 then
    v_new := replace(v_def, '''sku'', r.sku, ''category'', r.category,', '''sku'', r.sku, ''barcode'', r.barcode, ''category'', r.category,');
    v_new := replace(v_new, 'or lower(coalesce(r.sku, '''')) like ''%'' || v_q || ''%'')',
                            'or lower(coalesce(r.sku, '''')) like ''%'' || v_q || ''%'' or lower(coalesce(r.barcode, '''')) = v_q)');
    if position('''barcode'', r.barcode' in v_new) = 0 or position('lower(coalesce(r.barcode, '''')) = v_q' in v_new) = 0 then
      raise exception '0632: ing_list is not the expected version; not changed';
    end if;
    execute v_new;
  end if;

  -- ing_save: an optional barcode
  v_def := pg_get_functiondef('public.ing_save(jsonb)'::regprocedure);
  if position('v_bar' in v_def) = 0 then
    v_new := replace(v_def, 'v_reorder numeric := coalesce(nullif(p->>''reorder_level'', '''')::numeric, 0); v_cost bigint;',
      'v_reorder numeric := coalesce(nullif(p->>''reorder_level'', '''')::numeric, 0); v_cost bigint;
  v_bar text := nullif(regexp_replace(coalesce(p->>''barcode'', ''''), ''\s'', '''', ''g''), ''''); v_owner text;');
    v_new := replace(v_new, '  insert into public.ingredient_profiles (inventory_item_id, organization_id, cost_minor, is_veg)',
      '  -- the barcode (0632): set when given, cleared with ''''; one item per code in a business
  if p ? ''barcode'' then
    if v_bar is not null and v_bar !~ ''^[A-Za-z0-9._-]{4,48}$'' then raise exception ''POS_BAD_REQUEST: a barcode is 4 to 48 letters or digits''; end if;
    select x.name into v_owner from public.inventory_items x where x.organization_id = v_org and x.barcode = v_bar and x.id <> i.id;
    if v_owner is not null then raise exception ''POS_CONFLICT: this barcode is already on %'', v_owner; end if;
    update public.inventory_items set barcode = v_bar, updated_at = now() where id = i.id;
  end if;
  insert into public.ingredient_profiles (inventory_item_id, organization_id, cost_minor, is_veg)');
    if position('v_bar text :=' in v_new) = 0 or position('update public.inventory_items set barcode = v_bar' in v_new) = 0 then
      raise exception '0632: ing_save is not the expected version; not changed';
    end if;
    execute v_new;
  end if;
end $$;
