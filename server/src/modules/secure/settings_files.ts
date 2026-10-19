// Secret-bearing: private file storage for Settings (store QR, documents, feedback screenshot). Same shape as the setup images: the app asks for
// a signed upload slot, sends the bytes to it, then confirms. The slot and the signed links are made here with the service role, but only for a
// path under the CALLER's own business folder, and the database (run as the caller) decides who may attach or open a file.
import { db, mapDbError, userClient } from '../../db.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { FILE_EXT, FILE_MAX_BYTES, FileAsk, FileAttach, FileLink } from '../../schemas/settings.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'store-files';

async function caller(request: Request): Promise<{ org: string; canEdit: boolean }> {
  const { data, error } = await userClient(request).rpc('pos_settings_get', { p: {} });
  if (error) mapDbError(error);
  const org = (data as { organization?: { id?: string } } | null)?.organization?.id;
  if (!org) throw new HttpError(403, 'Sign in to a business to continue.', undefined, 'forbidden');
  return { org, canEdit: (data as { can_edit?: boolean }).can_edit === true };
}

export async function fileSlot({ request, args }: SecureCtx) {
  const b = parse(FileAsk, args);
  const { org, canEdit } = await caller(request);
  if (b.kind !== 'feedback' && !canEdit) throw new HttpError(403, 'Only the owner or a manager can change store files.', undefined, 'forbidden');
  const path = `${org}/${b.kind}/${crypto.randomUUID()}.${FILE_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: FILE_MAX_BYTES };
}

export async function fileAttach({ request, args }: SecureCtx) {
  const b = parse(FileAttach, args);
  const { org } = await caller(request);
  if (!b.path.startsWith(`${org}/${b.kind}/`) || b.path.includes('..')) throw new HttpError(400, 'That file does not belong to your business.', undefined, 'validation');
  const info = await db().storage.from(BUCKET).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1 || size > FILE_MAX_BYTES) {
    await db().storage.from(BUCKET).remove([b.path]);
    throw new HttpError(422, size < 1 ? 'That file is empty.' : 'Each file can be up to 5 MB.', undefined, 'validation');
  }
  const { data, error } = await userClient(request).rpc('pos_settings_attach_file', { p: { ...b, size } });
  if (error) { await db().storage.from(BUCKET).remove([b.path]); mapDbError(error); }
  const res = (data ?? {}) as Record<string, unknown>;
  const replaced = res.replaced_path as string | null | undefined;
  if (replaced) await db().storage.from(BUCKET).remove([replaced]);       // the old copy is not kept
  delete res.replaced_path;
  return res;
}

export async function fileLink({ request, args }: SecureCtx) {
  const b = parse(FileLink, args);
  const { data, error } = await userClient(request).rpc('pos_settings_file_path', { p: b });
  if (error) mapDbError(error);
  const path = (data as { path?: string } | null)?.path;
  if (!path) throw new HttpError(404, 'That file was not found.', undefined, 'not_found');
  const signed = await db().storage.from(BUCKET).createSignedUrl(path, 300);
  if (signed.error || !signed.data) throw new HttpError(502, 'The file is not available right now.');
  return { url: signed.data.signedUrl, content_type: path.endsWith('.pdf') ? 'application/pdf' : path.endsWith('.png') ? 'image/png' : 'image/jpeg', expires_in: 300 };
}

/** Result transform for the remove functions: delete the stored file the database just detached, and do not hand its path to the app. */
export async function dropRemovedFile<T>(result: T): Promise<T> {
  const r = result as { removed_path?: string | null } | null;
  const path = r?.removed_path;
  if (r && 'removed_path' in r) delete r.removed_path;
  if (path) await db().storage.from(BUCKET).remove([path]);
  return result;
}
