-- 0601 Stock tags on the Menu (founder, 27 Oct 2026): beside "Available", a dish shows "Out of stock" (red) or "Low in stock" (orange)
-- worked out from its recipe (0600: menu_item_recipes) and its ingredients' stock. Read only. Safe to run again.
--   * out: an ingredient that has been stocked (it has stock movements) has less on hand than one serving needs (with wastage);
--   * low: an ingredient with a reorder level is at or below it.
-- Ingredients never stocked through receiving are not judged (a new business would otherwise see every dish "out").
-- A dish switched off on the menu is "out of stock" from menu_items.is_available already; this only adds what stock says.

begin;

create or replace function public.menu_stock_signals(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_items jsonb := '[]'; r record; v_state text; v_ing text; l record; v_on numeric;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  for r in select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org loop
    v_state := null; v_ing := null;
    for l in select mr.qty_per_unit, mr.wastage_pct, i.id, i.name, i.reorder_level
               from public.menu_item_recipes mr join public.inventory_items i on i.id = mr.inventory_item_id
              where mr.menu_item_id = r.menu_item_id and mr.organization_id = v_org
                and exists (select 1 from public.stock_movements m where m.organization_id = v_org and m.inventory_item_id = i.id)
              order by mr.is_key desc, i.name loop
      v_on := public.mb_on_hand(v_org, l.id);
      if v_on < l.qty_per_unit * (1 + l.wastage_pct / 100) then
        v_state := 'out'; v_ing := l.name; exit;
      elsif l.reorder_level > 0 and v_on <= l.reorder_level and v_state is null then
        v_state := 'low'; v_ing := l.name;
      end if;
    end loop;
    if v_state is not null then
      v_items := v_items || jsonb_build_object('menu_item_id', r.menu_item_id, 'state', v_state, 'ingredient', v_ing);
    end if;
  end loop;
  return jsonb_build_object('items', v_items);
end $$;

revoke all on function public.menu_stock_signals(jsonb) from public, anon;
grant execute on function public.menu_stock_signals(jsonb) to authenticated, service_role;

commit;
