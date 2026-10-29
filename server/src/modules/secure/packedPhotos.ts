// Secret-bearing: the photo of a packed order (founder, 29 Oct 2026). The app asks for a signed upload slot, sends the photo to it, then
// records the path (pos_packed_photo_save). The slot is made with the service role, but only under the CALLER's business and order folder,
// and only for an order the database (run as the caller) says is theirs; the database checks the path again on save.
// Bucket: order-photos (private; opened through a 10-minute signed link).
import { db, mapDbError, userClient } from '../../db.ts';
import { viaProxy } from '../../config.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { PHOTO_EXT, PHOTO_MAX_BYTES, PhotoAsk, PhotoLink } from '../../schemas/packed.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'order-photos';

export async function photoSlot({ request, args }: SecureCtx) {
  const b = parse(PhotoAsk, args);
  const { data, error } = await userClient(request).rpc('pos_packed_photo_org', { p: { order_id: b.order_id } });
  if (error) mapDbError(error);
  const d = data as { organization_id?: string; order_id?: string } | null;
  if (!d?.organization_id || !d.order_id) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const path = `${d.organization_id}/orders/${d.order_id}/${crypto.randomUUID()}.${PHOTO_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: viaProxy(signed.data.signedUrl), max_bytes: PHOTO_MAX_BYTES };
}

export async function photoLink({ request, args }: SecureCtx) {
  const b = parse(PhotoLink, args);
  const { data, error } = await userClient(request).rpc('pos_packed_photo_path', { p: b });
  if (error) mapDbError(error);
  const path = (data as { path?: string } | null)?.path;
  if (!path) throw new HttpError(404, 'This order has no packed photo.', undefined, 'not_found');
  const signed = await db().storage.from(BUCKET).createSignedUrl(path, 600);
  if (signed.error || !signed.data) throw new HttpError(502, 'The photo is not available right now.');
  return { url: viaProxy(signed.data.signedUrl), expires_in: 600 };
}
