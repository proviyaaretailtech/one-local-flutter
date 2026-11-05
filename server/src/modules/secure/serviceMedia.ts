// Secret-bearing: a service's banner photos and videos (founder, 4 Nov 2026: "photos should have option to add banner photos and videos").
// The app asks for a signed upload slot, sends the bytes to it, then keeps the public link in the service's listing. The slot is made with
// the service role, but only under the CALLER's business folder, and only when the database (run as the caller) says they manage services.
// Bucket: service-media (public: customers see the banners on the service).
import { db, mapDbError, userClient } from '../../db.ts';
import { viaProxy } from '../../config.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { IMAGE_MAX_BYTES, MEDIA_EXT, MediaAsk, VIDEO_MAX_BYTES } from '../../schemas/ads.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'service-media';

export async function mediaSlot({ request, args }: SecureCtx) {
  const b = parse(MediaAsk, args);
  const { data, error } = await userClient(request).rpc('svc_media_org', { p: {} });
  if (error) mapDbError(error);
  const org = (data as { organization_id?: string } | null)?.organization_id;
  if (!org) throw new HttpError(403, 'Sign in to a business to continue.', undefined, 'forbidden');
  const path = `${org}/services/${crypto.randomUUID()}.${MEDIA_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  const video = b.content_type.startsWith('video/');
  const url = db().storage.from(BUCKET).getPublicUrl(path).data.publicUrl;
  return { path, url: viaProxy(url), media_kind: video ? 'video' : 'image', upload_url: viaProxy(signed.data.signedUrl), max_bytes: video ? VIDEO_MAX_BYTES : IMAGE_MAX_BYTES };
}
