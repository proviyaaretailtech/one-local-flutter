-- ==========================================================================================================================
-- HOSTED: 0638 Devices for the restaurant (1 Nov 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Settings → Devices: receipt, kitchen (KOT) and barcode label printers; default per job; test print; the receipt names the default.
-- ==========================================================================================================================
begin;
-- Stops here, changing nothing, if what this relies on is missing.
do $$
begin
  if to_regclass('public.pos_printers') is null or to_regclass('public.pos_kitchen_stations') is null then
    raise exception 'STOPPED, nothing changed: the printer tables are missing on hosted'; end if;
  if to_regprocedure('public.rst_receipt_view(jsonb)') is null or to_regprocedure('public.has_org_role(text[])') is null then
    raise exception 'STOPPED, nothing changed: a function this relies on is missing on hosted'; end if;
end $$;
-- 0638: Devices for the restaurant (founder, 1 Nov 2026: "make a device manager like the store POS", Settings → Devices).
-- The printers of a business, kept in pos_printers (which the kitchen set-up and the receipt already read): receipt printers, kitchen
-- (KOT) printers and barcode label printers. Each has a name, how it connects (Wi-Fi / LAN with its address, Bluetooth with its name,
-- USB, or the phone's print service), an optional model, the paper width (receipts, KOT) or the label size, copies, auto cut, and
-- whether it is the default for its job. A printer is marked tested when a test page printed. Nothing existing changes meaning:
--   * new columns: model, label_size, is_default; the phone's print service ('system') joins the connections;
--   * rst_devices_list, rst_printer_save, rst_printer_delete (kept, marked deleted), rst_printer_tested;
--   * the receipt names the default receipt printer first.
-- Who: owners, admins and managers (the same people who change Settings). A kitchen printer made here can then be chosen for a kitchen
-- station in the kitchen set-up, as before.

alter table public.pos_printers add column if not exists model text check (model is null or char_length(model) <= 40);
alter table public.pos_printers add column if not exists label_size text check (label_size is null or label_size in ('38x25', '50x25', '50x30', '75x50', '100x50'));
alter table public.pos_printers add column if not exists is_default boolean not null default false;
do $$
declare c text;
begin
  -- the phone's own print service is a way to connect too
  select conname into c from pg_constraint where conrelid = 'public.pos_printers'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%connection%';
  if c is not null and pg_get_constraintdef((select oid from pg_constraint where conname = c and conrelid = 'public.pos_printers'::regclass)) not like '%system%' then
    execute format('alter table public.pos_printers drop constraint %I', c);
    alter table public.pos_printers add constraint pos_printers_connection_check check (connection in ('lan', 'usb', 'bluetooth', 'system'));
  end if;
end $$;

-- who may manage devices: the people who change Settings
create or replace function public.rst_devices_can() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and public.current_org_id() is not null
     and public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager', 'operations_manager']);
$$;
revoke all on function public.rst_devices_can() from public, anon, authenticated;

create or replace function public.rst_printer_json(x public.pos_printers) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', x.id, 'name', x.name, 'type', x.printer_type, 'connection', x.connection, 'address', nullif(x.address, ''), 'model', x.model,
    'paper_mm', x.paper_mm, 'label_size', x.label_size, 'copies', x.copies, 'auto_cut', x.auto_cut, 'is_default', x.is_default, 'active', x.active,
    'location_id', x.location_id, 'tested_at', x.last_test_at,
    'stations', (select coalesce(jsonb_agg(s.name order by s.sort_order, s.name), '[]'::jsonb) from public.pos_kitchen_stations s where s.printer_id = x.id));
$$;
revoke all on function public.rst_printer_json(public.pos_printers) from public, anon, authenticated;

create or replace function public.rst_devices_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_rows jsonb;
begin
  if not public.rst_devices_can() then raise exception 'POS_FORBIDDEN: your role cannot change devices'; end if;
  select coalesce(jsonb_agg(public.rst_printer_json(x) order by x.printer_type, x.is_default desc, x.created_at), '[]'::jsonb) into v_rows
    from public.pos_printers x
   where x.organization_id = v_org and x.deleted_at is null and (x.location_id is null or public.location_is_allowed(v_org, x.location_id));
  return jsonb_build_object('printers', v_rows,
    'count', jsonb_array_length(v_rows), 'tested', (select count(*) from jsonb_array_elements(v_rows) e where e->>'tested_at' is not null));
end $$;

create or replace function public.rst_printer_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_id uuid; v_loc uuid; x public.pos_printers;
  v_name text := btrim(coalesce(p->>'name', '')); v_type text := p->>'type'; v_conn text := coalesce(p->>'connection', 'bluetooth');
  v_addr text := nullif(btrim(coalesce(p->>'address', '')), ''); v_model text := nullif(btrim(coalesce(p->>'model', '')), '');
  v_paper int; v_label text := nullif(p->>'label_size', ''); v_copies int; v_cut boolean := coalesce((p->>'auto_cut')::boolean, true);
  v_default boolean := coalesce((p->>'is_default')::boolean, false);
begin
  if not public.rst_devices_can() then raise exception 'POS_FORBIDDEN: your role cannot change devices'; end if;
  begin
    v_id := nullif(p->>'id', '')::uuid;
    v_loc := nullif(p->>'location_id', '')::uuid;
    v_paper := coalesce(nullif(p->>'paper_mm', '')::int, 80);
    v_copies := coalesce(nullif(p->>'copies', '')::int, 1);
  exception when others then raise exception 'POS_BAD_REQUEST: check the printer details';
  end;
  if char_length(v_name) < 1 or char_length(v_name) > 40 then raise exception 'POS_BAD_REQUEST: give the printer a name (up to 40 letters)'; end if;
  if v_type not in ('receipt', 'kot', 'label') then raise exception 'POS_BAD_REQUEST: choose what it prints'; end if;
  if v_conn not in ('lan', 'usb', 'bluetooth', 'system') then raise exception 'POS_BAD_REQUEST: choose how it connects'; end if;
  if v_conn = 'lan' and v_addr is null then raise exception 'POS_BAD_REQUEST: enter the printer''s IP address, like 192.168.1.50'; end if;
  if v_conn = 'lan' and v_addr !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{2,5})?$' then raise exception 'POS_BAD_REQUEST: the IP address looks wrong; it is like 192.168.1.50'; end if;
  if v_addr is not null and char_length(v_addr) > 60 then raise exception 'POS_BAD_REQUEST: the address or Bluetooth name is too long'; end if;
  if v_model is not null and char_length(v_model) > 40 then raise exception 'POS_BAD_REQUEST: the model can be up to 40 letters'; end if;
  if v_paper not in (58, 80) then raise exception 'POS_BAD_REQUEST: choose 58 mm or 80 mm paper'; end if;
  if v_copies not between 1 and 5 then raise exception 'POS_BAD_REQUEST: print 1 to 5 copies'; end if;
  if v_type = 'label' then
    v_label := coalesce(v_label, '50x25');
    if v_label not in ('38x25', '50x25', '50x30', '75x50', '100x50') then raise exception 'POS_BAD_REQUEST: choose a label size'; end if;
  else
    v_label := null;
  end if;
  -- the outlet: the one chosen, else the first the person may see
  if v_loc is null then
    select l.id into v_loc from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)
     order by (l.code = 'MAIN') desc, l.created_at limit 1;
  elsif not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org and public.location_is_allowed(v_org, l.id)) then
    raise exception 'POS_NOT_FOUND: outlet not found';
  end if;

  if v_id is null then
    insert into public.pos_printers (organization_id, location_id, name, printer_type, connection, address, model, paper_mm, label_size, copies, auto_cut, active)
    values (v_org, v_loc, v_name, v_type, v_conn, coalesce(v_addr, ''), v_model, v_paper, v_label, v_copies, v_cut, true) returning * into x;
  else
    update public.pos_printers set name = v_name, printer_type = v_type, connection = v_conn, address = coalesce(v_addr, ''), model = v_model, paper_mm = v_paper,
           label_size = v_label, copies = v_copies, auto_cut = v_cut, updated_at = now(),
           -- a printer that changes job is no longer the default of its old job
           is_default = case when printer_type = v_type then is_default else false end
     where id = v_id and organization_id = v_org and deleted_at is null returning * into x;
    if x.id is null then raise exception 'POS_NOT_FOUND: printer not found'; end if;
  end if;
  -- the default for its job at its outlet: asked for, or the first printer for that job
  if v_default or not exists (select 1 from public.pos_printers y where y.organization_id = v_org and y.printer_type = x.printer_type and y.deleted_at is null
                                and y.is_default and y.id <> x.id and y.location_id is not distinct from x.location_id) then
    update public.pos_printers set is_default = (id = x.id)
     where organization_id = v_org and printer_type = x.printer_type and deleted_at is null and location_id is not distinct from x.location_id;
  end if;
  select * into x from public.pos_printers where id = x.id;
  return public.rst_printer_json(x);
