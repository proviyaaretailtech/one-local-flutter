-- 0661 Two gaps found when the guest page met the customer server (2026-11-05, local dev DB):
--   1. a table QR's answer did not name the restaurant's store link, so a table order could not be sent through the customer server
--      (it needs the store link) and the live order feed could not start on a table QR;
--   2. a declined or cancelled web order did not say why.
begin;
do $$
declare v_src text := pg_get_functiondef('public.guest_qr_open'::regproc);
  v_old text := $r$'business', jsonb_build_object('name', v_org.name)$r$;
begin
  if v_src like '%''store_link'', (select store_slug%' then return; end if;
  if position(v_old in v_src) = 0 then raise exception '0661: guest_qr_open has changed shape; patch it by hand'; end if;
  execute replace(v_src, v_old, $r$'business', jsonb_build_object('name', v_org.name,
      'store_link', (select store_slug from public.org_listing_profiles where organization_id = v_org.id))$r$);
end $$;

do $$
declare v_src text := pg_get_functiondef('public.ol__web_order_json'::regproc);
  v_old text := $r$'order_id', x.id, 'display_no', o.display_no, 'status', x.status, 'stage', v_stage, 'stage_label', v_label,$r$;
begin
  if v_src like '%''decline_reason''%' then return; end if;
  if position(v_old in v_src) = 0 then raise exception '0661: ol__web_order_json has changed shape; patch it by hand'; end if;
  execute replace(v_src, v_old, v_old || $r$
    'decline_reason', case when v_stage in ('declined', 'cancelled') then coalesce(nullif(btrim(x.cancel_reason), ''),
      case x.cancel_code when 'auto_cancelled' then 'The restaurant did not answer in time.' when 'rejected_by_partner' then 'The restaurant could not take this order.' end) end,$r$);
end $$;

insert into public.schema_migrations_ledger (filename, note)
values ('partner/0661_web_order_gaps.sql', 'Table QR answer names the store link; web order status says why it was declined (local dev DB 2026-11-05)') on conflict do nothing;
commit;
