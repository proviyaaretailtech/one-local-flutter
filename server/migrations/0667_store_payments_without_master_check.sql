-- 0667 (6 Nov 2026): a store can take payments again. STORE ONLY, on the founder's instruction: "Only fix store pos dont make any changes in restaurant and service pos".
-- 0659 put a call to public.require_via_master('pos_capture') in pos_record_payment, but no migration defines that function and hosted does not have it
-- (checked on hosted, pieces 46 and 47), so every payment through this writer stops with 42883 and the app shows "Something went wrong".
-- A store now skips that one call. A restaurant or service business still makes it, so it behaves exactly as before, including failing while the function is missing.
-- Every other check in the writer stays. WHEN THE REAL FUNCTION EXISTS, take this back out so a store obeys the Master pause too. Safe to run again.
do $$
declare
  v_src text := replace(pg_get_functiondef('public.pos_record_payment(jsonb)'::regprocedure), E'\r', '');
  v_old text := $r$perform public.require_via_master('pos_capture');$r$;
  v_new text := $r$if lower(coalesce((select business_domain from public.organizations where id = v_o.organization_id), '')) ~ 'restaurant|food|service' then perform public.require_via_master('pos_capture'); end if; -- 0667: a store skips this until the function exists$r$;
begin
  if v_src like '%0667: a store skips%' then return; end if;
  if (char_length(v_src) - char_length(replace(v_src, v_old, ''))) <> char_length(v_old) then
    raise exception '0667: pos_record_payment does not have exactly one Master check; nothing was changed'; end if;
  execute replace(v_src, v_old, v_new);
end $$;
