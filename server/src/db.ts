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

/** A client that acts AS the caller (their own access token on the anon key), so auth.uid() and RLS apply. */
export function userClient(request: Request): SupabaseClient {
  const url = supabaseUrl(), anon = anonKey();
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '').trim();
  if (!url || !anon) throw new HttpError(503, 'The database is not connected yet.', undefined, 'database_unavailable');
  if (!token) throw new HttpError(401, 'Sign in to continue.');
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
}

// Database functions raise errors like "OL_STALE: this order was already changed on another phone".
const STATUS: Record<string, number> = {
  OL_BAD_REQUEST: 400, OL_BAD_QTY: 400, OL_EMPTY: 400, OL_NOT_FOUND: 404, OL_NOT_ONE_LOCAL: 404,
  OL_NOT_ACCEPTING: 409, OL_ITEM_UNAVAILABLE: 409, OL_STALE: 409, OL_WRONG_STATE: 409, OL_EXPIRED: 409,
  OL_NOT_DELIVERABLE: 409, OL_PICKED_UP: 409, OL_TAKEN: 409, OL_GONE: 410,
  OL_BAD_STEP: 409, OL_TOO_FAR: 422, OL_PICKUP_MISMATCH: 422, OL_CASH_MISMATCH: 422, OL_IDEMPOTENCY: 422, OL_IDEMPOTENCY_MISMATCH: 422, OL_IN_PROGRESS: 409,
};
const CODE: Record<string, string> = {
  OL_NOT_DELIVERABLE: 'order_not_deliverable', OL_PICKED_UP: 'already_picked_up', OL_EXPIRED: 'offer_expired', OL_TAKEN: 'already_taken',
  OL_STALE: 'version_conflict', OL_GONE: 'offer_withdrawn', OL_NOT_FOUND: 'not_found', OL_WRONG_STATE: 'wrong_state',
  OL_BAD_STEP: 'invalid_transition', OL_TOO_FAR: 'too_far', OL_PICKUP_MISMATCH: 'pickup_mismatch', OL_CASH_MISMATCH: 'cash_mismatch', OL_IDEMPOTENCY: 'idempotency_mismatch', OL_IDEMPOTENCY_MISMATCH: 'idempotency_mismatch', OL_IN_PROGRESS: 'in_progress',
};

export function mapDbError(error: { message?: string; code?: string } | null): never {
  const message = error?.message ?? 'Database error';
  const match = message.match(/^(OL_[A-Z_]+):\s*(.*)$/);
  if (match) throw new HttpError(STATUS[match[1]] ?? 400, match[2], undefined, CODE[match[1]]);
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
