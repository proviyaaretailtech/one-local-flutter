-- ==========================================================================================================================
-- HOSTED: 0652 Apply to Channels on a dish, and kitchen / captain logins see no money (3 Nov 2026). One transaction: if it stops with an
-- error, nothing has changed. Project ywylhzcxuoeilygzdonx. Restaurant functions only (no store or service function is changed).
-- A dish can be switched off for Table QR or the OneLocal app (guests then cannot order it there). Kitchen and captain logins get no
-- sales, payments or refunds on Home, and only the kitchen and floor events in the Activity log.
-- ==========================================================================================================================
begin;
-- 0652: the restaurant's dish channels, and kitchen / captain logins see no money (founder, 3 Nov 2026: "'Apply to Channels' on a dish is a
-- placeholder … Kitchen and captain logins can see sales and refund reasons in the Activity log and Home insights. Fix this; do not touch
-- service and store POS, only make changes in restaurant POS").
--   * Apply to Channels: rst_menu_item_view gives the dish's channels (Table QR, OneLocal app; on unless switched off) and rst_menu_item_save
--     takes them (menu:update). They are kept in item_channel_status ('qr', 'one_local'): OneLocal app orders already respect it
--     (ol_create_restaurant_order); guest__orderable (table QR orders) now does too. Swiggy and Zomato are switched off in their own apps.
--   * rst__sees_money: money:read or payment:record (owner, managers, cashiers, accounts); kitchen and captain logins have neither.
--   * rst_dashboard and rst_home_insights: for them no sales, payments, refunds or dish sales (money_hidden = true); orders, dishes and the
--     kitchen stay. rst_activity_log: for them only the kitchen and floor events (placed, KOT, ready, served, table moves, notes,
--     delivery steps), never payments, discounts, refunds, voids, cancellation reasons, approvals, customers or receipts (limited = true).
-- Store and service functions are not touched. Safe to run again.

create or replace function public.rst__sees_money(p_org uuid) returns boolean
  language sql stable security definer set search_path to 'public', 'pg_temp' as $f$
  select public.has_permission(p_org, 'money', 'read') or public.has_permission(p_org, 'payment', 'record');
$f$;
revoke all on function public.rst__sees_money(uuid) from public, anon, authenticated;

-- every money figure out of a dashboard answer, at any depth
create or replace function public.rst__strip_money(j jsonb) returns jsonb
  language plpgsql immutable set search_path to 'public', 'pg_temp' as $f$
declare k text; v jsonb; r jsonb;
begin
  if jsonb_typeof(j) = 'object' then
    r := '{}'::jsonb;
    for k, v in select * from jsonb_each(j) loop
      if k in ('sales', 'avg_bill', 'sales_today', 'payments', 'gross', 'refunds', 'paid_bills') then continue; end if;
      r := r || jsonb_build_object(k, public.rst__strip_money(v));
    end loop;
    return r;
  elsif jsonb_typeof(j) = 'array' then
    return coalesce((select jsonb_agg(public.rst__strip_money(e) order by o) from jsonb_array_elements(j) with ordinality x(e, o)), '[]'::jsonb);
  end if;
  return j;
