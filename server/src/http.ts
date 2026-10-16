// Small HTTP helpers: error shape {detail, code?}, body reading with a size cap, a per-process rate limit.
export class HttpError extends Error {
  status: number;
  detail: string;
  headers?: Record<string, string>;
  code?: string;
  extra?: Record<string, unknown>;
  constructor(status: number, detail: string, headers?: Record<string, string>, code?: string) {
    super(detail);
    this.status = status; this.detail = detail; this.headers = headers; this.code = code;
  }
}

export const json = (body: unknown, init: ResponseInit = {}) => Response.json(body, init);

/** The app reads `detail` from error bodies. */
export const fail = (status: number, detail: string, headers?: Record<string, string>, code?: string, extra?: Record<string, unknown>) =>
  Response.json(code ? { detail, code, ...extra } : { detail, ...extra }, { status, headers });

/** Anything that looks like a credential is masked before it is logged. */
export function redact(value: unknown): string {
  const text = value instanceof Error ? `${value.name}: ${value.message}${value.stack ? `\n${value.stack}` : ''}` : typeof value === 'string' ? value : JSON.stringify(value) ?? String(value);
  return text
    .replace(/([?&](?:key|apikey|api_key|token|access_token)=)[^&\s"')]+/gi, '$1[hidden]')
    .replace(/Bearer\s+[\w.~+/=-]{12,}/gi, 'Bearer [hidden]')
    .replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[hidden]')
    .replace(/\b(?:sb_secret|sb_publishable|sbp)_[\w-]{8,}/g, '[hidden]')
    .slice(0, 4000);
}

export type Handler = (request: Request, params: Record<string, string>) => Response | Promise<Response>;

/** Wraps a handler so thrown HttpErrors become {detail} responses and anything else becomes a plain 500. */
export function route(handler: Handler): Handler {
  return async (request, params) => {
    try {
      return await handler(request, params ?? {});
    } catch (error) {
      if (error instanceof HttpError) return fail(error.status, error.detail, error.headers, error.code, error.extra);
      console.error('[api]', request.method, new URL(request.url).pathname, redact(error));
      return fail(500, 'Something went wrong. Please try again.');
    }
  };
}

/** The body as text, refused as soon as it is over the limit. */
export async function readText(request: Request, maxBytes = 64 * 1024): Promise<string> {
  const declared = Number(request.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > maxBytes) throw new HttpError(413, 'Request is too large');
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) { await reader.cancel().catch(() => {}); throw new HttpError(413, 'Request is too large'); }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export async function readBody<T = Record<string, unknown>>(request: Request, maxBytes = 64 * 1024): Promise<T> {
  const text = await readText(request, maxBytes);
  try {
    const body = JSON.parse(text || '{}');
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error();
    return body as T;
  } catch {
    throw new HttpError(400, 'Request body must be a JSON object');
  }
}

// Per-process limiter: fixed window per subject. Expired buckets are swept and the map is capped.
const buckets = new Map<string, { count: number; reset: number }>();
const MAX_BUCKETS = 50_000;

export function limit(subject: string, name: string, max: number, windowMs: number) {
  const now = Date.now();
  if (buckets.size > MAX_BUCKETS) {
    for (const [k, b] of buckets) if (b.reset <= now) buckets.delete(k);
    for (const k of buckets.keys()) { if (buckets.size <= MAX_BUCKETS * 0.8) break; buckets.delete(k); }
  }
  const key = `${name}:${subject}`;
  const bucket = buckets.get(key);
  if (!bucket || bucket.reset <= now) { buckets.set(key, { count: 1, reset: now + windowMs }); return; }
  if (++bucket.count > max) {
    const seconds = Math.ceil((bucket.reset - now) / 1000);
    throw new HttpError(429, `Too many attempts. Please try again in ${seconds} seconds.`, { 'Retry-After': String(seconds) });
  }
}

/** Caller's network address for limits that must not depend on what the caller sends. 'direct' = unknown (one shared bucket). */
export function clientIp(request: Request, peer?: string): string {
  const configured = Number(process.env.TRUSTED_PROXY_HOPS);
  const hops = Number.isInteger(configured) && configured >= 0 && process.env.TRUSTED_PROXY_HOPS?.trim() ? configured : process.env.NODE_ENV === 'production' ? 1 : 0;
  if (hops === 0) return peer ?? 'direct';
  const forwarded = (request.headers.get('x-forwarded-for') ?? '').split(',').map(s => s.trim()).filter(Boolean);
  const hit = forwarded.length ? forwarded[Math.max(0, forwarded.length - hops)] : request.headers.get('x-real-ip')?.trim();
  return hit && /^[0-9a-fA-F:.]{3,45}$/.test(hit) ? hit.toLowerCase() : 'direct';
}

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}
