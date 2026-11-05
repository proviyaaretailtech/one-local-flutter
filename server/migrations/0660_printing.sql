-- 0660 Printing that really prints (founder's finding, 2026-11-04): kitchen tickets never printed while the app said "sent to the
-- printer"; Print KOT and receipt Print did nothing; the printers saved in Devices were never used. Local dev DB 2026-11-04.
-- The phone / tablet on the restaurant's Wi-Fi prints: an online server cannot reach a printer on the shop's network. The database
-- only answers WHAT to print and WHERE (one source of truth: pos_printers + pos_kitchen_stations.printer_id from Devices / Kitchen
-- setup), and records what happened.
--   pos_print_targets   any staff member: the business's active printers (no secrets in them) and which station prints where
--   pos_kot_print       any staff member of the outlet: one kitchen ticket's dishes, grouped by the printer each station uses
--   pos_print_log       what was printed, where, and whether it worked (order_events; printer's last good print)
--   tbl_order_view      Print KOT is offered once the table has a ticket
begin;

create or replace function public.pos__staff_org() returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return v_org;
end $$;

create or replace function public.pos__printer_json(r public.pos_printers) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.id, 'name', r.name, 'type', r.printer_type, 'connection', r.connection, 'address', r.address,
    'paper_mm', coalesce(r.paper_mm, 80), 'copies', greatest(coalesce(r.copies, 1), 1), 'auto_cut', coalesce(r.auto_cut, true),
    'is_default', coalesce(r.is_default, false), 'model', r.model, 'label_size', r.label_size, 'location_id', r.location_id, 'last_test_at', r.last_test_at);
$$;

create or replace function public.pos_print_targets(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.pos__staff_org(); v_loc uuid := nullif(p->>'location_id', '')::uuid; o public.organizations%rowtype; l public.locations%rowtype;
begin
  if v_loc is not null and not public.location_is_allowed(v_org, v_loc) then raise exception 'POS_FORBIDDEN: this outlet is not one you work in'; end if;
  select * into o from public.organizations where id = v_org;
  select * into l from public.locations where id = coalesce(v_loc, (select id from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1));
  return jsonb_build_object(
    'printers', (select coalesce(jsonb_agg(public.pos__printer_json(r) order by r.printer_type, r.is_default desc nulls last, r.name), '[]'::jsonb)
                   from public.pos_printers r where r.organization_id = v_org and r.deleted_at is null and coalesce(r.active, true)
                    and (r.location_id is null or v_loc is null or r.location_id = v_loc)),
    'stations', (select coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'name', s.name, 'printer_id', coalesce(s.printer_id, g.printer_id)) order by s.sort_order, s.name), '[]'::jsonb)
                   from public.pos_kitchen_stations s left join public.pos_kitchen_stations g on g.id = s.kds_group_id
                  where s.organization_id = v_org and coalesce(s.active, true)),
    'business', jsonb_build_object('name', coalesce((select public_name from public.org_listing_profiles where organization_id = v_org), o.name),
                                   'outlet', l.name, 'gstin', coalesce(l.gstin, o.gstin),
                                   'address', coalesce(l.address->>'line', (select address_line from public.org_listing_profiles where organization_id = v_org)),
                                   'phone', coalesce((select phone from public.org_listing_profiles where organization_id = v_org), o.contact_phone)));
end $$;

-- the printer a station's dishes go to: the station's own, its kitchen group's, else the default kitchen (KOT) printer
create or replace function public.pos__kot_printer(p_org uuid, p_station text) returns uuid language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select coalesce(s.printer_id, g.printer_id) from public.pos_kitchen_stations s left join public.pos_kitchen_stations g on g.id = s.kds_group_id
      where s.organization_id = p_org and s.key = p_station and coalesce(s.active, true)),
    (select r.id from public.pos_printers r where r.organization_id = p_org and r.printer_type = 'kot' and r.deleted_at is null and coalesce(r.active, true)
      order by r.is_default desc nulls last, r.created_at limit 1));
$$;

create or replace function public.pos_kot_print(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.pos__staff_org(); o public.orders%rowtype; k public.kot_tickets%rowtype;
begin
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org;
  if not found or not public.location_is_allowed(v_org, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if nullif(p->>'ticket_id', '') is not null then
    select * into k from public.kot_tickets where id = (p->>'ticket_id')::uuid and order_id = o.id;
  else
    select * into k from public.kot_tickets where order_id = o.id order by kot_no desc, created_at desc limit 1;
  end if;
  if not found then raise exception 'POS_WRONG_STATE: send the order to the kitchen first'; end if;
  return jsonb_build_object('ticket_id', k.id, 'kot_no', k.kot_no, 'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel,
    'table_label', (select label from public.dining_tables where id = o.table_id), 'sent_at', k.created_at, 'note', o.notes,
    'reprint', exists (select 1 from public.order_events e where e.order_id = o.id and e.kind = 'kot_printed' and e.meta->>'ticket_id' = k.id::text),
    'groups', (select coalesce(jsonb_agg(jsonb_build_object('printer_id', x.printer_id, 'station', x.station_name, 'items', x.items) order by x.station_name), '[]'::jsonb) from (
       select public.pos__kot_printer(v_org, i.station) printer_id, public.tbl_station_label(v_org, i.station) station_name,
              jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty - coalesce(i.cancelled_qty, 0), 'variant', i.variant_name, 'add_ons', i.add_ons,
                                           'notes', i.notes, 'takeaway', coalesce(i.is_takeaway, false), 'cancelled', i.status = 'cancelled')
                        order by i.created_at, i.name) items
         from public.order_items i where i.kot_ticket_id = k.id
        group by 1, 2) x));