end $$;

create or replace function public.rst_printer_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); x public.pos_printers;
begin
  if not public.rst_devices_can() then raise exception 'POS_FORBIDDEN: your role cannot change devices'; end if;
  update public.pos_printers set deleted_at = now(), active = false, is_default = false, updated_at = now()
   where id = nullif(p->>'id', '')::uuid and organization_id = v_org and deleted_at is null returning * into x;
  if x.id is null then raise exception 'POS_NOT_FOUND: printer not found'; end if;
  -- kitchen stations stop printing to it; the next printer for its job becomes the default
  update public.pos_kitchen_stations set printer_id = null where printer_id = x.id;
  update public.pos_printers set is_default = true
   where id = (select y.id from public.pos_printers y where y.organization_id = v_org and y.printer_type = x.printer_type and y.deleted_at is null
                and y.location_id is not distinct from x.location_id order by y.created_at limit 1)
     and not exists (select 1 from public.pos_printers z where z.organization_id = v_org and z.printer_type = x.printer_type and z.deleted_at is null
                      and z.is_default and z.location_id is not distinct from x.location_id);
  return jsonb_build_object('id', x.id, 'deleted', true);
end $$;

create or replace function public.rst_printer_tested(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); x public.pos_printers;
begin
  if not public.rst_devices_can() then raise exception 'POS_FORBIDDEN: your role cannot change devices'; end if;
  update public.pos_printers set last_test_at = now() where id = nullif(p->>'id', '')::uuid and organization_id = v_org and deleted_at is null returning * into x;
  if x.id is null then raise exception 'POS_NOT_FOUND: printer not found'; end if;
  return public.rst_printer_json(x);
end $$;

revoke all on function public.rst_devices_list(jsonb), public.rst_printer_save(jsonb), public.rst_printer_delete(jsonb), public.rst_printer_tested(jsonb) from public, anon;
grant execute on function public.rst_devices_list(jsonb), public.rst_printer_save(jsonb), public.rst_printer_delete(jsonb), public.rst_printer_tested(jsonb) to authenticated, service_role;

-- the receipt names the default receipt printer first
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.rst_receipt_view(jsonb)'::regprocedure);
  if position('x.is_default desc' in v_def) > 0 then return; end if;
  v_new := replace(v_def, 'order by (x.location_id is null), x.created_at limit 1)', 'order by x.is_default desc, (x.location_id is null), x.created_at limit 1)');
  if v_new = v_def then raise exception '0638: rst_receipt_view is not the expected definition'; end if;
  execute v_new;
end $$;

notify pgrst, 'reload schema';
commit;
