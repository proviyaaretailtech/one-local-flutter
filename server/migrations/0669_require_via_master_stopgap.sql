-- 0669 (6 Nov 2026): STOPGAP. Payments and refunds work again for restaurant and service businesses, on the founder's go-ahead. Same as hosted piece 48, run on hosted the same day.
-- 0658 and 0659 call public.require_via_master(text) from pos_record_payment, rst_bill_pay, rst_bill_split, rst_bill_refund and rst_adj__refund_apply, but no migration defined it
-- and hosted did not have it (pieces 46 and 47), so those functions stopped with 42883 and the app showed "Something went wrong".
-- THIS CHECKS NOTHING: a Master pause of payments or refunds stops nothing until the real check replaces it. When it does, also take out the store's skip (0667).
-- A function that already exists is left unchanged. Safe to run again.
do $$
begin
  if to_regprocedure('public.require_via_master(text)') is not null then return; end if;
  execute $f$
    create function public.require_via_master(p_capability text) returns void
    language sql stable set search_path = public, pg_temp as 'select'
  $f$;
  execute $c$comment on function public.require_via_master(text) is 'STOPGAP 6 Nov 2026: checks nothing. Replace with the real Master pause check.'$c$;
  revoke all on function public.require_via_master(text) from public, anon;
  grant execute on function public.require_via_master(text) to authenticated, service_role;
end $$;
