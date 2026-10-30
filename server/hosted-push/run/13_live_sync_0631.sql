-- ==========================================================================================================================
-- HOSTED: 0631 live sync (30 Oct 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- Lets each business hear its own live channels (KOT, orders, stock), sends order and stock changes on them, and lets a restaurant
-- receive ingredients without an MRP (stores keep the rule). Checked on a copy of hosted (29 Oct dump + the pushed pieces).
-- ==========================================================================================================================
begin;
-- 0631: KOT, KDS, orders, stock and purchases kept in step on every screen (founder, 30 Oct 2026: "KOT-KDS-Inventory-Purchase all
-- should be synced").
-- The database already kept them in step (an order takes its ingredients when it goes to the kitchen, the KDS and the KOT read the
-- same tickets, a received purchase adds its stock) and already broadcast KOT changes on 'org:<business>:kitchen'. But nobody could
-- hear those broadcasts (private channels with no rule on realtime.messages), and orders and stock sent none, so each screen only
-- caught up on its 20-second re-read. Now:
--   * a member of a business may hear its live channels: org:<business>:kitchen, :orders and :stock (realtime.messages rule);
--   * an order sends 'order_updated' on :orders when it is placed or its status, total or table changes;
--   * stock sends one 'stock_changed' on :stock per business per statement (orders, receipts, counts, purchases alike);
--   * receiving goods (pur_receive_post) no longer needs an MRP in a restaurant (founder, 30 Oct 2026; stores keep it): a blank MRP
--     keeps the catalogue's MRP as it was.
-- The app listens (lib/api/live_sync.dart) and re-reads the screen at once; the 20-second re-read stays as a fallback.

-- the broadcast helper (the same body hosted has; created here where it is missing)
create or replace function public.ol_rt_send(p_topic text, p_event text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is null then return; end if;
  execute 'select realtime.send($1, $2, $3, true)' using coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('at', now()), p_event, p_topic;
exception when others then
  raise warning 'realtime notice skipped for %: %', p_topic, sqlerrm;
end $$;
revoke all on function public.ol_rt_send(text, text, jsonb) from public, anon, authenticated;

-- who may hear a business's live channels: its active members, and only for org:<that business>:kitchen | orders | stock
do $do$
begin
  if to_regclass('realtime.messages') is null then return; end if;
  execute 'drop policy if exists "members hear their business live" on realtime.messages';
  execute $p$
    create policy "members hear their business live" on realtime.messages for select to authenticated using (
      realtime.messages.extension = 'broadcast'
      and realtime.topic() ~ '^org:[0-9a-f-]{36}:(kitchen|orders|stock)$'
      and exists (select 1 from public.org_users ou
                   where ou.user_id = auth.uid() and ou.status = 'active'
                     and ou.organization_id = split_part(realtime.topic(), ':', 2)::uuid)
    )
  $p$;
end $do$;

-- orders: placed, or a new status, total or table
create or replace function public.orders_live_notify() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and (new.status, new.total, new.table_id) is not distinct from (old.status, old.total, old.table_id) then return null; end if;
  perform public.ol_rt_send('org:' || new.organization_id || ':orders', 'order_updated',
    jsonb_build_object('order_id', new.id, 'status', new.status, 'table_id', new.table_id));
  return null;
end $$;
drop trigger if exists orders_live_notify on public.orders;
create trigger orders_live_notify after insert or update on public.orders for each row execute function public.orders_live_notify();

-- stock: one message per business per statement (a big receipt or count is one message, not hundreds)
create or replace function public.stock_live_notify() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid;
begin
  for v_org in select distinct organization_id from new_rows loop
    perform public.ol_rt_send('org:' || v_org || ':stock', 'stock_changed', '{}'::jsonb);
  end loop;
  return null;
end $$;
drop trigger if exists stock_live_notify on public.stock_movements;
create trigger stock_live_notify after insert on public.stock_movements referencing new table as new_rows
  for each statement execute function public.stock_live_notify();

-- receiving in a restaurant: the MRP is optional (rewritten in place from the live definition; nothing to do where it is missing)
do $$
declare v_def text; v_new text;
begin
  if to_regprocedure('public.pur_receive_post(jsonb)') is null then raise notice '0631: no pur_receive_post here'; return; end if;
  v_def := pg_get_functiondef('public.pur_receive_post(jsonb)'::regprocedure);
  if position('v_mrp_optional' in v_def) > 0 then return; end if;  -- already done
  v_new := replace(v_def, 'v_mrp bigint;', 'v_mrp bigint; v_mrp_optional boolean := false;');
  v_new := replace(v_new,
    '    if v_mrp is null or v_mrp <= 0 then raise exception ''PUR_NEEDS_MRP: add the MRP on line % to add it to stock'', v_n; end if;',
    '    -- a restaurant''s ingredients often have no MRP (0631): optional there; a store still needs it
    v_mrp_optional := v_mrp_optional or exists (select 1 from public.organizations o where o.id = v_org and lower(coalesce(o.business_domain, '''')) = ''restaurant'');
    if (v_mrp is null or v_mrp <= 0) and not v_mrp_optional then raise exception ''PUR_NEEDS_MRP: add the MRP on line % to add it to stock'', v_n; end if;
    if v_mrp is not null and v_mrp <= 0 then v_mrp := null; end if;');
  v_new := replace(v_new, 'set mrp_minor = v_mrp,', 'set mrp_minor = coalesce(v_mrp, mrp_minor),');
  if position('v_mrp_optional := v_mrp_optional or' in v_new) = 0 or position('coalesce(v_mrp, mrp_minor)' in v_new) = 0 then
    raise exception '0631: pur_receive_post is not the expected version; not changed';
  end if;
  execute v_new;
end $$;

-- KOTs: hosted broadcasts them already (kot_tickets_realtime, which also tells a OneLocal customer); where that trigger is missing,
-- a plain one says the same on :kitchen, so the kitchen screens hear every KOT made or moved
create or replace function public.kot_live_notify() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  perform public.ol_rt_send('org:' || new.organization_id || ':kitchen', case when tg_op = 'INSERT' then 'kot_created' else 'kot_updated' end,
    jsonb_build_object('kot_id', new.id, 'kot_no', new.kot_no, 'order_id', new.order_id, 'status', new.status));
  return null;
end $$;
do $$
begin
  if exists (select 1 from pg_trigger where tgrelid = 'public.kot_tickets'::regclass and tgname in ('kot_tickets_realtime', 'kot_live_notify')) then return; end if;
  create trigger kot_live_notify after insert or update on public.kot_tickets for each row execute function public.kot_live_notify();
end $$;

notify pgrst, 'reload schema';
commit;
