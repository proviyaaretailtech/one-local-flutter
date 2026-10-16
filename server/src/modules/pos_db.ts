// Calling the POS database functions AS the signed-in staff member (their token on the anon key), so auth.uid(), current_org_id(),
// role checks and row-level security all apply. Used by the catalogue (section G) and GRN modules. No business rule lives here:
// the database raises "PREFIX_CODE: sentence" and this file turns the prefix into an HTTP status.
import type { SupabaseClient } from '@supabase/supabase-js';
import { userClient } from '../db.ts';
import { HttpError } from '../http.ts';

export const asCaller = (request: Request): SupabaseClient => userClient(request);

const ERRORS: Record<string, { status: number; code: string }> = {
  POS_BAD_REQUEST: { status: 400, code: 'bad_request' }, POS_FORBIDDEN: { status: 403, code: 'forbidden' }, POS_NOT_FOUND: { status: 404, code: 'not_found' },
  POS_STALE: { status: 409, code: 'version_conflict' }, POS_DUPLICATE: { status: 409, code: 'duplicate' }, POS_TAX_REQUIRED: { status: 422, code: 'tax_required' },
  GRN_BAD_REQUEST: { status: 400, code: 'bad_request' }, GRN_BAD_QTY: { status: 400, code: 'bad_quantity' }, GRN_FORBIDDEN: { status: 403, code: 'forbidden' },
  GRN_NOT_FOUND: { status: 404, code: 'not_found' }, GRN_STALE: { status: 409, code: 'version_conflict' }, GRN_WRONG_STATE: { status: 409, code: 'wrong_state' },
  GRN_DUPLICATE: { status: 409, code: 'duplicate' }, GRN_UNRESOLVED: { status: 422, code: 'unresolved' }, GRN_NOT_APPROVED: { status: 409, code: 'not_approved' },
  GRN_UNAVAILABLE: { status: 503, code: 'unavailable' },
  // raised by section H's inv_document_act when approval posts the receipt
  INV_FORBIDDEN: { status: 403, code: 'forbidden' }, INV_NOT_FOUND: { status: 404, code: 'not_found' }, INV_BAD_REQUEST: { status: 400, code: 'bad_request' },
  INV_BAD_QTY: { status: 400, code: 'bad_quantity' }, INV_STALE: { status: 409, code: 'version_conflict' }, INV_WRONG_STATE: { status: 409, code: 'wrong_state' },
  INV_FROZEN: { status: 409, code: 'wrong_state' },
};

const sentence = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? '' : '.') : 'Request refused.');

export function dbFail(error: { message?: string; code?: string }): never {
  const message = String(error.message ?? '');
  const m = message.match(/^([A-Z]+_[A-Z_]+):\s*(.*)$/);
  if (m && ERRORS[m[1]]) throw new HttpError(ERRORS[m[1]].status, sentence(m[2]), undefined, ERRORS[m[1]].code);
  if (error.code === '42501' || /permission denied/i.test(message)) throw new HttpError(403, 'You do not have permission to do that.', undefined, 'forbidden');
  console.error('[pos-db]', { code: error.code, message: message.slice(0, 200) });
  throw new HttpError(500, 'Something went wrong. Please try again.');
}

export async function call<T = Record<string, any>>(client: SupabaseClient, fn: string, p: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(fn, { p });
  if (error) dbFail(error);
  return data as T;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function needUuid(id: string, what: string): string {
  if (!UUID.test(id)) throw new HttpError(404, `${what} not found.`, undefined, 'not_found');
  return id;
}
