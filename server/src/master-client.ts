// The one way this server talks to the Master server (the control plane). Today it only answers health's question,
// "does Master accept our key?"; calls that carry work go through masterFetch when they are added.
// Mirrors One Local's server/master-client.ts (OL-ui/frontend).
//
//   - Address: MASTER_SERVER_URL. Plain http is refused in production unless the host is this machine.
//   - Identity: this server calls Master as `pos` with INTERNAL_KEY_POS, sent in `x-internal-key`. The key never appears in a log
//     line, an error message or a return value.
//   - Every call has a timeout (5 s by default). Redirects are never followed: fetch would carry x-internal-key to wherever a 3xx
//     points. A 3xx is reported as Master's answer and the call stops there.

export type MasterStatus = 'ok' | 'wrong_key' | 'unreachable' | 'not_configured';
export type MasterErrorCode = 'not_configured' | 'insecure_url' | 'unreachable' | 'timeout' | 'http';

type Env = Record<string, string | undefined>;
type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export const MASTER_CALLER = 'pos';
const KEY_ENV = 'INTERNAL_KEY_POS';

// Why a call did not produce an answer from Master. `status` is Master's HTTP status when it did answer (code 'http').
export class MasterError extends Error {
  code: MasterErrorCode;
  status?: number;
  constructor(code: MasterErrorCode, message: string, status?: number) {
    super(message);
    this.name = 'MasterError';
    this.code = code;
    this.status = status;
  }
}

const isLocalHost = (host: string) => host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';

// Master's base address (no trailing slash) and our key, or why they cannot be used. Nothing here echoes the key.
function target(env: Env): { base: string; key: string } {
  const raw = env.MASTER_SERVER_URL?.trim();
  const key = env[KEY_ENV]?.trim();
  if (!raw || !key) throw new MasterError('not_configured', `Master is not configured (needs MASTER_SERVER_URL and ${KEY_ENV})`);
  let url: URL;
  try { url = new URL(raw); } catch { throw new MasterError('not_configured', 'MASTER_SERVER_URL is not a valid address'); }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new MasterError('insecure_url', 'MASTER_SERVER_URL must be http(s)');
  if (url.protocol === 'http:' && (env.NODE_ENV ?? process.env.NODE_ENV) === 'production' && !isLocalHost(url.hostname)) {
    throw new MasterError('insecure_url', `Refusing to send a key over plain http to ${url.hostname}; use https`);
  }
  return { base: raw.replace(/\/+$/, ''), key };
}

export type MasterCall = {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  idempotencyKey?: string;
  timeoutMs?: number;
  env?: Env;
  fetchImpl?: FetchLike;
};

// One request to Master, sent once. Resolves with Master's parsed JSON on 2xx; otherwise throws a MasterError (never with the key).
export async function masterFetch<T = unknown>(path: string, call: MasterCall = {}): Promise<T> {
  const { base, key } = target(call.env ?? process.env);
  const doFetch = call.fetchImpl ?? ((url, init) => fetch(url, init));
  const timeoutMs = call.timeoutMs ?? 5000;
  const headers: Record<string, string> = { 'x-internal-key': key, 'x-ol-source': 'one-local-pos', accept: 'application/json' };
  if (call.idempotencyKey) headers['Idempotency-Key'] = call.idempotencyKey;
  if (call.body !== undefined) headers['content-type'] = 'application/json';
  let res: Response;
  try {
    res = await doFetch(`${base}${path.startsWith('/') ? path : `/${path}`}`, {
      method: call.method ?? 'GET', headers, body: call.body === undefined ? undefined : JSON.stringify(call.body),
      signal: AbortSignal.timeout(timeoutMs), redirect: 'manual',
    });
  } catch (error) {
    // The underlying error is dropped on purpose: some carry the request, and the request carries the key.
    const name = (error as { name?: string })?.name;
    if (name === 'TimeoutError' || name === 'AbortError') throw new MasterError('timeout', `Master did not answer within ${timeoutMs} ms`);
    throw new MasterError('unreachable', 'Master could not be reached');
  }
  if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) {
    await res.body?.cancel().catch(() => {});
    throw new MasterError('http', `Master answered with a redirect (${res.status}); not followed`, res.status);
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => {});
    throw new MasterError('http', `Master answered ${res.status}`, res.status);
  }
  const text = await res.text();
  try { return (text ? JSON.parse(text) : null) as T; } catch { throw new MasterError('http', `Master answered ${res.status} with a body that is not JSON`, res.status); }
}

// Does Master accept our key? Asks GET /api/internal/whoami and checks Master recognised us as `pos`.
export async function checkMaster(options: { env?: Env; fetchImpl?: FetchLike; timeoutMs?: number } = {}): Promise<MasterStatus> {
  try {
    const me = await masterFetch<{ caller?: string }>('/api/internal/whoami', { env: options.env, fetchImpl: options.fetchImpl, timeoutMs: options.timeoutMs ?? 1500 });
    // Another server's key in our variable would be accepted by Master but act as someone else.
    return me?.caller === MASTER_CALLER ? 'ok' : 'wrong_key';
  } catch (error) {
    if (!(error instanceof MasterError)) return 'unreachable';
    if (error.code === 'not_configured' || error.code === 'insecure_url') return 'not_configured';
    if (error.code === 'http' && (error.status === 401 || error.status === 403)) return 'wrong_key';
    return 'unreachable';
  }
}

// checkMaster, remembered for 30 s so a busy health endpoint does not call Master on every probe.
let cached: { at: number; status: Promise<MasterStatus> } | null = null;
export function masterStatus(options: { ttlMs?: number; now?: () => number } & Parameters<typeof checkMaster>[0] = {}): Promise<MasterStatus> {
  const now = (options.now ?? Date.now)();
  if (cached && now - cached.at < (options.ttlMs ?? 30_000)) return cached.status;
  const status = checkMaster(options);
  cached = { at: now, status };
  return status;
}
export const resetMasterStatusCache = () => { cached = null; };
