-- 0662 A web order (placed on the restaurant's own page, ol_orders.source = 'web') is served and paid at the restaurant: when its POS
-- order is paid, the customer order is complete (delivered). Before this it stayed "packed" for ever (2026-11-05 end-to-end run).
-- The move goes through the status gate with its own event, so the legality guard and the event spine see it like any other.
begin;
insert into public.order_transitions (entity, from_status, event, to_status)
select 'ol_orders', s, 'paid_at_restaurant', 'delivered' from unnest(array['accepted', 'packed']) s
where not exists (select 1 from public.order_transitions t where t.entity = 'ol_orders' and t.from_status = s and t.event = 'paid_at_restaurant');

create or replace function public.orders_paid_completes_web_order() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ol uuid;
begin
  select o.id into v_ol from public.ol_orders o where o.pos_order_id = new.id and o.source = 'web' and o.status in ('accepted', 'packed') for update;
  if v_ol is null then return null; end if;
  perform public.status_gate('ol_orders', v_ol, 'paid_at_restaurant');
  update public.ol_orders set status = 'delivered' where id = v_ol;
  return null;
end $$;
revoke all on function public.orders_paid_completes_web_order() from public, anon, authenticated;

drop trigger if exists orders_zz_paid_completes_web on public.orders;
create trigger orders_zz_paid_completes_web after update of status on public.orders
  for each row when (new.status = 'paid' and old.status is distinct from 'paid' and new.channel = 'online')
  execute function public.orders_paid_completes_web_order();

-- web orders already paid before this file: complete them the same way
do $$
declare r record;
begin
  for r in select ol.id from public.ol_orders ol join public.orders o on o.id = ol.pos_order_id
            where ol.source = 'web' and ol.status in ('accepted', 'packed') and o.status = 'paid' loop
    perform public.status_gate('ol_orders', r.id, 'paid_at_restaurant');
    update public.ol_orders set status = 'delivered' where id = r.id;
  end loop;
end $$;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0662_web_order_paid_completes.sql', 'Paid web order completes its customer order (status gate event paid_at_restaurant) (local dev DB 2026-11-05)') on conflict do nothing;
commit;
