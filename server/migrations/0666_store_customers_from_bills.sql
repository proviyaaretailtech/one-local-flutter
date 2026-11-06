-- 0666 (5 Nov 2026): a store's Customers list shows the people on its bills. STORE ONLY: a restaurant or service business is skipped.
-- A bill saved with a customer's 10-digit mobile number finds or adds that customer and points at them. It never stops a sale: a bad number, or anything
-- going wrong here, leaves the bill as it was. Bills already saved are filled in below. Safe to run again.

create or replace function public.pos_orders__store_customer() returns trigger
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_phone text; v_name text; v_first text; v_last text; v_id uuid;
begin
  if new.pos_customer_id is not null or coalesce(btrim(new.customer_phone), '') = '' then return new; end if;
  if lower(coalesce((select business_domain from public.organizations where id = new.organization_id), '')) ~ 'restaurant|food|service' then return new; end if;
  v_phone := public.cust_phone(new.customer_phone);
  if v_phone is null or v_phone !~ '^[6-9][0-9]{9}$' then return new; end if;
  select id into v_id from public.pos_customers where organization_id = new.organization_id and phone = v_phone and deleted_at is null limit 1;
  if v_id is null then
    v_name := btrim(coalesce(new.customer_name, ''));
    if v_name = '' or lower(v_name) in ('guest', 'walk-in', 'walk in') then v_name := 'Customer'; end if;
    v_first := split_part(v_name, ' ', 1);
    v_last := btrim(substr(v_name, char_length(v_first) + 1));
    insert into public.pos_customers (organization_id, location_id, first_name, last_name, phone, created_by)
    values (new.organization_id, new.location_id, v_first, v_last, v_phone, auth.uid())
    returning id into v_id;
  end if;
  new.pos_customer_id := v_id;
  return new;
exception when others then
  return new;
end $f$;
revoke all on function public.pos_orders__store_customer() from public, anon, authenticated;

drop trigger if exists orders_store_customer on public.orders;
create trigger orders_store_customer before insert or update of customer_phone on public.orders
  for each row execute function public.pos_orders__store_customer();

-- the people already on a store's bills, newest name first
do $b$
declare o record; v_phone text; v_name text; v_first text; v_id uuid;
begin
  for o in
    select x.id, x.organization_id, x.location_id, x.customer_name, x.customer_phone
      from public.orders x join public.organizations g on g.id = x.organization_id
     where x.pos_customer_id is null and coalesce(btrim(x.customer_phone), '') <> ''
       and lower(coalesce(g.business_domain, '')) !~ 'restaurant|food|service'
     order by x.created_at desc
  loop
    v_phone := public.cust_phone(o.customer_phone);
    continue when v_phone is null or v_phone !~ '^[6-9][0-9]{9}$';
    select id into v_id from public.pos_customers where organization_id = o.organization_id and phone = v_phone and deleted_at is null limit 1;
    if v_id is null then
      v_name := btrim(coalesce(o.customer_name, ''));
      if v_name = '' or lower(v_name) in ('guest', 'walk-in', 'walk in') then v_name := 'Customer'; end if;
      v_first := split_part(v_name, ' ', 1);
      insert into public.pos_customers (organization_id, location_id, first_name, last_name, phone)
      values (o.organization_id, o.location_id, v_first, btrim(substr(v_name, char_length(v_first) + 1)), v_phone)
      returning id into v_id;
    end if;
    -- a paid bill may refuse to be changed: the customer is still on file
    begin
      update public.orders set pos_customer_id = v_id where id = o.id;
    exception when others then null;
    end;
  end loop;
end $b$;
