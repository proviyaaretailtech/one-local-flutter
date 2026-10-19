// Database access (Supabase). The service-role client is for the few things only the server may do (storage slots, staff lookup,
// calling functions on behalf of an already-verified user id). userClient() runs as the caller so row-level security applies.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { anonKey, serviceKey, supabaseUrl } from './config.ts';
import { HttpError } from './http.ts';

let client: SupabaseClient | null = null;
let clientFor = '';

export function db(): SupabaseClient {
  const url = supabaseUrl(), key = serviceKey();
  if (!url || !key) throw new HttpError(503, 'The database is not connected yet.', undefined, 'database_unavailable');
  if (client && clientFor === `${url}|${key}`) return client;
  client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  clientFor = `${url}|${key}`;
  return client;
}

/** A client on the public (anon/publishable) key only: used to verify a token without any privileged key. */
export function anonClient(): SupabaseClient | null {
  const url = supabaseUrl(), anon = anonKey();
  if (!url || !anon) return null;
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
}

/** A client that acts AS the caller (their own access token on the anon key), so auth.uid() and RLS apply. */
export function userClient(request: Request): SupabaseClient {
  const url = supabaseUrl(), anon = anonKey();
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '').trim();
  if (!url || !anon) throw new HttpError(503, 'The database is not connected yet.', undefined, 'database_unavailable');
  if (!token) throw new HttpError(401, 'Sign in to continue.');
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
}

// Database functions raise errors like "OL_STALE: this order was already changed on another phone": a family prefix (OL, POS, INV,
// GRN, SVC, PS, TBL, PUR), a reason, then the sentence the app shows. The reason decides the HTTP status; an unknown reason is a plain 400.
const FAMILIES = ['OL', 'POS', 'INV', 'GRN', 'SVC', 'PS', 'TBL', 'PUR'];
const STATUS: Record<string, number> = {
  BAD_REQUEST: 400, BAD_QTY: 400, EMPTY: 400, BAD_TABLE: 400, FORBIDDEN: 403, NOT_FOUND: 404, NOT_ONE_LOCAL: 404,
  NOT_ACCEPTING: 409, ITEM_UNAVAILABLE: 409, STALE: 409, WRONG_STATE: 409, EXPIRED: 409, NOT_DELIVERABLE: 409, PICKED_UP: 409, TAKEN: 409,
  BAD_STEP: 409, IN_PROGRESS: 409, HAS_PAYMENTS: 409, NOT_PAID_IN_FULL: 409, DUPLICATE: 409, NOT_APPROVED: 409, FROZEN: 409,
  STATUS_AUTHORITY: 409, ORDER_FROZEN: 409, GONE: 410,
  TOO_FAR: 422, PICKUP_MISMATCH: 422, CASH_MISMATCH: 422, IDEMPOTENCY: 422, IDEMPOTENCY_MISMATCH: 422, UNDERPAID: 422, OVERPAY: 422,
  SHORT: 409, ALLOCATION: 409, CAPACITY: 422, STORAGE: 422, TENANT: 403,                                   // inventory (section H)
  CONFLICT: 409, SCOPE: 403,                                                                                     // purchase suggestions (section J), tables (H)
  MERGED: 409, NOT_OCCUPIED: 409, BUSY: 409, CLOSED: 422,                                                                   // tables and floor (section H)
  COUPON_UNKNOWN: 422, COUPON_MIN: 422, COUPON_LIMIT: 422, COUPON_CUSTOMER: 422, COUPON_ZERO: 422, OVER_REFUND: 422, OVER_RETURN: 422, PROVIDER_OFF: 503, TAX_REQUIRED: 422, UNRESOLVED: 422, UNAVAILABLE: 503,
  SHIFT_OPEN: 409, NO_SHIFT: 409, PAYMENT_PENDING: 409, NOT_ENOUGH_CASH: 422, REASON_REQUIRED: 422, RETURN_WINDOW: 422,       // store shift, payment pending, refunds (0500-0502)
};
const CODE: Record<string, string> = {
  NOT_DELIVERABLE: 'order_not_deliverable', PICKED_UP: 'already_picked_up', EXPIRED: 'offer_expired', TAKEN: 'already_taken',
  STALE: 'version_conflict', GONE: 'offer_withdrawn', BAD_STEP: 'invalid_transition', BAD_QTY: 'bad_quantity', EMPTY: 'empty_cart',
  IDEMPOTENCY: 'idempotency_mismatch', IDEMPOTENCY_MISMATCH: 'idempotency_mismatch', STATUS_AUTHORITY: 'wrong_state', ORDER_FROZEN: 'wrong_state', FROZEN: 'wrong_state',
  ITEM_UNAVAILABLE: 'item_unavailable', SCOPE: 'store_scope', COUPON_MIN: 'coupon_minimum', PROVIDER_OFF: 'provider_not_configured',
};
const sentence = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? '' : '.') : 'Request refused.');

export function mapDbError(error: { message?: string; code?: string } | null): never {
  const message = error?.message ?? 'Database error';
  const match = message.match(/^([A-Z]+)_([A-Z_]+):\s*(.*)$/);
  if (match && FAMILIES.includes(match[1])) {
    const reason = match[2];
    throw new HttpError(STATUS[reason] ?? 400, (match[1] === 'OL' ? match[3] : sentence(match[3])), undefined, CODE[reason] ?? reason.toLowerCase());
  }
  // Row-level security and missing grants answer 42501: the caller may not do this.
  if (error?.code === '42501' || /permission denied|row-level security/i.test(message)) throw new HttpError(403, 'You do not have permission to do that.', undefined, 'forbidden');
  // Only the code and the message: `details` and `hint` can quote the row that was refused (names, phones, addresses).
  console.error('[db]', { code: error?.code, message: message.slice(0, 200) });
  throw new HttpError(500, 'Something went wrong. Please try again.');
}

export const fromDbError = mapDbError;

export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db().rpc(fn, args);
  if (error) fromDbError(error);
  return data as T;
}
