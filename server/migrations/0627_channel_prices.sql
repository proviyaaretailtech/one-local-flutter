-- 0627: a dish's price on OneLocal, Zomato and Swiggy (founder, 29 Oct 2026: Price control shows Selling price, OneLocal, Zomato and Swiggy
-- prices). A dish without a channel price is sold there at its selling price. Set or cleared from Price control.
--   * menu_item_channel_prices; menu_channel_price_save; rcp_list rows: + channel_prices {onelocal, zomato, swiggy}
-- Safe to run again.

create table if not exists public.menu_item_channel_prices (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  channel text not null check (channel in ('onelocal', 'zomato', 'swiggy')),
  price numeric(10,2) not null check (price > 0 and price <= 100000),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (menu_item_id, channel)
);
alter table public.menu_item_channel_prices enable row level security;
revoke all on public.menu_item_channel_prices from anon, authenticated;

-- set a dish's price on one channel, or clear it ("price": null) so the selling price applies there
create or replace function public.menu_channel_price_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_item uuid := nullif(p->>'menu_item_id', '')::uuid; v_ch text := p->>'channel';
  v_price numeric := round(nullif(p->>'price', '')::numeric, 2);
begin
  if not exists (select 1 from public.menu_items where id = v_item and organization_id = v_org) then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if v_ch is null or v_ch not in ('onelocal', 'zomato', 'swiggy') then raise exception 'POS_BAD_REQUEST: choose OneLocal, Zomato or Swiggy'; end if;
  if v_price is null then
    delete from public.menu_item_channel_prices where menu_item_id = v_item and channel = v_ch;
  else
    if v_price <= 0 or v_price > 100000 then raise exception 'POS_BAD_REQUEST: enter a price above zero'; end if;
    insert into public.menu_item_channel_prices (organization_id, menu_item_id, channel, price, updated_by) values (v_org, v_item, v_ch, v_price, auth.uid())
    on conflict (menu_item_id, channel) do update set price = excluded.price, updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('menu_item_id', v_item, 'channel_prices', coalesce((select jsonb_object_agg(channel, price) from public.menu_item_channel_prices
                                                                                   where menu_item_id = v_item and organization_id = v_org), '{}'::jsonb));
end $$;
revoke all on function public.menu_channel_price_save(jsonb) from public, anon;
grant execute on function public.menu_channel_price_save(jsonb) to authenticated;

-- ---- existing function, patched (live definition + the 0627 change) ----
CREATE OR REPLACE FUNCTION public.rcp_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), ''));
  v_items jsonb := '[]'; r record; j jsonb; v_with int := 0; v_sum numeric := 0; v_n int := 0;
begin
  for r in select m.id from public.menu_items m left join public.menu_categories c on c.id = m.category_id
            where m.organization_id = v_org and (v_q = '' or lower(m.name) like '%' || v_q || '%')
            order by c.sort_order nulls last, c.name, m.sort_order, m.name loop
    j := public.mb_recipe_json(v_org, r.id) - 'lines'
      -- 0627: its price on each channel where one is set (else the selling price applies)
      || jsonb_build_object('channel_prices', coalesce((select jsonb_object_agg(cp.channel, cp.price) from public.menu_item_channel_prices cp
                                                          where cp.menu_item_id = r.id and cp.organization_id = v_org), '{}'::jsonb));
    if (j->>'line_count')::int > 0 then
      v_with := v_with + 1;
      if j->>'food_cost_pct' is not null then v_sum := v_sum + (j->>'food_cost_pct')::numeric; v_n := v_n + 1; end if;
    end if;
    v_items := v_items || j;
  end loop;
  return jsonb_build_object('items', v_items,
    'summary', jsonb_build_object('dishes', jsonb_array_length(v_items), 'with_recipe', v_with, 'without_recipe', jsonb_array_length(v_items) - v_with,
                                  'avg_food_cost_pct', case when v_n > 0 then round(v_sum / v_n, 1) end),
    -- 0626: every add-on with its recipe figures (the recipe master's Add-ons)
    'addons', coalesce((select jsonb_agg(public.mb_addon_recipe_json(v_org, ad.id) - 'lines' order by g.sort_order, g.name, ad.sort_order, ad.name)
                          from public.menu_addons ad join public.menu_addon_groups g on g.id = ad.group_id
                         where ad.organization_id = v_org and ad.active and (v_q = '' or lower(ad.name) like '%' || v_q || '%')), '[]'::jsonb));
end $$;
