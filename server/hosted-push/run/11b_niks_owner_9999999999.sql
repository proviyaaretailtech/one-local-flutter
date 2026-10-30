-- Niks Cafe (hosted, TESTING): make one login the owner of the test Niks Cafe (bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd).
-- 1. Sign in once on the app with the mobile number (it creates the login), then close the app.
-- 2. Put that 10-digit number on the line below, run this whole file in the SQL editor, and sign in again: the app opens Niks Cafe.
-- Use a number that is in no other business: the app opens the first business a login belongs to.
-- One transaction; it stops with a message (and changes nothing) if the number has no login or already belongs to another business.
do $$
declare
  v_mobile text := '9999999999';  -- <<< the 10-digit mobile number
  v_org constant uuid := 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd';
  v_user auth.users%rowtype;
  v_other text;
begin
  if v_mobile !~ '^[6-9][0-9]{9}$' then raise exception 'Put the 10-digit mobile number in v_mobile first.'; end if;
  select * into v_user from auth.users where phone in ('91' || v_mobile, '+91' || v_mobile) order by created_at limit 1;
  if not found then raise exception 'No login with +91 % yet: sign in once on the app with it, then run this again.', v_mobile; end if;
  select string_agg(o.name, ', ') into v_other from public.org_users ou join public.organizations o on o.id = ou.organization_id
   where ou.user_id = v_user.id and ou.organization_id <> v_org and ou.status = 'active';
  if v_other is not null then raise exception '+91 % already belongs to %: the app would open that one. Use another number.', v_mobile, v_other; end if;
  insert into public.org_users (organization_id, user_id, role_id, email, full_name, status, location_id)
  values (v_org, v_user.id, (select id from public.roles where slug = 'org_owner'),
          coalesce(nullif(v_user.email, ''), v_mobile || '@phone.onelocal.invalid'),
          coalesce(v_user.raw_user_meta_data->>'full_name', v_user.raw_user_meta_data->>'name', 'Niks Cafe owner (test)'), 'active', null)
  on conflict do nothing;
  raise notice 'Done: +91 % is now the owner of Niks Cafe. Sign out and sign in again.', v_mobile;
end $$;