end $f$;
revoke all on function public.rst__strip_money(jsonb) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rst_menu_item_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); m public.menu_items%rowtype; v_loc uuid; v_draft boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  select d.is_draft into v_draft from public.catalogue_item_details d where d.menu_item_id = m.id;
  return jsonb_build_object(
    'id', m.id, 'name', m.name, 'price_minor', coalesce(m.price_minor, round(m.price * 100)::bigint), 'currency', m.currency_code,
    'description', m.description, 'food_type', m.food_type, 'course', m.course, 'station', m.station, 'prep_minutes', m.prep_minutes,
    'image_url', m.image_url, 'images', case when nullif(btrim(coalesce(m.image_url, '')), '') is null then '[]'::jsonb else jsonb_build_array(m.image_url) end,
    'in_stock', m.is_available, 'draft', coalesce(v_draft, false),
    'category', (select jsonb_build_object('id', c.id, 'name', c.name) from public.menu_categories c where c.id = m.category_id),
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', r.qty_per_unit, 'unit', i.unit) order by lower(i.name)), '[]'::jsonb)
                      from public.menu_item_recipes r join public.inventory_items i on i.id = r.inventory_item_id
                     where r.menu_item_id = m.id and lower(i.name) <> lower(m.name)),
    'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'price_minor', round(v.price * 100)::bigint, 'is_default', v.is_default)
                   order by v.sort_order, v.name), '[]'::jsonb) from public.menu_item_variants v where v.menu_item_id = m.id),
    'availability', public.rst_menu_windows(m.id),
    'presets', jsonb_build_array(jsonb_build_object('slot', 'morning', 'starts_at', '06:00', 'ends_at', '12:00'),
                                 jsonb_build_object('slot', 'evening', 'starts_at', '16:00', 'ends_at', '20:00'),
                                 jsonb_build_object('slot', 'night', 'starts_at', '20:00', 'ends_at', '24:00')),
    'orderable_now', public.menu_item_orderable_at(m.id, now(), public.menu_outlet_tz(v_org, v_loc)),
    'location_id', v_loc,
    -- 0652: where the dish is sold besides the floor: guests ordering from the table QR, and the OneLocal app (on unless switched off)
    'channels', jsonb_build_object(
      'qr', not exists (select 1 from public.item_channel_status s where s.menu_item_id = m.id and s.channel = 'qr' and not s.is_available),
      'one_local', not exists (select 1 from public.item_channel_status s where s.menu_item_id = m.id and s.channel = 'one_local' and not s.is_available
                                 and (s.off_until is null or s.off_until > now()))),
    'version', m.edit_version,
    'can_edit', public.has_permission(v_org, 'menu', 'update'));
end $function$;

