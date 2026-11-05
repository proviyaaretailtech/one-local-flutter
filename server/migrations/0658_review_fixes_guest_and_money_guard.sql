-- 0658 Fixes from the independent review of 2026-11-04 (agent/reviews/partner-2026-11-04.md). Local dev DB 2026-11-04.
--   SM-01  an accepted pre-order no longer fires the kitchen ticket or uses stock at once: it waits as a held pickup order
--          (in_billing) that staff send to the kitchen near pickup time (Orders -> held orders -> send to kitchen).
--   CON-1  the accepted pre-order is made in the outlet whose inbox it was in (pos_place_order takes location_id for orders
--          without a table, checked against the business and active).
--   GX-RL-1 one phone/browser cannot fill a restaurant's pre-order inbox: per client (hash of the network address from the POS
--          server) at most 3 waiting and 6 per hour per restaurant, on top of the per-phone limit.
--   G05    the 0656 helpers are not executable by anon / PUBLIC / authenticated (definer functions call them as their owner).
--   F2     the Master money guard is back in the restaurant money functions that partner 0649/0645/0640 re-created without it:
--          payments and refunds stop when Master pauses pos_capture / pos_refund (canonical 0602 contract).
begin;

-- ------------------------------------------------------------------------------------------------------------- G05
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p where p.pronamespace = 'public'::regnamespace
             and (p.proname like 'gx\_\_%' or p.proname = 'org_listing_slug_not_reserved') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------- CON-1
do $$
declare v_src text := pg_get_functiondef('public.pos_place_order'::regproc);
  v_old text := $r$  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;$r$;
begin
  if v_src not like '%0658: an order without a table may name its outlet%' then
    if position(v_old in v_src) = 0 then raise exception '0658: pos_place_order has changed shape; patch it by hand'; end if;
    v_src := replace(v_src, v_old, $r$  -- 0658: an order without a table may name its outlet (an accepted pre-order stays in the outlet that took it)
  if v_loc is null and nullif(p->>'location_id', '') is not null then
    select id into v_loc from public.locations where id = (p->>'location_id')::uuid and organization_id = v_org and status = 'active';
    if v_loc is null then raise exception 'POS_BAD_REQUEST: that outlet is not one of yours or is closed'; end if;
  end if;
$r$ || v_old);
    execute v_src;
  end if;
end $$;

-- --------------------------------------------------------------------------------------------------------- SM-01
do $$
declare v_src text := pg_get_functiondef('public.guest_request_decide'::regproc);
begin
  if v_src not like '%''fire_kot'', false%' then
    v_src := replace(v_src,
      $r$v_place := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'pickup',$r$,
      $r$v_place := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'pickup', 'location_id', r.location_id, 'fire_kot', false,$r$);
    if v_src not like '%''fire_kot'', false%' then raise exception '0658: guest_request_decide has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------------- GX-RL-1
alter table public.guest_order_requests add column if not exists client_hash text;
create index if not exists guest_order_requests_preorder_client on public.guest_order_requests (organization_id, client_hash, created_at) where kind = 'preorder';

do $$
declare v_src text := pg_get_functiondef('public.gx_preorder_place'::regproc);
  v_anchor text := $r$  if (select count(*) from public.guest_order_requests q where q.organization_id = v_org and q.kind = 'preorder' and q.status = 'waiting') >= 30 then$r$;
begin
  if v_src not like '%per client%' then
    if position(v_anchor in v_src) = 0 then raise exception '0658: gx_preorder_place has changed shape; patch it by hand'; end if;
    v_src := replace(v_src, v_anchor, $r$  -- per client (the POS server's hash of the network address): one browser cannot fill the inbox with made-up numbers
  if nullif(p->>'client', '') is not null then
    if (select count(*) from public.guest_order_requests q where q.organization_id = v_org and q.kind = 'preorder' and q.client_hash = p->>'client' and q.status = 'waiting') >= 3
       or (select count(*) from public.guest_order_requests q where q.organization_id = v_org and q.kind = 'preorder' and q.client_hash = p->>'client' and q.created_at > now() - interval '1 hour') >= 6 then
      raise exception 'GUEST_RATE_LIMITED: too many pre-orders from this phone. Please call the restaurant.'; end if;
  end if;
$r$ || v_anchor);
    v_src := replace(v_src, $r$guest_name, note, kind, pickup_at, guest_phone, track_hash)$r$, $r$guest_name, note, kind, pickup_at, guest_phone, track_hash, client_hash)$r$);
    v_src := replace(v_src, $r$v_name, v_note, 'preorder', v_at, v_phone, public.guest__hash(v_token))$r$, $r$v_name, v_note, 'preorder', v_at, v_phone, public.guest__hash(v_token), left(nullif(p->>'client', ''), 64))$r$);
    if v_src not like '%client_hash)%' then raise exception '0658: gx_preorder_place insert has changed shape; patch it by hand'; end if;
    execute v_src;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------- F2
do $$
declare r record; v_src text; v_kind text;
begin
  for r in select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace
             and p.proname in ('rst_bill_pay', 'rst_bill_split', 'rst_bill_refund', 'rst_adj__refund_apply') loop
    v_kind := case when r.proname in ('rst_bill_pay', 'rst_bill_split') then 'pos_capture' else 'pos_refund' end;
    v_src := pg_get_functiondef(r.oid);
    if v_src !~ 'require_via_master' then
      if position(E'\nbegin\n' in v_src) = 0 then raise exception '0658: % has no plain begin line; patch it by hand', r.proname; end if;
      v_src := regexp_replace(v_src, E'\nbegin\n', E'\nbegin\n  perform public.require_via_master(''' || v_kind || E''');   -- 0658: Master pause applies (canonical 0602)\n');
      execute v_src;
    end if;
  end loop;
end $$;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0658_review_fixes_guest_and_money_guard.sql', 'Review 2026-11-04 fixes: pre-order accepted as held pickup in its outlet, per-client pre-order cap, 0656 helpers not callable by apps, Master money guard back in rst_bill_pay/split/refund (local dev DB)')
on conflict do nothing;
commit;
