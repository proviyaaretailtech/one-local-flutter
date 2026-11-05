-- HOSTED, READ ONLY (5 Nov 2026): changes nothing. Exports the store Money functions, which exist only on hosted, and the functions the
-- store POS close-out work (Close day as the one close, carry-forward, reopen) has to build on, plus the columns of their tables.
-- Run it in the SQL editor, then use Export > Download CSV on the result and send the file (the rows are long, a screen copy cuts them).
select 'function' as kind, p.proname as name, pg_get_function_identity_arguments(p.oid) as args,
       md5(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')) as fingerprint, pg_get_functiondef(p.oid) as definition
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and (p.proname ~ '^smoney' or p.proname ~ '^pos_day' or p.proname ~ '^inv_doc'
        or p.proname in ('pos_checkout', 'pos_checkout_pay', 'pos_split_pay', 'pos_payment_confirm', 'pos_shift_close', 'pos_shift_open'))
union all
select 'table', c.table_name, null, null,
       string_agg(c.column_name || ' ' || c.data_type || case when c.is_nullable = 'NO' then ' not null' else '' end, ', ' order by c.ordinal_position)
  from information_schema.columns c
 where c.table_schema = 'public'
   and (c.table_name ~ '^(smoney|store_money|money_cash|pos_business_days|pos_day)' or c.table_name in ('pos_refunds', 'pos_shifts'))
 group by c.table_name
 order by 1, 2;
