-- 0610: accept delivery orders within a minute, and auto-accept (founder, 28 Oct 2026). Safe to run again.
--   * ol_merchant_channels.auto_accept (default off): when on, the Orders screen accepts each new order as it arrives.
--     The accept window is the existing accept_window_seconds (60 by default).
--   * rst_channel_accept({order_id}): accepts one new delivery order. A held POS order is sent to the kitchen (tbl_kot_fire, its KOT);
--     a OneLocal app order is also marked accepted (the customer's order moves on through the status gate). Safe to repeat.
--   * rst_auto_accept_set({on}): turns auto-accept on or off (a manager or owner).
--   * rst_channel_orders (0607) also answers accept_window and auto_accept.

begin;

alter table public.ol_merchant_channels add column if not exists auto_accept boolean not null default false;

create or replace function public.rst_channel_accept(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; v_kot jsonb; v_done boolean := false;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot accept orders'; end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  -- the kitchen gets it (a held order has no KOT yet)
  if o.status in ('new', 'in_billing') then
    v_kot := public.tbl_kot_fire(o.id);
    v_done := true;
  end if;
  -- a OneLocal app order: the customer's order is accepted too
  if x.id is not null and x.status = 'placed' then
    perform public.status_gate('ol_orders', x.id, 'restaurant_accept');
    update public.ol_orders set status = 'accepted', prep_minutes = coalesce(x.prep_minutes, 20), eta_minutes = coalesce(x.prep_minutes, 20) + 15 where id = x.id;
    v_done := true;
  end if;
  if v_done then
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'accepted', o.display_no || ' accepted' || case when coalesce((p->>'auto')::boolean, false) then ' automatically' else '' end, 'pos',
            jsonb_build_object('by', auth.uid(), 'auto', coalesce((p->>'auto')::boolean, false)));
  end if;
  return jsonb_build_object('order_id', o.id, 'accepted', true, 'already', not v_done, 'kot', v_kot);
end $$;

create or replace function public.rst_auto_accept_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_on boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager']) then
    raise exception 'POS_FORBIDDEN: only a manager can change auto-accept'; end if;
  begin v_on := (p->>'on')::boolean; exception when others then v_on := null; end;
  if v_on is null then raise exception 'POS_BAD_REQUEST: on is true or false'; end if;
  insert into public.ol_merchant_channels (organization_id, auto_accept, updated_by, updated_at) values (v_org, v_on, auth.uid(), now())
  on conflict (organization_id) do update set auto_accept = excluded.auto_accept, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('auto_accept', v_on);
end $$;

revoke all on function public.rst_channel_accept(jsonb) from public, anon;
grant execute on function public.rst_channel_accept(jsonb) to authenticated, service_role;
revoke all on function public.rst_auto_accept_set(jsonb) from public, anon;
grant execute on function public.rst_auto_accept_set(jsonb) to authenticated, service_role;

create or replace function public.rst_channel_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name, ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$;

commit;
