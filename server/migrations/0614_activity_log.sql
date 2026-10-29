-- 0614: the Activity log in Settings (founder, 28 Oct 2026): the operational timeline that used to sit on the table order page, for every order of
-- the business in one place, newest first. Read only. Safe to run again.
--   p: location_id (optional; null or 'all' = every outlet the user may see), before (optional cursor: the 'at' of the last entry shown),
--      limit (1-100, default 50).
--   answer: entries [{id, at, kind, message, actor, order_id, display_no, table_label, location_name}], more (true when older entries exist).

create or replace function public.rst_activity_log(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_before timestamptz := nullif(p->>'before', '')::timestamptz; v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100); v_rows jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
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
           order by ev.created_at desc, ev.id desc
           limit v_limit + 1) x;
  return jsonb_build_object('entries', coalesce((select jsonb_agg(e order by ord) from jsonb_array_elements(v_rows) with ordinality as a(e, ord) where ord <= v_limit), '[]'::jsonb),
                            'more', jsonb_array_length(v_rows) > v_limit);
end $$;

revoke all on function public.rst_activity_log(jsonb) from public, anon;
grant execute on function public.rst_activity_log(jsonb) to authenticated, service_role;
