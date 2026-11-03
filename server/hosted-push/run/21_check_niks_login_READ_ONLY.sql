-- READ ONLY: why can't niks.test@onelocal.co sign in? Changes nothing. Shows the login, how it can sign in, and its Niks Cafe membership.
with u as (select * from auth.users where lower(email) = 'niks.test@onelocal.co' or phone in ('919999999999', '+919999999999'))
select 'login' as what,
       case when not exists (select 1 from u) then 'NO SUCH LOGIN'
            else (select string_agg(format('email=%s phone=%s | email confirmed=%s | has password=%s | banned until=%s | deleted=%s | last sign-in=%s',
                    email, coalesce(phone, '-'), (email_confirmed_at is not null), (encrypted_password is not null and encrypted_password <> ''),
                    coalesce(banned_until::text, 'no'), (deleted_at is not null), coalesce(last_sign_in_at::text, 'never')), ' || ') from u) end as result
union all
select 'sign-in methods', coalesce((select string_agg(i.provider, ', ') from auth.identities i where i.user_id in (select id from u)), 'NONE (no identity: email sign-in cannot work)')
union all
select 'business membership', coalesce((select string_agg(format('%s | role=%s | status=%s', o.name, r.slug, ou.status), ' || ')
                                          from public.org_users ou join public.organizations o on o.id = ou.organization_id left join public.roles r on r.id = ou.role_id
                                         where ou.user_id in (select id from u)), 'NOT A MEMBER of any business');
