// Secret-bearing: private file storage. The app never holds a storage key: it asks for a signed upload slot, sends the bytes to it,
// then confirms. The slot and every signed link are made here with the service role, but only for a path the DATABASE says belongs
// to the verified caller (their own application folder / their own business folder). Buckets: partner-documents, partner-listing-media.
import { db, rpc } from '../../db.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { Attach, EXT, KINDS, MAX_BYTES, PreviewAsk, UploadAsk } from '../../schemas/onboarding.ts';
import { IMAGE_EXT, IMAGE_KINDS, IMAGE_MAX_BYTES, ImageAsk, ImageAttach } from '../../schemas/setup.ts';
import type { SecureCtx } from './index.ts';

const DOCS = 'partner-documents';
const IMAGES = 'partner-listing-media';

// ---------- onboarding documents ----------

async function applicationId(userId: string): Promise<string> {
  const g = await rpc<{ exists?: boolean; application?: { id: string; status: string } }>('partner_app_get', { p_user_id: userId });
  if (!g.exists || !g.application) throw new HttpError(404, 'Start your application first.', undefined, 'not_found');
  if (g.application.status !== 'draft') throw new HttpError(409, 'Your application has already been submitted.', undefined, 'wrong_state');
  return g.application.id;
}

export async function documentSlot({ userId, args }: SecureCtx) {
  const b = parse(UploadAsk, args);
  const path = `${await applicationId(userId)}/${b.kind}/${crypto.randomUUID()}.${EXT[b.content_type]}`;
  const signed = await db().storage.from(DOCS).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: MAX_BYTES };
}

export async function documentAttach({ userId, args }: SecureCtx) {
  const b = parse(Attach, args);
  const appId = await applicationId(userId);
  if (!b.path.startsWith(`${appId}/${b.kind}/`)) throw new HttpError(400, 'That file does not belong to your application.', undefined, 'validation');
  const info = await db().storage.from(DOCS).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1) { await db().storage.from(DOCS).remove([b.path]); throw new HttpError(422, 'That file is empty.', undefined, 'validation'); }
  if (size > MAX_BYTES) { await db().storage.from(DOCS).remove([b.path]); throw new HttpError(422, 'Each file can be up to 5 MB.', undefined, 'validation'); }
  const res = await rpc<Record<string, unknown>>('partner_app_attach_document', {
    p_user_id: userId, p_kind: b.kind, p_path: b.path, p_name: b.file_name, p_mime: b.content_type, p_size: size });
  const replaced = res.replaced_path as string | null | undefined;
  if (replaced) await db().storage.from(DOCS).remove([replaced]);       // the old copy is not kept
  delete res.replaced_path;
  return res;
}

export async function documentPreview({ userId, args }: SecureCtx) {
  const b = parse(PreviewAsk, args);
  if (!(KINDS as readonly string[]).includes(b.kind)) throw new HttpError(400, 'Unknown document type.', undefined, 'validation');
  const path = await rpc<string>('partner_app_document_path', { p_user_id: userId, p_kind: b.kind });
  const signed = await db().storage.from(DOCS).createSignedUrl(path, 300);
  if (signed.error || !signed.data) throw new HttpError(502, 'The preview is not available right now.');
  return { url: signed.data.signedUrl, expires_in: 300 };
}

// ---------- setup listing images ----------

type Setup = Record<string, unknown> & { listing?: Record<string, unknown> };

/** Replaces the storage paths in a setup state with short-lived links (the app never sees a storage path). Used after any setup call. */
export async function withImageLinks<T>(s: T): Promise<T> {
  const l = (s as Setup | null)?.listing;
  if (!l || typeof l !== 'object') return s;
  for (const kind of IMAGE_KINDS) {
    const path = l[`${kind}_path`] as string | null | undefined;
    delete l[`${kind}_path`];
    l[`${kind}_url`] = null;
    if (path) {
      const signed = await db().storage.from(IMAGES).createSignedUrl(path, 600);
      l[`${kind}_url`] = signed.error ? null : signed.data?.signedUrl ?? null;
    }
  }
  return s;
}

async function organizationId(userId: string): Promise<string> {
  const s = await rpc<{ organization?: { id?: string } }>('partner_setup_get', { p_user_id: userId });
  const id = s.organization?.id;
  if (!id) throw new HttpError(404, 'Your business is not approved yet.', undefined, 'not_found');
  return id;
}

export async function imageSlot({ userId, args }: SecureCtx) {
  const b = parse(ImageAsk, args);
  const path = `${await organizationId(userId)}/${b.kind}/${crypto.randomUUID()}.${IMAGE_EXT[b.content_type]}`;
  const signed = await db().storage.from(IMAGES).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: IMAGE_MAX_BYTES };
}

export async function imageAttach({ userId, args }: SecureCtx) {
  const b = parse(ImageAttach, args);
  const org = await organizationId(userId);
  if (!b.path.startsWith(`${org}/${b.kind}/`)) throw new HttpError(400, 'That file does not belong to your business.', undefined, 'validation');
  const info = await db().storage.from(IMAGES).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1 || size > IMAGE_MAX_BYTES) {
    await db().storage.from(IMAGES).remove([b.path]);
    throw new HttpError(422, size < 1 ? 'That file is empty.' : 'Each image can be up to 5 MB.', undefined, 'validation');
  }
  const res = await rpc<Setup>('partner_setup_attach_listing_image', { p_user_id: userId, p_kind: b.kind, p_path: b.path, p_mime: b.content_type, p_size: size });
  const replaced = res.replaced_path as string | null | undefined;
  if (replaced) await db().storage.from(IMAGES).remove([replaced]);
  delete res.replaced_path;
  return withImageLinks(res);
}

