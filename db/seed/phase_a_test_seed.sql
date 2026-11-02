-- Phase A test seed. LOCAL stack only. Creates one staff membership for the
-- test user phasea.member@test.local (auth user created via the local admin API
-- by the test script; no password in this file). Does not touch hosted data.
begin;
insert into public.org_users (organization_id, user_id, role_id, email, full_name, status)
select '457794b2-2fc5-4600-8ebc-bdf67c17a4ee', u.id, '6035ff28-8156-4ed5-a0ce-fea51a613c89',
       u.email, 'Phase A Tester', 'active'
from auth.users u
where u.email = 'phasea.member@test.local'
  and not exists (select 1 from public.org_users ou where ou.user_id = u.id and ou.organization_id = '457794b2-2fc5-4600-8ebc-bdf67c17a4ee');
commit;
