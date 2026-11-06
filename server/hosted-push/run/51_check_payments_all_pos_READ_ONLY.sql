-- HOSTED, READ ONLY IN EFFECT (6 Nov 2026): after piece 48, do payments get past the Master check for a restaurant and a service business?
-- It makes a pretend Rs 40 bill and pays it by split, once in the first restaurant and once in the first service business it finds, and calls the restaurant's own
-- bill functions with an order that does not exist. Then it ALWAYS stops with an error whose text is the answer. That error undoes everything, so nothing is saved.
-- Seeing a red error here is expected: copy its text back. "42883" in the text would mean the function is still missing.
do $$
declare
  v_out text := ''; c record; v_org uuid; v_loc uuid; v_user uuid; v_o uuid; v_state text; v_msg text; v_res text; v_fn text;
begin
  v_out := 'function exists=' || (to_regprocedure('public.require_via_master(text)') is not null);

  -- a rollback cannot call back a message already sent: if a trigger here can reach outside the database, stop before touching anything
  select string_agg(distinct cl.relname || '.' || t.tgname, ', ') into v_res
    from pg_trigger t join pg_class cl on cl.oid = t.tgrelid join pg_proc f on f.oid = t.tgfoid join pg_namespace n on n.oid = f.pronamespace
   where not t.tgisinternal and cl.relnamespace = 'public'::regnamespace and cl.relname in ('orders', 'payments', 'order_items', 'order_events', 'pos_fulfilments', 'pos_customers')
     and (n.nspname = 'supabase_functions' or f.prosrc ~* '(net\.http|http_post|http_get|extensions\.http|dblink|pg_net)');
  if v_res is not null then raise exception 'RESULT % ||| STOPPED, no payment tried: these triggers can reach outside the database: %', v_out, v_res; end if;

  for c in select * from (values ('restaurant', 'restaurant|food'), ('service', 'service')) t(label, pat) loop
    v_org := null; v_user := null; v_loc := null;
    select g.id, u.user_id into v_org, v_user
      from public.organizations g
      join public.org_users u on u.organization_id = g.id and u.status = 'active'
      join public.roles r on r.id = u.role_id and r.slug = 'org_owner'
     where lower(coalesce(g.business_domain, '')) ~ c.pat
     order by g.created_at limit 1;
    if v_org is null then v_out := v_out || ' ||| ' || c.label || ': no business with an active owner found'; continue; end if;
    select id into v_loc from public.locations where organization_id = v_org order by created_at limit 1;
    v_o := gen_random_uuid();
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_user::text, true);
    begin
      insert into public.orders (id, organization_id, location_id, channel, status, subtotal, total, order_no, display_no)
      values (v_o, v_org, v_loc, 'pickup', 'in_billing', 40, 40, 999951, 'ZZ-CHECK-51');
      perform public.pos_split_pay(jsonb_build_object('order_id', v_o, 'idempotency_key', 'zz-check-51', 'payments', jsonb_build_array(
        jsonb_build_object('method', 'cash', 'amount', 20), jsonb_build_object('method', 'upi', 'amount', 20, 'reference', 'TESTREF51'))));
      select status::text || ', payments=' || (select count(*) from public.payments where order_id = v_o) into v_res from public.orders where id = v_o;
      raise exception 'ZZ_WORKED %', v_res;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      v_out := v_out || ' ||| ' || c.label || ' split pay: ' || v_state || ' ' || v_msg;
    end;
  end loop;

  foreach v_fn in array array['rst_bill_pay', 'rst_bill_split', 'rst_bill_refund'] loop
    begin
      execute format('select public.%I($1)', v_fn) using jsonb_build_object('order_id', gen_random_uuid(), 'idempotency_key', 'zz-check-51', 'method', 'cash', 'amount', 1);
      raise exception 'ZZ_RETURNED';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      v_out := v_out || ' ||| ' || v_fn || ': ' || v_state || ' ' || left(v_msg, 90);
    end;
  end loop;

  raise exception 'RESULT %', v_out;
end $$;
