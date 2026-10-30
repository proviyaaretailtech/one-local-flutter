-- 0617: a table transfer shows on the kitchen tickets (founder, 28 Oct 2026). The KDS and KOT views already read the table from the order,
-- so a moved order shows its new table; now each ticket also says it moved ("T2 → T5", when), so the kitchen and the pass notice.
--   * order_table_move(order): the order's last transfer {from, to, at}, or null
--   * kds_card_json and rst_kot_orders: 'moved'
-- Read only. Safe to run again.

create or replace function public.order_table_move(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('from', coalesce(f.label, '?'), 'to', coalesce(t.label, '?'), 'at', e.created_at)
    from public.order_events e
    left join public.dining_tables f on f.id = nullif(e.meta->>'from', '')::uuid
    left join public.dining_tables t on t.id = nullif(e.meta->>'to', '')::uuid
   where e.order_id = p_order and e.kind = 'table_transferred'
   order by e.created_at desc, e.id desc limit 1
$$;
revoke all on function public.order_table_move(uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'moved', public.order_table_move(o.id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$$

;

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
  if v_st not in ('all', 'preparing', 'ready', 'completed') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and i.status <> 'cancelled'),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 else 3 end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$

;
