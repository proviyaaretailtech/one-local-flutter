-- 0603 "Mark as clean" (founder, 27 Oct 2026): a table shows Cleaning for 10 minutes after its bill is paid or its session closes
-- (tbl_states); floor staff can now end that early. Safe to run again.
--   * dining_tables.cleaned_at: when someone marked the table clean;
--   * tbl_states: a table marked clean after its last bill is not Cleaning (everything else exactly as before);
--   * tbl_mark_clean: only a Cleaning table; joined (merged) tables are one place, so every member is marked; floor staff only
--     (tbl_guard 'read': order place, order update status or table manager).

begin;

alter table public.dining_tables add column if not exists cleaned_at timestamptz;

create or replace function public.tbl_states(p_org uuid, p_loc uuid, p_table uuid default null::uuid)
 returns table(table_id uuid, status text, since timestamp with time zone, reserved_at timestamp with time zone, reservation_id uuid, open_orders integer)
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with t as (select id, cleaned_at from public.dining_tables
              where organization_id = p_org and is_active and coalesce(location_id, public.tbl_main(p_org)) = p_loc),
  oo as (select o.table_id, count(*)::int n, min(o.created_at) first_at from public.orders o
          where o.organization_id = p_org and o.table_id is not null and public.tbl_order_open(o.status, o.paid_at) group by o.table_id),
  ss as (select s.table_id, min(s.opened_at) first_at from public.table_sessions s where s.organization_id = p_org and s.status in ('open', 'billed') group by s.table_id),
  cl as (select x.table_id, max(x.at) at from (
           select o.table_id, coalesce(o.paid_at, o.updated_at) at from public.orders o
            where o.organization_id = p_org and o.table_id is not null and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
           union all select s.table_id, s.closed_at from public.table_sessions s where s.organization_id = p_org and s.status = 'closed' and s.closed_at is not null) x group by x.table_id),
  rv as (select distinct on (r.table_id) r.table_id, r.scheduled_at, r.row_id from public.pos_reservations r
          where r.organization_id = p_org and r.deleted_at is null and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending')
            and r.scheduled_at between now() - interval '30 minutes' and now() + interval '120 minutes'
          order by r.table_id, r.scheduled_at),
  base as (
    select t.id,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then 'occupied'
                -- 0603: marked clean after the last bill = not Cleaning any more
                when cl.at is not null and cl.at > now() - interval '10 minutes' and (t.cleaned_at is null or t.cleaned_at < cl.at) then 'cleaning'
                when rv.row_id is not null then 'reserved' else 'available' end st,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then least(coalesce(oo.first_at, ss.first_at), coalesce(ss.first_at, oo.first_at)) end sn,
           rv.scheduled_at rat, rv.row_id rid, coalesce(oo.n, 0) n
      from t left join oo on oo.table_id = t.id left join ss on ss.table_id = t.id left join cl on cl.table_id = t.id left join rv on rv.table_id = t.id::text),
  gm as (select m.table_id, m.merge_id from public.table_merge_members m where m.organization_id = p_org and m.released_at is null),
  -- joined tables are one place: occupied if ANY member is, the earliest booking of any member shows, the open orders add up
  agg as (select gm.merge_id, bool_or(b.st = 'occupied') occ, bool_or(b.st = 'cleaning') cln, sum(b.n)::int n, min(b.sn) sn, min(b.rat) rat,
                 (array_agg(b.rid order by b.rat) filter (where b.rid is not null))[1] rid
            from gm join base b on b.id = gm.table_id group by gm.merge_id)
  select b.id,
         case when g.merge_id is null then b.st when a.occ then 'occupied' when a.cln then 'cleaning' when a.rat is not null then 'reserved' else 'available' end,
         case when g.merge_id is null then b.sn when a.occ then a.sn end,
         case when g.merge_id is null then b.rat when not a.occ and not a.cln then a.rat end,
         case when g.merge_id is null then b.rid when not a.occ and not a.cln then a.rid end,
         case when g.merge_id is null then b.n else a.n end
    from base b left join gm g on g.table_id = b.id left join agg a on a.merge_id = g.merge_id
   where p_table is null or b.id = p_table;
$function$;

create or replace function public.tbl_mark_clean(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'table_id', '')::uuid;
  v_label text; v_state text; v_merge uuid; v_n int;
begin
  select label into v_label from public.dining_tables where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc;
  if v_label is null then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  if coalesce(v_state, '') <> 'cleaning' then
    raise exception 'TBL_WRONG_STATE: % is %, not cleaning', v_label, coalesce(v_state, 'available'); end if;
  select merge_id into v_merge from public.table_merge_members where table_id = v_id and organization_id = v_org and released_at is null limit 1;
  update public.dining_tables d set cleaned_at = now(), updated_at = now()
   where d.organization_id = v_org
     and (d.id = v_id or (v_merge is not null and d.id in (select m.table_id from public.table_merge_members m where m.merge_id = v_merge and m.released_at is null)));
  get diagnostics v_n = row_count;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  return jsonb_build_object('table_id', v_id, 'label', v_label, 'status', v_state, 'tables_marked', v_n);
end $$;

revoke all on function public.tbl_mark_clean(jsonb) from public, anon;
grant execute on function public.tbl_mark_clean(jsonb) to authenticated, service_role;

commit;
