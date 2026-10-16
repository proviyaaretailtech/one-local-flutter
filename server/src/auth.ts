// Who is calling: the Supabase access token the app sends as `Authorization: Bearer <token>`, verified by Supabase Auth.
import { db } from './db.ts';
import { sha256 } from './http.ts';

const cache = new Map<string, { id: string | null; until: number }>();

/** The user id the token belongs to, or null (missing, malformed, expired or forged). Results are cached briefly. */
export async function signedInUserId(request: Request): Promise<string | null> {
  const header = request.headers.get('authorization');
  if (!header?.startsWith('Bearer ')) return null;
  const token = header.slice(7).trim();
  if (token.length < 20 || token.length > 4096) return null;
  const key = await sha256(token);
  const hit = cache.get(key);
  if (hit && hit.until > Date.now()) return hit.id;
  let id: string | null = null;
  try {
    const { data, error } = await db().auth.getUser(token);
    if (!error) id = data.user?.id ?? null;
  } catch { /* an unreachable auth service counts as "not signed in" for this call only */ }
  if (cache.size > 5000) cache.clear();
  cache.set(key, { id, until: Date.now() + (id ? 60_000 : 10_000) });
  return id;
}
