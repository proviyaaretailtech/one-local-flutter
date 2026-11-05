-- READ ONLY (4 Nov 2026): why was niks.test@onelocal.co sent back to the sign-in page? Changes nothing.
-- The app only goes to sign-in when hosted refuses to renew the session (revoked, signed out elsewhere, token used twice, login
-- changed or deleted). This lists the login's sessions and the last 40 sign-in events (newest first). No token values are shown.
with u as (select id from auth.users where lower(email) = 'niks.test@onelocal.co')
select * from (
  select 'login' as what, now() as at,
         coalesce((select format('created=%s | last sign-in=%s | banned until=%s | deleted=%s | updated=%s',
                    created_at, coalesce(last_sign_in_at::text, 'never'), coalesce(banned_until::text, 'no'), (deleted_at is not null), updated_at)
                   from auth.users where id in (select id from u)), 'NO SUCH LOGIN') as detail
  union all
  select 'session', s.created_at,
         format('session %s | refreshed=%s | not after=%s | level=%s | device=%s | tokens: %s live, %s revoked',
                left(s.id::text, 8), coalesce(s.refreshed_at::text, '-'), coalesce(s.not_after::text, '-'), coalesce(s.aal::text, '-'),
                left(coalesce(s.user_agent, '-'), 60),
                (select count(*) from auth.refresh_tokens r where r.session_id = s.id and not r.revoked),
                (select count(*) from auth.refresh_tokens r where r.session_id = s.id and r.revoked))
    from auth.sessions s where s.user_id in (select id from u)
  union all
  select 'event', a.created_at,
         format('%s | %s', a.payload ->> 'action', coalesce(a.payload ->> 'log_type', '') || ' ' || coalesce(a.payload -> 'traits' ->> 'provider', ''))
    from (select * from auth.audit_log_entries
           where payload ->> 'actor_id' in (select id::text from u)
           order by created_at desc limit 40) a
) x
order by case what when 'login' then 0 else 1 end, at desc;
