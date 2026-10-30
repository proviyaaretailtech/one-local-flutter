-- ==========================================================================================================================
-- HOSTED PUSH piece 01 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0630_stock_allocate_alias_fix.sql
-- 0630: stock coming in failed on hosted ("record "s" is not assigned yet"). The negative-stock change (store team, 29 Oct 2026, applied
-- straight to hosted) declared a loop variable `s` in stock_movement_allocate, and the same function uses `s` as a table alias in its
-- sale-reversal check. PL/pgSQL reads `s.ref_type` there as the unassigned variable, so every movement that adds stock (receipts,
-- opening stock, a cancelled order's stock coming back) failed. The variable is renamed `neg`; nothing else changes.
-- Rewritten in place from the live definition; where the clash is not there (the local DB, or once fixed) it does nothing.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef('public.stock_movement_allocate(bigint)'::regprocedure) into v_def;
  if v_def is null or position('v_short numeric; s record;' in v_def) = 0 then
    raise notice '0630: stock_movement_allocate has no loop variable s; nothing to fix';
    return;
  end if;
  v_new := replace(v_def, 'v_short numeric; s record;', 'v_short numeric; neg record;');
  v_new := replace(v_new, ' for s in', ' for neg in'); -- the one loop over the negative bins
  v_new := replace(v_new, 'v_short := least(v_left, s.short);', 'v_short := least(v_left, neg.short);');
  v_new := replace(v_new, 'values (m.organization_id, m.id, s.bin_id, s.lot_id, v_take);', 'values (m.organization_id, m.id, neg.bin_id, neg.lot_id, v_take);');
  if position('for neg in' in v_new) = 0 or position('neg.short' in v_new) = 0 or position('neg.bin_id, neg.lot_id' in v_new) = 0
     or v_new ~ '[^a-z_]s\.(short|bin_id, s\.lot_id, v_take)' then
    raise exception '0630: stock_movement_allocate is not the expected version; not changed';
  end if;
  execute v_new;
end $$;

notify pgrst, 'reload schema';
commit;
