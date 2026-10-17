// Secure: storefront pictures (banners, category icons, product pictures, ad images). The app never holds a storage key: it asks for a signed
// upload slot, sends the bytes to it, then confirms. Slot and links are made here with the service role, but only for the business the DATABASE
// says the verified caller may manage (sf_image_org: an active owner / admin / manager / marketing role). The file is recorded by the
// service-only registrar sf_image_register after the storage service confirms it exists and is small enough. Bucket: partner-listing-media.
import { db, rpc } from '../../db.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { IMAGE_EXT, IMAGE_MAX_BYTES, ImageAsk, ImageAttach } from '../../schemas/storefront.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'partner-listing-media';

export async function imageSlot({ userId, args }: SecureCtx) {
  const b = parse(ImageAsk, args);
  const org = await rpc<string>('sf_image_org', { p_user_id: userId });
  const path = `${org}/sf-${b.kind}/${crypto.randomUUID()}.${IMAGE_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: IMAGE_MAX_BYTES };
}

export async function imageAttach({ userId, args }: SecureCtx) {
  const b = parse(ImageAttach, args);
  const org = await rpc<string>('sf_image_org', { p_user_id: userId });
  if (!b.path.startsWith(`${org}/sf-${b.kind}/`)) throw new HttpError(400, 'That file does not belong to your business.', undefined, 'validation');
  const info = await db().storage.from(BUCKET).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1 || size > IMAGE_MAX_BYTES) {
    await db().storage.from(BUCKET).remove([b.path]);
    throw new HttpError(422, size < 1 ? 'That file is empty.' : 'Each image can be up to 5 MB.', undefined, 'validation');
  }
  const res = await rpc<Record<string, unknown>>('sf_image_register', { p_user_id: userId, p_kind: b.kind, p_path: b.path, p_mime: b.content_type, p_size: size });
  return withStorefrontLinks(res);
}

/** Replaces every `<name>_path` storage path in a storefront answer with a short-lived `<name>_url` link (the app never sees a storage path). */
export async function withStorefrontLinks<T>(result: T): Promise<T> {
  const holders: { o: Record<string, unknown>; key: string; path: string }[] = [];
  const walk = (v: unknown, depth: number) => {
    if (depth > 12 || v === null || typeof v !== 'object') return;
    if (Array.isArray(v)) { for (const x of v) walk(x, depth + 1); return; }
    const o = v as Record<string, unknown>;
    for (const key of Object.keys(o)) {
      if (key.endsWith('_path') && o[key] === null) { delete o[key]; o[key.replace(/_path$/, '_url')] = null; }
      else if (key.endsWith('_path') && typeof o[key] === 'string') holders.push({ o, key, path: o[key] as string });
      else walk(o[key], depth + 1);
    }
  };
  walk(result, 0);
  if (!holders.length) return result;
  const paths = [...new Set(holders.map(h => h.path))];
  const signed = await db().storage.from(BUCKET).createSignedUrls(paths, 600);
  const byPath = new Map<string, string>();
  for (const s of signed.data ?? []) if (s.path && s.signedUrl && !s.error) byPath.set(s.path, s.signedUrl);
  for (const h of holders) { delete h.o[h.key]; h.o[h.key.replace(/_path$/, '_url')] = byPath.get(h.path) ?? null; }
  return result;
}
