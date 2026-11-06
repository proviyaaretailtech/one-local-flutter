-- 0670 (6 Nov 2026): a store's stock count is finished once its correction is approved. STORE ONLY: a restaurant or service business is skipped.
-- The count stayed in "review" for ever, so Count stock kept saying "Finished · fix the difference" after the stock had been corrected.
-- When the adjustment made from a count is posted, the count is marked completed. It never stops an approval: anything going wrong here leaves the count as it was.
-- Counts already corrected are marked below. Nothing is deleted. Safe to run again.
create or replace function public.inv_documents__store_count_done() returns trigger
  language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
begin
  if new.doc_type <> 'adjustment' or new.status <> 'posted' or old.status = 'posted' or new.linked_document_id is null then return null; end if;
  if lower(coalesce((select business_domain from public.organizations where id = new.organization_id), '')) ~ 'restaurant|food|service' then return null; end if;
  begin
    update public.inventory_documents
       set status = 'completed', posted_at = coalesce(posted_at, now()), posted_by = coalesce(posted_by, new.posted_by), version = version + 1, updated_at = now()
     where id = new.linked_document_id and doc_type = 'audit' and status = 'review';
  exception when others then null;
  end;
  return null;
end $f$;
revoke all on function public.inv_documents__store_count_done() from public, anon, authenticated;

drop trigger if exists inv_documents_store_count_done on public.inventory_documents;
create trigger inv_documents_store_count_done after update of status on public.inventory_documents
  for each row execute function public.inv_documents__store_count_done();

-- the counts already corrected
update public.inventory_documents a
   set status = 'completed', posted_at = coalesce(a.posted_at, j.posted_at, now()), posted_by = coalesce(a.posted_by, j.posted_by), version = a.version + 1, updated_at = now()
  from public.inventory_documents j
  join public.organizations g on g.id = j.organization_id
 where j.linked_document_id = a.id and j.doc_type = 'adjustment' and j.status = 'posted'
   and a.doc_type = 'audit' and a.status = 'review'
   and lower(coalesce(g.business_domain, '')) !~ 'restaurant|food|service';
