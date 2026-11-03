-- 0639: Sign out chosen devices (founder, 2 Nov 2026: "show a pop up asking which device you want to sign out ... in which devices it is
-- signed in"). Manage account lists the login's sessions (acct_get → devices, each with its id); the person ticks the ones to sign out.
--   * acct_sign_out_devices({session_ids}): ends those sessions of the signed-in login only (their refresh tokens go with them), so that
--     phone or browser has to sign in again once its current access token runs out. This device is not ended here: the app signs itself
--     out with Supabase auth, so it lands on the sign-in page at once.
--   * an audit line, like "Sign out of all devices" (acct_signed_out_everywhere).
-- Nothing existing changes.

create or replace function public.acct_sign_out_devices(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_sid text := current_setting('request.jwt.claims', true)::jsonb ->> 'session_id';
  v_ids uuid[]; v_n int;
begin
  if v_uid is null then raise exception 'ACCT_FORBIDDEN: sign in first'; end if;
  if jsonb_typeof(p -> 'session_ids') is distinct from 'array' or jsonb_array_length(p -> 'session_ids') = 0 then
    raise exception 'ACCT_INVALID: choose a device to sign out';
  end if;
  begin
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(p -> 'session_ids') x;
  exception when invalid_text_representation then raise exception 'ACCT_INVALID: that device is not known';
  end;
  -- only this login's own sessions, never this one
  with gone as (
    delete from auth.sessions s where s.user_id = v_uid and s.id = any(v_ids) and s.id::text is distinct from v_sid returning s.id
  ) select count(*) into v_n from gone;
  insert into public.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, before, after)
  values (public.current_org_id(), v_uid, 'account.sign_out_devices', 'auth_user', v_uid::text, null, jsonb_build_object('sessions', v_n));
  return jsonb_build_object('signed_out', v_n);
end $$;

revoke all on function public.acct_sign_out_devices(jsonb) from public, anon;
grant execute on function public.acct_sign_out_devices(jsonb) to authenticated;
