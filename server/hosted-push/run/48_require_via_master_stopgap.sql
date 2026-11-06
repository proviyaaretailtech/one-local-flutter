-- =====================================================================================================================
-- HOSTED, STOPGAP (6 Nov 2026): creates public.require_via_master(text) ONLY IF IT IS MISSING, so payments and refunds work again.
-- Migrations 0658 and 0659 call it from pos_record_payment, rst_bill_pay, rst_bill_split, rst_bill_refund and rst_adj__refund_apply, but
-- no migration defines it. A function that already exists is left unchanged.
-- WHAT THIS DOES NOT DO: it checks nothing, so a Master pause of payments or refunds does not stop anything until the real check is written.
-- It affects every POS type that pays through these functions. One transaction: if it stops with an error, nothing changed.
-- =====================================================================================================================
begin;
do $$
begin
  if to_regprocedure('public.require_via_master(text)') is not null then
    raise notice 'require_via_master already exists: nothing changed';
    return;
  end if;
  execute $f$
    create function public.require_via_master(p_capability text) returns void
    language sql stable set search_path = public, pg_temp as 'select'
  $f$;
  execute $c$comment on function public.require_via_master(text) is 'STOPGAP 6 Nov 2026: checks nothing. Replace with the real Master pause check.'$c$;
  revoke all on function public.require_via_master(text) from public, anon;
  grant execute on function public.require_via_master(text) to authenticated, service_role;
end $$;
commit;