end $$;

create or replace function public.pos_print_log(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.pos__staff_org(); v_kind text := p->>'kind'; v_out text := p->>'outcome'; o public.orders%rowtype; v_pr uuid := nullif(p->>'printer_id', '')::uuid;
  v_detail text := left(nullif(btrim(coalesce(p->>'detail', '')), ''), 200);
begin
  if v_kind not in ('kot', 'bill', 'receipt', 'test') then raise exception 'POS_BAD_REQUEST: unknown print kind'; end if;
  if v_out not in ('printed', 'failed', 'no_printer', 'dialog') then raise exception 'POS_BAD_REQUEST: unknown print outcome'; end if;
  if v_pr is not null and not exists (select 1 from public.pos_printers where id = v_pr and organization_id = v_org) then raise exception 'POS_NOT_FOUND: printer not found'; end if;
  if v_out = 'printed' and v_pr is not null then
    update public.pos_printers set last_test_at = now(), updated_at = now() where id = v_pr and v_kind = 'test';
  end if;
  if nullif(p->>'order_id', '') is not null then
    select * into o from public.orders where id = (p->>'order_id')::uuid and organization_id = v_org;
    if not found or not public.location_is_allowed(v_org, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, case v_out when 'printed' then v_kind || '_printed' else 'print_failed' end,
            initcap(v_kind) || case v_out when 'printed' then ' printed' when 'dialog' then ' sent to the phone''s print dialog' when 'no_printer' then ' not printed: no printer set up' else ' not printed' end
              || coalesce(' on ' || (select name from public.pos_printers where id = v_pr), '') || coalesce(' (' || v_detail || ')', ''),
            'pos', jsonb_build_object('by', auth.uid(), 'printer_id', v_pr, 'ticket_id', nullif(p->>'ticket_id', ''), 'outcome', v_out, 'detail', v_detail));
  end if;
  return jsonb_build_object('logged', true);
end $$;

-- Print KOT is offered once the table's order has a kitchen ticket
do $$
declare v_src text := replace(pg_get_functiondef('public.tbl_order_view'::regproc), E'\r', '');
begin
  if v_src like '%''print_kot'', false%' then
    v_src := replace(v_src, $r$'print_kot', false,$r$,
      $r$'print_kot', exists (select 1 from public.kot_tickets k join public.orders o on o.id = k.order_id where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),$r$);
    v_src := replace(v_src, $r$'unavailable', jsonb_build_object('print_kot', 'Printing a KOT is not in this release.')$r$,
      $r$'unavailable', jsonb_build_object('print_kot', 'Send the order to the kitchen first.')$r$);
    execute v_src;
  end if;
end $$;


-- a LAN printer may be named by its IP address or by a host name on the shop's network, with an optional port (e.g. kitchen.local:9100)
do $$
declare v_src text := replace(pg_get_functiondef('public.rst_printer_save'::regproc), E'\r', '');
  v_old text := $r$  if v_conn = 'lan' and v_addr !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{2,5})?$' then raise exception 'POS_BAD_REQUEST: the IP address looks wrong; it is like 192.168.1.50'; end if;$r$;
begin
  if v_src like '%host name or IPv4 address%' then return; end if;
  if position(v_old in v_src) = 0 then raise exception '0660: rst_printer_save has changed shape; patch it by hand'; end if;
  v_src := replace(v_src, v_old, $r$  -- 0660: host name or IPv4 address, optional port
  if v_conn = 'lan' and not (v_addr ~ '^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(:[0-9]{2,5})?$'
                             or v_addr ~* '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:[0-9]{2,5})?$') then
    raise exception 'POS_BAD_REQUEST: the printer address looks wrong; it is like 192.168.1.50 or kitchen-printer.local'; end if;$r$);
  execute v_src;
end $$;

-- the order's activity and the audit report show prints and failed prints
do $$
declare v_src text := replace(pg_get_functiondef('public.rst_activity_log'::regproc), E'\r', '');
begin
  if v_src like '%''kot_printed''%' then return; end if;
  if position($r$'kot_fired', 'kot_reprinted',$r$ in v_src) = 0 then raise exception '0660: rst_activity_log has changed shape; patch it by hand'; end if;
  execute replace(v_src, $r$'kot_fired', 'kot_reprinted',$r$, $r$'kot_fired', 'kot_reprinted', 'kot_printed', 'bill_printed', 'receipt_printed', 'print_failed',$r$);
end $$;

revoke all on function public.pos__staff_org(), public.pos__printer_json(public.pos_printers), public.pos__kot_printer(uuid, text) from public, anon, authenticated;
revoke all on function public.pos_print_targets(jsonb), public.pos_kot_print(jsonb), public.pos_print_log(jsonb) from public, anon;
grant execute on function public.pos_print_targets(jsonb), public.pos_kot_print(jsonb), public.pos_print_log(jsonb) to authenticated, service_role;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0660_printing.sql', 'Printing: print targets for any staff, KOT print data routed by station printer, print log, Print KOT offered (local dev DB 2026-11-04)')
on conflict do nothing;
commit;
