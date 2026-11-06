-- HOSTED, READ ONLY IN EFFECT (6 Nov 2026): why does Split Pay answer 500 on test bill P-00018 of Purushottam Super Market?
-- It tries the split twice, with and without a UPI reference, then ALWAYS stops with an error whose text is the answer.
-- That error undoes everything, so nothing is saved. Seeing a red error here is expected: copy its text back.
do $$
declare
  v_org uuid; v_user uuid; v_o uuid; v_total numeric; v_status text;
  v_a text; v_b text; v_state text; v_msg text; v_ctx text;
begin
  select id into v_org from public.organizations where name = 'Purushottam Super Market' limit 1;
  if v_org is null then raise exception 'RESULT: store not found'; end if;
  select id, total, status::text into v_o, v_total, v_status from public.orders where organization_id = v_org and display_no = 'P-00018' limit 1;
  if v_o is null then raise exception 'RESULT: bill P-00018 not found'; end if;
  select u.user_id into v_user from public.org_users u join public.roles r on r.id = u.role_id
   where u.organization_id = v_org and u.status = 'active' and r.slug = 'org_owner' limit 1;
  if v_user is null then raise exception 'RESULT: no active owner found'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  set local role authenticated;

  begin
    perform public.pos_split_pay(jsonb_build_object('order_id', v_o, 'idempotency_key', 'zz-check-46-a', 'payments', jsonb_build_array(
      jsonb_build_object('method', 'cash', 'amount', 20), jsonb_build_object('method', 'upi', 'amount', 20, 'reference', 'TESTUTR6NOV'))));
    raise exception 'ZZ_WORKED';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_ctx = pg_exception_context;
    v_a := v_state || ' ' || v_msg || ' @ ' || left(v_ctx, 700);
  end;

  begin
    perform public.pos_split_pay(jsonb_build_object('order_id', v_o, 'idempotency_key', 'zz-check-46-b', 'payments', jsonb_build_array(
      jsonb_build_object('method', 'cash', 'amount', 20), jsonb_build_object('method', 'upi', 'amount', 20))));
    raise exception 'ZZ_WORKED';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_ctx = pg_exception_context;
    v_b := v_state || ' ' || v_msg || ' @ ' || left(v_ctx, 700);
  end;

  raise exception 'RESULT bill status=% total=% ||| WITH REFERENCE: % ||| NO REFERENCE: %', v_status, v_total, replace(v_a, E'\n', ' / '), replace(v_b, E'\n', ' / ');
end $$;
