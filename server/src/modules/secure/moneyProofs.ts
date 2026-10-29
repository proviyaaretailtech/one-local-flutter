// Secret-bearing: the proof photo on a store money entry (founder's Money in sketch, 28 Oct 2026). The app asks for a signed upload slot, sends
// the bytes to it, then names the path when it saves the entry. The slot is made with the service role, but only under the CALLER's business
// folder, and only when the database (run as the caller) says they may record money; the database checks the path again on save.
// Bucket: money-proofs (private; opened through a 5-minute signed link).
import { db, mapDbError, userClient } from '../../db.ts';
import { viaProxy } from '../../config.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { PROOF_EXT, PROOF_MAX_BYTES, ProofAsk, ProofLink } from '../../schemas/money.ts';
import type { SecureCtx } from './index.ts';

const BUCKET = 'money-proofs';

export async function proofSlot({ request, args }: SecureCtx) {
  const b = parse(ProofAsk, args);
  const { data, error } = await userClient(request).rpc('smoney_proof_org', { p: {} });
  if (error) mapDbError(error);
  const org = (data as { organization_id?: string } | null)?.organization_id;
  if (!org) throw new HttpError(403, 'Sign in to a business to continue.', undefined, 'forbidden');
  const path = `${org}/proofs/${crypto.randomUUID()}.${PROOF_EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[secure] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: viaProxy(signed.data.signedUrl), max_bytes: PROOF_MAX_BYTES };
}

export async function proofLink({ request, args }: SecureCtx) {
  const b = parse(ProofLink, args);
  const { data, error } = await userClient(request).rpc('smoney_proof_path', { p: b });
  if (error) mapDbError(error);
  const path = (data as { path?: string } | null)?.path;
  if (!path) throw new HttpError(404, 'No proof photo on this entry.', undefined, 'not_found');
  const signed = await db().storage.from(BUCKET).createSignedUrl(path, 300);
  if (signed.error || !signed.data) throw new HttpError(502, 'The photo is not available right now.');
  return { url: viaProxy(signed.data.signedUrl), content_type: path.endsWith('.pdf') ? 'application/pdf' : path.endsWith('.png') ? 'image/png' : 'image/jpeg', expires_in: 300 };
}
