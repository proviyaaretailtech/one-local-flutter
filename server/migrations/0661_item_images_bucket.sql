-- 0661 The dish photo bucket the server uses (src/modules/secure/itemPhotos.ts: item-images, public so a dish's link never expires).
-- It existed on hosted but was never in a migration, so the local dev DB had none and adding a dish photo failed there. Idempotent.
begin;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('item-images', 'item-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
insert into public.schema_migrations_ledger (filename, note)
values ('partner/0661_item_images_bucket.sql', 'item-images storage bucket (public, 5 MB, jpg/png/webp) in a migration (local dev DB 2026-11-05)') on conflict do nothing;
commit;
