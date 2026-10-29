-- 0618: a cancelled order buzzes the KDS (founder, 28 Oct 2026). A ticket used to vanish from the kitchen display without a word when its
-- order was cancelled. kds_queue now also lists the orders cancelled in the last hour that had already gone to the kitchen: number, where
-- it was going, its KOTs and dishes, and when; the KDS sounds an alarm once for each and shows "Stop cooking" until it is dismissed.
--   * kds_cancelled(org, outlet)
--   * kds_queue: 'cancelled'
-- Read only. Safe to run again.

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_queue(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_station text := nullif(btrim(coalesce(p->>'station', '')), ''); v_loc uuid := nullif(p->>'location_id', '')::uuid;
  v_status text := coalesce(nullif(p->>'status', ''), 'all'); v_q text := nullif(lower(btrim(coalesce(p->>'q', ''))), '');
  v_day timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_stats jsonb; v_counts jsonb; v_cards jsonb; v_chips jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_NOT_FOUND: sign in to a business first'; end if;
  if not public.kitchen_can(v_org, 'view') then raise exception 'POS_FORBIDDEN: your role cannot see the kitchen display'; end if;
  if v_status not in ('all', 'new', 'in_progress', 'ready', 'served') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  if v_station is not null and v_station <> 'unassigned' and not exists (select 1 from public.pos_kitchen_stations where organization_id = v_org and key = v_station) then
    raise exception 'POS_NOT_FOUND: station not found'; end if;
  -- one statement, no scratch tables
  with cards as (select * from public.kds_cards(v_org) c where v_loc is null or c.location_id = v_loc),
  vis_all as (select * from cards c where public.kds_visible(c.chip, c.order_status, c.created_at, c.served_at)),
  vis as (select * from vis_all c where v_station is null or c.queue_key = v_station),
  done as (select count(*) n from cards c where c.chip = 'served' and c.served_at >= v_day and (v_station is null or c.queue_key = v_station)),
  shown as (
    select b.ticket_id, b.queue_key, b.chip, b.priority, b.created_at from vis b
     where (v_status = 'all' or b.chip = v_status)
       and (v_q is null or lower(b.display_no) like '%' || v_q || '%' or exists (select 1 from public.order_items i where i.kot_ticket_id = b.ticket_id and i.status <> 'cancelled'
              and public.kitchen_queue_key(v_org, i.station) = b.queue_key and position(v_q in lower(i.name)) > 0))
     order by (b.chip = 'served'), (b.priority = 'urgent') desc, b.created_at limit 100)
  select jsonb_build_object(
           'queue_critical', count(*) filter (where chip in ('new', 'in_progress') and priority = 'urgent'),
           'pending', count(*) filter (where chip in ('new', 'in_progress')),
           'dine_in', count(*) filter (where chip in ('new', 'in_progress') and channel = 'dine_in'),
           'online_delivery', count(*) filter (where chip in ('new', 'in_progress') and channel in ('delivery', 'online', 'swiggy', 'zomato')),
           'delayed', count(*) filter (where chip in ('new', 'in_progress') and created_at < now() - interval '15 minutes'),
           'completed_today', (select n from done)),
         jsonb_build_object('all', count(*), 'new', count(*) filter (where chip = 'new'), 'in_progress', count(*) filter (where chip = 'in_progress'),
           'ready', count(*) filter (where chip = 'ready'), 'served', count(*) filter (where chip = 'served')),
         coalesce((select jsonb_agg(public.kds_card_json(sh.ticket_id, sh.queue_key) order by (sh.chip = 'served'), (sh.priority = 'urgent') desc, sh.created_at) from shown sh), '[]'),
         -- chips: active stations, a station that was switched off but still has cards, and Unassigned when some card has no station
         coalesce((select jsonb_agg(jsonb_build_object('key', x.key, 'name', x.name) order by x.ord, x.name) from (
              select s.key, s.name, s.sort_order ord from public.pos_kitchen_stations s
               where s.organization_id = v_org and (s.active or s.key in (select queue_key from vis_all))
              union all select 'unassigned', 'Unassigned', 1000000 where exists (select 1 from vis_all where queue_key = 'unassigned')) x), '[]')
    into v_stats, v_counts, v_cards, v_chips from vis;
  return jsonb_build_object('live', (v_counts->>'all')::int, 'station', v_station, 'stats', v_stats, 'counts', v_counts, 'tickets', v_cards, 'stations', v_chips,
    'delayed_after_minutes', 15, 'can', jsonb_build_object('act', public.has_permission(v_org, 'order', 'update_status')),
    -- 0618: orders cancelled in the last hour after they reached the kitchen, so the KDS buzzes and says stop cooking
    'cancelled', public.kds_cancelled(v_org, v_loc));
end $$

;
