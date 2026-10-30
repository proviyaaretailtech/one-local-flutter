-- 0621: an order cancelled while the kitchen has it shows on the KDS and on the KOT view (founder, 29 Oct 2026). The KOT view used to drop
-- a cancelled order without a word, and the KDS alert (0618) did not say who cancelled or why.
--   * order_cancel_info(order): who cancelled (Customer / Restaurant / Swiggy / Zomato / OneLocal) and the reason
--   * kds_cancelled: + 'by', 'reason'
--   * rst_kot_orders: today's cancelled kitchen orders stay, stage 'cancelled' with 'cancel' {by, reason, at}; a 'cancelled' count and
--     filter; one cancelled in the last hour comes first
-- Read only. Safe to run again.

create or replace function public.order_cancel_info(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with o as (select o.id, o.channel from public.orders o where o.id = p_order),
  ol as (select ol.id, ol.user_id, ol.cancelled_by, ol.cancel_reason from public.ol_orders ol join o on ol.pos_order_id = o.id limit 1),
  oc as (select c.initiated_by, c.reason from public.order_cancellations c join ol on c.ol_order_id = ol.id limit 1),
  ev as (select e.meta->>'reason' as reason from public.order_events e join o on e.order_id = o.id
          where e.kind = 'status_cancelled' order by e.created_at desc limit 1)
  select jsonb_build_object(
    'by', case
            when exists (select 1 from ev) then 'Restaurant'
            when (select initiated_by from oc) = 'customer' or ((select cancelled_by from ol) is not null and (select cancelled_by from ol) = (select user_id from ol)) then 'Customer'
            when (select initiated_by from oc) = 'restaurant' then 'Restaurant'
            when exists (select 1 from ol) then 'OneLocal'
            when (select channel from o) = 'swiggy' then 'Swiggy'
            when (select channel from o) = 'zomato' then 'Zomato'
            else 'Restaurant' end,
    'reason', coalesce(nullif(btrim((select reason from ev)), ''), nullif(btrim((select reason from oc)), ''), nullif(btrim((select cancel_reason from ol)), '')))
$$;
revoke all on function public.order_cancel_info(uuid) from public, anon;

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         || public.order_cancel_info(o.id)
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.rst_kot_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_st text := coalesce(nullif(p->>'status', ''), 'all'); v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_st not in ('all', 'preparing', 'ready', 'completed', 'cancelled') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.updated_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             -- a cancelled order counts the dishes the kitchen had (all of them are cancelled now)
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status <> 'cancelled' or (o.status = 'cancelled' and i.kot_ticket_id is not null))) as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.status = 'cancelled' then 'cancelled'
                  when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage,
             o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes' as fresh_cancel
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed'),
                                   'cancelled', (select count(*) from s where stage = 'cancelled')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'cancel', case when s.stage = 'cancelled' then public.order_cancel_info(s.id) || jsonb_build_object('at', s.updated_at, 'recent', s.fresh_cancel) end,
          'dishes', case when s.stage = 'cancelled' then (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty) order by i.created_at), '[]')
                                                          from public.order_items i where i.order_id = s.id and i.kot_ticket_id is not null) end,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status <> 'cancelled' or s.stage = 'cancelled')),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case when s.fresh_cancel then -1 else case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 when 'completed' then 3 else 4 end end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$;
