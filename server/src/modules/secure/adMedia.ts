// Secret-bearing: an ad's 9:16 photo or video (founder's Ads sketch, 29 Oct 2026). The app asks for a signed upload slot, sends the bytes
// to it, then names the path when it makes the ad. The slot is made with the service role, but only under the CALLER's business folder,
// and only when the database (run as the caller) says they may edit the shop page; the database checks the path again on save.
// Bucket: ad-media (private; opened through a 10-minute signed link).
import { db, mapDbError, userClient } from '../../db.ts';
import { viaProxy } from '../../config.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { IMAGE_MAX_BYTES, MEDIA_EXT, MediaAsk, MediaLink, VIDEO_MAX_BYTES } from '../../schemas/ads.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'ad-media';

export async function mediaSlot({ request, args }: SecureCtx) {
  const b = parse(MediaAsk, args);
  const { data, error } = await userClient(request).rpc('ads_media_org', { p: {} });
  if (error) mapDbError(error);
  const org = (data as { organization_id?: string } | null)?.organization_id;
  if (!org) throw new HttpError(403, 'Sign in to a business to continue.', undefined, 'forbidden');
  const path = `${org}/ads/${crypto.randomUUID()}.${MEDIA_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  const video = b.content_type.startsWith('video/');
  return { path, media_kind: video ? 'video' : 'image', upload_url: viaProxy(signed.data.signedUrl), max_bytes: video ? VIDEO_MAX_BYTES : IMAGE_MAX_BYTES };
}

export async function mediaLink({ request, args }: SecureCtx) {
  const b = parse(MediaLink, args);
  const { data, error } = await userClient(request).rpc('ads_media_path', { p: b });
  if (error) mapDbError(error);
  const d = data as { path?: string; media_kind?: string } | null;
  if (!d?.path) throw new HttpError(404, 'This ad has no photo or video.', undefined, 'not_found');
  const signed = await db().storage.from(BUCKET).createSignedUrl(d.path, 600);
  if (signed.error || !signed.data) throw new HttpError(502, 'The ad media is not available right now.');
  return { url: viaProxy(signed.data.signedUrl), media_kind: d.media_kind ?? 'image', expires_in: 600 };
}
