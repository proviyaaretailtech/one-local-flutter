-- ==========================================================================================================================
-- HOSTED: 0634 the customer on a restaurant bill (30 Oct 2026). One transaction: if it stops with an error, nothing has changed. Project ywylhzcxuoeilygzdonx.
-- The bill and the receipt also carry the customer's name, so Checkout and Send receipt show who the bill is for.
-- ==========================================================================================================================
begin;
-- 0634: the customer on a restaurant bill (founder, 30 Oct 2026: "customer icon for name & number before and post bill"). The bill and the
-- receipt (rst_bill_order_json, read by rst_bill_view and rst_receipt_view) carried the customer's number only; they now also carry the
-- name and the customer id, so Checkout and Send receipt can show who the bill is for. The customer is set with cust_save + cust_attach_order.
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.rst_bill_order_json(uuid)'::regprocedure);
  if position('''customer_name''' in v_def) > 0 then return; end if; -- already applied
  v_new := replace(v_def, '''customer_phone'', o.customer_phone,', '''customer_phone'', o.customer_phone, ''customer_name'', o.customer_name, ''customer_id'', o.pos_customer_id,');
  if v_new = v_def then raise exception '0634: rst_bill_order_json is not the expected definition'; end if;
  execute v_new;
end $$;

notify pgrst, 'reload schema';
commit;
