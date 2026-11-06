-- HOSTED: 0668 Store POS: a paid counter bill is finished, with nothing to accept or pack. Restaurant and service are not changed.
-- 0668 (6 Nov 2026): a store's counter sale is finished when it is paid. STORE ONLY, founder: "paid walkin bills/ counter sales should not appear in new orders. Only online orders should appear".
-- pos_checkout, pos_checkout_pay and pos_split_pay all call pos_fulfilment_open, so every paid counter bill got a packing job: it logged "awaiting store acceptance"
-- and its own page offered "Accept order". Now a store's counter bill gets no job. Online orders, and bills with a delivery address, still do. A restaurant or service business is not changed.
-- The jobs already open on a store's counter bills are finished below (nothing is deleted: these records are never deleted). Safe to run again.
do $$
declare
  v_src text := replace(pg_get_functiondef('public.pos_fulfilment_open(uuid,jsonb)'::regprocedure), E'\r', '');
  v_old text := $r$if exists (select 1 from public.pos_fulfilments where order_id = p_order) then return; end if;$r$;
  v_new text := $r$if exists (select 1 from public.pos_fulfilments where order_id = p_order) then return; end if;
  -- 0668: a store's counter sale is finished when it is paid: nothing to accept or pack
  if v_o.channel <> 'online' and coalesce(v_o.placed_by, '') <> 'integration' and coalesce(p_delivery, '{}'::jsonb) = '{}'::jsonb
     and lower(coalesce((select business_domain from public.organizations where id = v_o.organization_id), '')) !~ 'restaurant|food|service' then return; end if;$r$;
begin
  if v_src like '%0668: a store%' then return; end if;
  if (char_length(v_src) - char_length(replace(v_src, v_old, ''))) <> char_length(v_old) then
    raise exception '0668: pos_fulfilment_open has changed shape; nothing was changed'; end if;
  execute replace(v_src, v_old, v_new);
end $$;

-- the jobs already open on a store's paid counter bills: walked to completed through the allowed steps, dated when the bill was paid
do $$
declare
  r record; v_stage text; v_ver int; v_next text; v_at timestamptz; v_steps int;
begin
  for r in
    select f.order_id, f.stage, f.version
      from public.pos_fulfilments f
      join public.orders o on o.id = f.order_id
      join public.organizations g on g.id = o.organization_id
     where f.stage not in ('completed', 'cancelled') and f.delivery_address is null
       and o.channel <> 'online' and coalesce(o.placed_by, '') <> 'integration' and o.status in ('paid', 'delivered')
       and lower(coalesce(g.business_domain, '')) !~ 'restaurant|food|service'
  loop
    v_stage := r.stage; v_ver := r.version; v_steps := 0;
    select coalesce(max(p.created_at), now()) into v_at from public.payments p where p.order_id = r.order_id;
    while v_stage <> 'completed' loop
      v_steps := v_steps + 1;
      if v_steps > 8 then raise exception '0668: no way to finish the job on order %', r.order_id; end if;
      select t.to_status into v_next from public.order_transitions t
       where t.entity = 'pos_fulfilments' and t.from_status = v_stage and t.to_status <> 'cancelled'
       order by array_position(array['completed', 'ready', 'picked', 'picking', 'dispatched'], t.to_status) limit 1;
      if v_next is null then raise exception '0668: no step from % on order %', v_stage, r.order_id; end if;
      v_ver := v_ver + 1;
      perform public.pos_fulfilment_arm(r.order_id, v_next, v_ver);
      update public.pos_fulfilments set stage = v_next, version = v_ver, exception = null, exception_note = null,
             handover_method = case when v_next = 'completed' then 'collection' else handover_method end,
             completed_at = case when v_next = 'completed' then v_at end
       where order_id = r.order_id;
      v_stage := v_next;
    end loop;
  end loop;
end $$;
