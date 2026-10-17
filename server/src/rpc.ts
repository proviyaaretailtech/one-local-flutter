// The one generic endpoint: POST /rpc/<alias> (body = JSON args) and POST /rpc (a small batch).
//   1. the alias must be in the manifest (anything else is 404);
//   2. the caller's Supabase access token is verified (public key only);
//   3. the body is checked against the entry's schema;
//   4. a `db` entry calls the database function AS THE CALLER, so row-level security and the function's own checks decide. The
//      service-role key is never touched on this path. A `secure` entry runs its handler with the verified user id.
// Errors are always { detail, code? }; database errors map from their OL_/POS_/INV_/GRN_/SVC_ prefix (see db.ts).
import { signedInUserId } from './auth.ts';
import { mapDbError, userClient } from './db.ts';
import { HttpError, json, limit, readBody, readText } from './http.ts';
import { idempotencyKey } from './idempotency.ts';
import { lookup, type Entry, type Rate } from './rpc-manifest.ts';
import { parse } from './validate.ts';

const RATE: Record<Rate, number> = { read: 600, write: 180, money: 90, secure: 60 };
const BATCH_MAX = 10;
const FN_SHAPE = /^[a-z][a-z0-9_]{1,63}$/;

async function run(request: Request, userId: string, alias: string, body: Record<string, unknown>, headerKey: string | null): Promise<unknown> {
  const entry: Entry | undefined = FN_SHAPE.test(alias) ? lookup(alias) : undefined;
  if (!entry) throw new HttpError(404, 'Not found');
  limit(userId, `rpc:${entry.rate}`, RATE[entry.rate], 60_000);
  const args = entry.args === 'passthrough' ? body : parse(entry.args, body);
  if (entry.kind === 'local') return entry.run();
  if (entry.kind === 'secure') return entry.handler({ request, userId, args: args as Record<string, unknown> });
  const dbArgs = entry.map ? entry.map(args) : { p: args };
  if (entry.idem && headerKey && dbArgs.p && typeof dbArgs.p === 'object' && !('idempotency_key' in (dbArgs.p as object))) (dbArgs.p as Record<string, unknown>).idempotency_key = headerKey;
  const { data, error } = await userClient(request).rpc(entry.fn, dbArgs);
  if (error) mapDbError(error);
  return entry.post ? entry.post(data) : data;
}

async function caller(request: Request): Promise<string> {
  const id = await signedInUserId(request);
  if (!id) throw new HttpError(401, 'Sign in to continue.');
  return id;
}

/** POST /rpc/:name */
export async function rpcOne(request: Request, params: Record<string, string>): Promise<Response> {
  const entry = FN_SHAPE.test(params.name ?? '') ? lookup(params.name) : undefined;
  if (!entry) throw new HttpError(404, 'Not found');              // before the token is even looked at: nothing about the allowlist leaks via 401 vs 404
  const userId = await caller(request);
  const body = await readBody(request, entry.maxBytes);
  return json(await run(request, userId, params.name, body, idempotencyKey(request)) ?? null);
}

/** POST /rpc  { calls: [{ fn, args }] } — up to 10 calls in order; each answers { ok, data } or { ok:false, status, detail, code }. Not one transaction. */
export async function rpcBatch(request: Request): Promise<Response> {
  const userId = await caller(request);
  let body: { calls?: { fn?: unknown; args?: unknown }[] };
  try { body = JSON.parse((await readText(request, 256 * 1024)) || '{}'); } catch { throw new HttpError(400, 'Request body must be a JSON object'); }
  const calls = body?.calls;
  if (!Array.isArray(calls) || calls.length < 1 || calls.length > BATCH_MAX) throw new HttpError(400, `Send between 1 and ${BATCH_MAX} calls.`, undefined, 'validation');
  const out: unknown[] = [];
  for (const c of calls) {
    try {
      const args = c.args && typeof c.args === 'object' && !Array.isArray(c.args) ? c.args as Record<string, unknown> : {};
      out.push({ ok: true, data: (await run(request, userId, String(c.fn ?? ''), args, null)) ?? null });
    } catch (e) {
      if (e instanceof HttpError) out.push({ ok: false, status: e.status, detail: e.detail, ...(e.code ? { code: e.code } : {}) });
      else { console.error('[rpc]', e instanceof Error ? e.message : e); out.push({ ok: false, status: 500, detail: 'Something went wrong. Please try again.' }); }
    }
  }
  return json({ results: out });
}