CREATE OR REPLACE FUNCTION public.rst_menu_item_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); m public.menu_items%rowtype; v_desc text; v_food text; w jsonb; v_slot text; v_s time; v_e time;
  v_days smallint[]; v_n int := 0; v_txt text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_permission(v_org, 'menu', 'update') then raise exception 'POS_FORBIDDEN: your role cannot change the menu'; end if;
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null then raise exception 'POS_BAD_REQUEST: refresh the dish and try again'; end if;
  if (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;

  v_desc := case when p ? 'description' then nullif(btrim(regexp_replace(coalesce(p->>'description', ''), '\s+', ' ', 'g')), '') else m.description end;
  if v_desc is not null and char_length(v_desc) > 500 then raise exception 'POS_BAD_REQUEST: a description is up to 500 characters'; end if;
  v_food := case when p ? 'food_type' then p->>'food_type' else m.food_type end;
  if v_food not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: food type is veg, non_veg or egg'; end if;

  if p ? 'availability' then
    if jsonb_typeof(p->'availability') <> 'array' then raise exception 'POS_BAD_REQUEST: availability is a list of windows'; end if;
    if jsonb_array_length(p->'availability') > 6 then raise exception 'POS_BAD_REQUEST: up to 6 serving windows per dish'; end if;
    delete from public.menu_item_availability where menu_item_id = m.id;
    for w in select * from jsonb_array_elements(p->'availability') loop
      v_slot := w->>'slot';
      if v_slot = 'morning' then v_s := '06:00'; v_e := '12:00';
      elsif v_slot = 'evening' then v_s := '16:00'; v_e := '20:00';
      elsif v_slot = 'night' then v_s := '20:00'; v_e := '24:00';
      elsif v_slot = 'custom' then
        if coalesce(w->>'starts_at', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(w->>'ends_at', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
          raise exception 'POS_BAD_REQUEST: a custom window needs a start and an end time (HH:MM)'; end if;
        v_s := (w->>'starts_at')::time; v_e := (w->>'ends_at')::time;
        if v_s = v_e then raise exception 'POS_BAD_REQUEST: a custom window cannot start and end at the same time'; end if;
      else raise exception 'POS_BAD_REQUEST: availability is morning, evening, night or custom'; end if;
      v_days := null;
      if w ? 'days' and jsonb_typeof(w->'days') = 'array' then
        if exists (select 1 from jsonb_array_elements(w->'days') d where jsonb_typeof(d) <> 'number' or (d::text)::int not between 1 and 7) then
          raise exception 'POS_BAD_REQUEST: days are 1 (Monday) to 7 (Sunday)'; end if;
        select array_agg(distinct (d::text)::smallint order by (d::text)::smallint) into v_days from jsonb_array_elements(w->'days') d;
        if v_days is not null and cardinality(v_days) = 7 then v_days := null; end if;
      end if;
      if exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id and a.starts_at = v_s and a.ends_at = v_e
                   and a.days is not distinct from v_days) then continue; end if;
      insert into public.menu_item_availability (organization_id, menu_item_id, slot, starts_at, ends_at, days)
      values (v_org, m.id, v_slot, v_s, v_e, v_days);
      v_n := v_n + 1;
    end loop;
  end if;

  -- 0652: Apply to Channels: Table QR and the OneLocal app, each on or off
  if p ? 'channels' then
    if jsonb_typeof(p->'channels') <> 'object' then raise exception 'POS_BAD_REQUEST: channels is qr and one_local, each true or false'; end if;
    if exists (select 1 from jsonb_each(p->'channels') c where c.key not in ('qr', 'one_local') or jsonb_typeof(c.value) <> 'boolean') then
      raise exception 'POS_BAD_REQUEST: channels is qr and one_local, each true or false'; end if;
    insert into public.item_channel_status (organization_id, menu_item_id, channel, is_available, off_until, updated_at)
    select v_org, m.id, c.key, (c.value)::text::boolean, null, now() from jsonb_each(p->'channels') c
    on conflict (menu_item_id, channel) do update set is_available = excluded.is_available, off_until = null, updated_at = now();
  end if;

  -- always an update, so the version moves even when only the windows changed
  update public.menu_items set description = v_desc, food_type = v_food, updated_at = now() where id = m.id;
  return public.rst_menu_item_view(jsonb_build_object('id', m.id, 'location_id', p->>'location_id'));
end $function$;

CREATE OR REPLACE FUNCTION public.guest__orderable(p_item uuid, p_loc uuid, p_def jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_ok boolean;
begin
  select m.is_available and coalesce((p_def->'items'->(m.id::text)->>'hidden')::boolean, false) is false into v_ok
    from public.menu_items m where m.id = p_item;
  if not coalesce(v_ok, false) then return false; end if;
  -- 0652: a dish switched off for Table QR (Apply to Channels) cannot be ordered from the table
  if exists (select 1 from public.item_channel_status s where s.menu_item_id = p_item and s.channel = 'qr' and not s.is_available) then return false; end if;
  if to_regprocedure('public.menu_item_orderable_now(uuid,uuid)') is not null then
    execute 'select public.menu_item_orderable_now($1, $2)' into v_ok using p_item, p_loc;
  end if;
  return coalesce(v_ok, false);
end $function$;

CREATE OR REPLACE FUNCTION public.rst_dashboard(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_lname text; v_today date; v_from timestamptz; v_to timestamptz;
  v_kot jsonb; v_tables jsonb; v_low jsonb; v_sales numeric; v_refunds numeric; v_paid int; v_live int; v_total int; v_ol jsonb; v_last7 jsonb; v_domain text; v_new int; v_items jsonb; v_prev7 jsonb; v_open int;
  v_res jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'RST_FORBIDDEN: sign in to a business first'; end if;
  if not (public.has_permission(v_org, 'order', 'place') or public.has_permission(v_org, 'order', 'update_status') or public.has_permission(v_org, 'dining_tables', 'manage')) then
    raise exception 'RST_FORBIDDEN: your role cannot see the restaurant dashboard'; end if;
  if v_loc is null then
    select l.id into v_loc from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)
      order by (l.code = 'MAIN') desc, l.created_at limit 1;
  end if;
  select timezone, name into v_tz, v_lname from public.locations where id = v_loc and organization_id = v_org;
  if v_tz is null or not public.location_is_allowed(v_org, v_loc) then raise exception 'RST_NOT_FOUND: store not found'; end if;
  select business_domain into v_domain from public.organizations where id = v_org;
  v_today := (now() at time zone v_tz)::date;
  v_from := v_today::timestamp at time zone v_tz; v_to := (v_today + 1)::timestamp at time zone v_tz;

  -- kitchen display counts (null when the role may not see the kitchen)
  begin
    v_kot := public.kds_queue(jsonb_build_object('location_id', v_loc));
    v_kot := (v_kot->'counts') || jsonb_build_object('delayed', (v_kot->'stats'->>'delayed')::int, 'critical', coalesce((v_kot->'stats'->>'queue_critical')::int, 0));
  exception when others then v_kot := null; end;
  -- tables strip, same states as the floor (0404)
  begin
    select jsonb_build_object('all', count(*), 'available', count(*) filter (where s.status = 'available'), 'occupied', count(*) filter (where s.status = 'occupied'),
             'reserved', count(*) filter (where s.status = 'reserved'), 'cleaning', count(*) filter (where s.status = 'cleaning'))
      into v_tables from public.tbl_states(v_org, v_loc) s;
  exception when others then v_tables := null; end;
  -- ingredients below their reorder level (null when the role may not read stock)
  begin
    v_items := public.backoffice_low_stock(jsonb_build_object('location_id', v_loc));
    v_low := v_items->'counts';
    select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'unit', e->>'unit', 'available', e->'available', 'reorder_level', e->'reorder_level', 'level', e->>'level')), '[]'::jsonb)
      into v_items from (select e from jsonb_array_elements(v_items->'items') with ordinality t(e, i) order by i limit 3) x;
  exception when others then v_low := null; v_items := null; end;

  -- orders at this outlet (an order with no outlet belongs to the main one)
  with mine as (select o.* from public.orders o where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc)
  select count(*) filter (where public.tbl_order_open(m.status, m.paid_at)), count(*) filter (where public.tbl_order_open(m.status, m.paid_at) and m.status = 'new'),
         count(*) filter (where m.created_at >= v_from and m.created_at < v_to and m.status <> 'cancelled')
    into v_live, v_new, v_total from mine m;
  with mine as (select o.id, o.total, coalesce(o.paid_at, o.updated_at) at from public.orders o
                 where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null)))
  select coalesce(sum(m.total) filter (where m.at >= v_from and m.at < v_to), 0), count(*) filter (where m.at >= v_from and m.at < v_to) into v_sales, v_paid from mine m;
  select coalesce(sum(r.amount), 0) into v_refunds from public.pos_refunds r join public.orders o on o.id = r.order_id
   where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and r.created_at >= v_from and r.created_at < v_to;

  -- One Local online orders: the record has a business but no outlet, so these are business-wide
  select jsonb_build_object('scope', 'business', 'today', count(*) filter (where c.created_at >= v_from and c.created_at < v_to and c.status <> 'cancelled'),
           'open', count(*) filter (where c.status not in ('delivered', 'cancelled')),
           'sales_today', coalesce(sum(c.total) filter (where c.created_at >= v_from and c.created_at < v_to and c.status <> 'cancelled'), 0))
    into v_ol from public.ol_orders c where c.organization_id = v_org;

  -- last 7 local days, oldest first, a day with nothing is zero
  select jsonb_agg(jsonb_build_object('date', d.dt, 'label', to_char(d.dt, 'Dy'), 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.n, 0)) order by d.dt) into v_last7
    from (select v_today - 6 + k as dt from generate_series(0, 6) k) d
    left join (select (coalesce(o.paid_at, o.updated_at) at time zone v_tz)::date as dt, sum(o.total) sales, count(*) n from public.orders o
                where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
                  and coalesce(o.paid_at, o.updated_at) >= (v_today - 6)::timestamp at time zone v_tz group by 1) x on x.dt = d.dt;

  -- the 7 local days before those, for the % change (same rule as last7)
  select jsonb_build_object('sales', coalesce(sum(o.total), 0), 'orders', count(*)) into v_prev7 from public.orders o
   where o.organization_id = v_org and coalesce(o.location_id, public.tbl_main(v_org)) = v_loc and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
     and coalesce(o.paid_at, o.updated_at) >= (v_today - 13)::timestamp at time zone v_tz and coalesce(o.paid_at, o.updated_at) < (v_today - 6)::timestamp at time zone v_tz;
  -- open = this outlet is taking One Local orders (outlet_channels, 0520); no row = not open
  select count(*) filter (where c.accepting) into v_open from public.outlet_channels c where c.location_id = v_loc;

  v_res := jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org), 'is_restaurant', v_domain = 'Restaurant',
    'location', jsonb_build_object('id', v_loc, 'name', v_lname),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'date', v_today, 'date_label', trim(to_char(v_today, 'FMDay, FMDD FMMonth YYYY')),
    'orders', jsonb_build_object('live', v_live, 'new', v_new, 'in_progress', v_live - v_new, 'today', v_total),
    'ingredients_items', v_items, 'prev7', v_prev7, 'channel', jsonb_build_object('open_outlets', v_open, 'outlets', 1),
    'kot', v_kot, 'tables', v_tables, 'ingredients_low', v_low,
    'sales', jsonb_build_object('today', v_sales - v_refunds, 'gross', v_sales, 'refunds', v_refunds, 'paid_bills', v_paid),
    'onelocal', v_ol, 'last7', v_last7,
    'not_reported', jsonb_build_array('complaints', 'reviews'));
  -- 0652: a kitchen or captain login (no money:read, no payment:record) gets no sales, payments or refunds
  if not public.rst__sees_money(v_org) then v_res := public.rst__strip_money(v_res) || jsonb_build_object('money_hidden', true); end if;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.rst_home_insights(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
  v_res jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  v_res := (
    with o as materialized (
      select o.id, o.total, o.channel,
             case when o.channel = 'dine_in' then 'dine_in' when o.channel = 'pickup' then 'takeaway' else 'delivery' end as served
        from public.orders o
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
    ), li as (
      select i.menu_item_id, i.name, i.qty, i.unit_price from public.order_items i join o on o.id = i.order_id where i.status <> 'cancelled'
    ), dishes as materialized (
      select m.id, m.name, m.is_available, m.image_url, m.description,
             public.menu_can_make(v_org, m.id) as can_make,
             exists (select 1 from public.menu_item_recipes r where r.menu_item_id = m.id and r.organization_id = v_org) as has_recipe,
             (public.mb_recipe_json(v_org, m.id)->>'food_cost_pct')::numeric as food_pct
        from public.menu_items m where m.organization_id = v_org
    )
    select jsonb_build_object(
      'mix', jsonb_build_object(
        'orders', (select count(*) from o),
        'sales', (select coalesce(sum(total), 0) from o),
        'avg_bill', (select coalesce(round(avg(total), 2), 0) from o),
        'by', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label,
                  'orders', (select count(*) from o where o.served = k.key), 'sales', (select coalesce(sum(o.total), 0) from o where o.served = k.key)) order by k.sort)
               from (values ('dine_in', 'Dine in', 1), ('takeaway', 'Takeaway', 2), ('delivery', 'Delivery', 3)) k(key, label, sort))),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', x.method, 'amount', x.amount, 'count', x.n) order by x.amount desc), '[]')
                     from (select pm.method, sum(pm.amount) as amount, count(*) as n from public.payments pm
                            where pm.organization_id = v_org and pm.created_at >= v_since and pm.amount > 0
                              and (v_loc is null or exists (select 1 from public.orders x where x.id = pm.order_id and x.location_id = v_loc))
                            group by pm.method) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'sales', t.sales) order by t.qty desc, t.sales desc), '[]')
                from (select li.name, sum(li.qty) as qty, sum(li.qty * li.unit_price) as sales from li group by li.name order by 2 desc, 3 desc limit 5) t),
      'menu', jsonb_build_object(
        'dishes', (select count(*) from dishes),
        'low', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'can_make', d.can_make) order by d.can_make, d.name), '[]')
                  from (select * from dishes where can_make is not null and can_make < 10 order by can_make, name limit 5) d),
        'out', (select count(*) from dishes where not is_available or can_make = 0),
        'food_cost_avg', (select round(avg(food_pct), 1) from dishes where food_pct is not null),
        'high_cost', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'pct', round(d.food_pct, 1)) order by d.food_pct desc), '[]')
                        from (select * from dishes where food_pct > 45 order by food_pct desc limit 5) d),
        'no_recipe', (select count(*) from dishes where not has_recipe),
        'no_photo', (select count(*) from dishes where coalesce(btrim(image_url), '') = ''),
        'no_description', (select count(*) from dishes where coalesce(btrim(description), '') = '')),
      'ready', (select count(*) from public.order_items i join o on o.id = i.order_id where i.status = 'ready'),
      -- 0645: revenue leakage: changes made today with an admin PIN (the owner's and the managers' who may see the audit)
      'leakage', case when public.has_permission(v_org, 'pos_audit_log', 'read', null) then (
        with x as (select e.*, od.display_no from public.order_events e join public.orders od on od.id = e.order_id
                    where e.organization_id = v_org and e.kind = 'admin_override' and e.created_at >= v_since
                      and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id))
        select jsonb_build_object('admin_changes', (select count(*) from x),
          -- 0650: bills left open at Day end and ended days reopened, today
          'unsettled', (select count(*) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'unsettled_due_minor', (select coalesce(sum((e.meta->>'due_minor')::bigint), 0) from public.order_events e join public.orders od on od.id = e.order_id
                         where e.organization_id = v_org and e.kind = 'day_end_unsettled' and e.created_at >= v_since
                           and (v_loc is null or od.location_id = v_loc) and public.location_is_allowed(od.organization_id, od.location_id)),
          'reopened', (select count(*) from public.rmoney_day_reopens r where r.organization_id = v_org and r.reopened_at >= v_since
                         and (v_loc is null or r.location_id = v_loc)),
          'latest', (select coalesce(jsonb_agg(jsonb_build_object('bill', y.display_no, 'what', y.message, 'at', y.created_at,
                       'by', public.money_person(v_org, nullif(y.meta->>'by', '')::uuid), 'approved_by', public.money_person(v_org, nullif(y.meta->>'approved_by', '')::uuid))
                       order by y.created_at desc), '[]'::jsonb) from (select * from x order by created_at desc limit 3) y))) end
    )
  );
  -- 0652: a kitchen or captain login (no money:read, no payment:record) gets no sales, payments or refunds
  if not public.rst__sees_money(v_org) then v_res := public.rst__strip_money(v_res) || jsonb_build_object('money_hidden', true); end if;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.rst_activity_log(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_before timestamptz := nullif(p->>'before', '')::timestamptz; v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100); v_rows jsonb;
  v_money boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  v_money := public.rst__sees_money(v_org);
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'kind', x.kind, 'message', x.message, 'actor', x.actor, 'order_id', x.order_id,
           'display_no', x.display_no, 'table_label', x.table_label, 'location_name', x.location_name) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_rows
    from (select ev.id, ev.created_at, ev.kind, ev.message, ev.actor, ev.order_id, o.display_no, t.label as table_label, l.name as location_name
            from public.order_events ev
            join public.orders o on o.id = ev.order_id and o.organization_id = v_org
            left join public.dining_tables t on t.id = o.table_id
            left join public.locations l on l.id = o.location_id
           where ev.organization_id = v_org
             and (v_loc is null or o.location_id = v_loc)
             and (o.location_id is null or public.location_is_allowed(v_org, o.location_id))
             and (v_before is null or ev.created_at < v_before)
             -- 0652: a kitchen or captain login sees the kitchen and floor events only
             and (v_money or ev.kind in ('placed', 'kot_fired', 'kot_reprinted', 'items_added', 'held', 'hold_updated', 'served', 'note', 'table_transferred',
                                        'accepted', 'timed_out', 'guest_request_accepted', 'delivery_ready', 'delivery_out', 'state_changed')
                  or ev.kind like 'kot\_%' or ev.kind like 'status\_%' or ev.kind like 'fulfilment\_%')
           order by ev.created_at desc, ev.id desc
           limit v_limit + 1) x;
  return jsonb_build_object('entries', coalesce((select jsonb_agg(e order by ord) from jsonb_array_elements(v_rows) with ordinality as a(e, ord) where ord <= v_limit), '[]'::jsonb),
                            'more', jsonb_array_length(v_rows) > v_limit, 'limited', not v_money);
end $function$;

notify pgrst, 'reload schema';
commit;
