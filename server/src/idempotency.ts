import { HttpError } from './http.ts';

export const KEY_SHAPE = /^[\w:.-]{8,200}$/;

/** The Idempotency-Key header, or null when absent. The database functions store and replay by this key. */
export function idempotencyKey(request: Request): string | null {
  const key = request.headers.get('idempotency-key')?.trim();
  if (!key) return null;
  if (!KEY_SHAPE.test(key)) throw new HttpError(400, 'Idempotency-Key is not valid.', undefined, 'invalid_request');
  return key;
}
