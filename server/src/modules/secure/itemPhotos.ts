// Secure: catalogue item photos. The app never holds a storage key: it asks for a signed upload slot for one item, sends the bytes to it,
// then confirms. The slot is only made when the DATABASE says the verified caller may add or change that item's business catalogue
// (menu:create or menu:update). The file is recorded by the service-only cat_item_photo_attach after the storage service confirms it
// exists and is small enough; the photo it replaced is deleted. Bucket: item-images (public, so the link on the item never expires).
import { db, rpc } from '../../db.ts';
import { viaProxy } from '../../config.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { IMAGE_MAX_BYTES, PHOTO_EXT, PhotoAsk, PhotoAttach, PhotoRemove } from '../../schemas/catalogue.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'item-images';
type Done = { id: string; image_url: string | null; replaced_url?: string | null };

/** The item's business, when the caller may change its catalogue; otherwise the refusal the screens show. */
async function itemOrg(userId: string, itemId: string): Promise<string> {
  const { data, error } = await db().from('menu_items').select('organization_id').eq('id', itemId).maybeSingle();
  if (error) { console.error('[secure] item lookup failed', error.message); throw new HttpError(500, 'Something went wrong. Please try again.'); }
  const org = (data as { organization_id?: string } | null)?.organization_id;
  if (!org) throw new HttpError(404, 'That item no longer exists.', undefined, 'not_found');
  for (const action of ['update', 'create']) {
    if (await rpc<boolean>('user_has_permission', { p_user: userId, p_org: org, p_resource: 'menu', p_action: action })) return org;
  }
  throw new HttpError(403, 'Your role cannot change catalogue items.', undefined, 'forbidden');
}

/** Deletes the file a replaced or removed photo pointed at, when it is one of ours. A failure only leaves an unused file. */
async function dropOld(url: string | null | undefined) {
  const at = url?.indexOf(`/${BUCKET}/`) ?? -1;
  if (!url || at < 0) return;
  const { error } = await db().storage.from(BUCKET).remove([decodeURIComponent(url.slice(at + BUCKET.length + 2))]);
  if (error) console.error('[secure] old item photo not removed', error.message);
}

export async function photoSlot({ userId, args }: SecureCtx) {
  const b = parse(PhotoAsk, args);
  const org = await itemOrg(userId, b.item_id);
  const path = `${org}/items/${b.item_id}/${crypto.randomUUID()}.${PHOTO_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: viaProxy(signed.data.signedUrl), max_bytes: IMAGE_MAX_BYTES };
}

export async function photoAttach({ userId, args }: SecureCtx) {
  const b = parse(PhotoAttach, args);
  const org = await itemOrg(userId, b.item_id);
  if (!b.path.startsWith(`${org}/items/${b.item_id}/`)) throw new HttpError(400, 'That file does not belong to this item.', undefined, 'validation');
  const info = await db().storage.from(BUCKET).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The photo has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1 || size > IMAGE_MAX_BYTES) {
    await db().storage.from(BUCKET).remove([b.path]);
    throw new HttpError(422, size < 1 ? 'That photo is empty.' : 'Each photo can be up to 5 MB.', undefined, 'validation');
  }
  const url = db().storage.from(BUCKET).getPublicUrl(b.path).data.publicUrl;
  const res = await rpc<Done>('cat_item_photo_attach', { p_user_id: userId, p_item_id: b.item_id, p_path: b.path, p_url: url, p_mime: b.content_type, p_size: size });
  await dropOld(res.replaced_url);
  return { id: res.id, image_url: res.image_url };
}

export async function photoRemove({ userId, args }: SecureCtx) {
  const b = parse(PhotoRemove, args);
  await itemOrg(userId, b.item_id);
  const res = await rpc<Done>('cat_item_photo_remove', { p_user_id: userId, p_item_id: b.item_id });
  await dropOld(res.replaced_url);
  return { id: res.id, image_url: null };
}
