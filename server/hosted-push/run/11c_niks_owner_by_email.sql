-- Niks Cafe (hosted, TESTING): make an EMAIL login the owner of the test Niks Cafe (bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd).
-- 1. Supabase -> Authentication -> Users -> Add user -> Create new user: the email below, a password, tick "Auto confirm user".
-- 2. Run this whole file in the SQL editor (change v_email first if you used another address).
-- 3. On the app: Sign in -> "Use email instead" -> the email and password. The app opens Niks Cafe.
-- One transaction; it stops with a message (and changes nothing) if the email has no login or already belongs to another business.
do $$
declare
  v_email text := 'niks.test@onelocal.co';  -- <<< the email of the login you created
  v_org constant uuid := 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd';
  v_user auth.users%rowtype;
  v_other text;
begin
  v_email := lower(btrim(v_email));
  select * into v_user from auth.users where lower(email) = v_email order by created_at limit 1;
  if not found then raise exception 'No login with % yet: create it in Authentication -> Users first, then run this again.', v_email; end if;
  if v_user.email_confirmed_at is null then raise exception '% is not confirmed: tick "Auto confirm user" when creating it (or confirm it in Authentication -> Users).', v_email; end if;
  select string_agg(o.name, ', ') into v_other from public.org_users ou join public.organizations o on o.id = ou.organization_id
   where ou.user_id = v_user.id and ou.organization_id <> v_org and ou.status = 'active';
  if v_other is not null then raise exception '% already belongs to %: the app would open that one. Use another email.', v_email, v_other; end if;
  insert into public.org_users (organization_id, user_id, role_id, email, full_name, status, location_id)
  values (v_org, v_user.id, (select id from public.roles where slug = 'org_owner'), v_email, 'Niks Cafe owner (test)', 'active', null)
  on conflict do nothing;
  raise notice 'Done: % is now the owner of Niks Cafe. Sign in on the app with "Use email instead".', v_email;
end $$;
