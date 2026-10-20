// Secret-bearing: "Remove background (AI)" on the item form. The photo goes to remove.bg and comes back as a transparent PNG for the
// person to keep or discard; nothing is saved here (saving a product photo is the catalogue's job once the database stores item photos).
//   1. REMOVE_BG_API_KEY must be set on this server (never printed). Without it: 503 "Background removal is not set up yet.", code bg_not_configured.
//   2. The caller must be active staff of a business (requireStaff); the gateway's per-address 'secure' rate limit applies.
//   3. One remove.bg call (JSON in, JSON out) with the checked photo; REMOVE_BG_SIZE picks the output size (default 'auto').
//   4. The answer: { image_b64, content_type: 'image/png' }. remove.bg's refusals become plain sentences (credits, key, busy, unusable photo).
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { RemoveBg } from '../../schemas/catalogue.ts';
import { requireStaff } from '../../staff.ts';
import type { SecureCtx } from './index.ts';

export const REMOVE_BG_URL = 'https://api.remove.bg/v1.0/removebg';

export type BgAnswer = { status: number; json: unknown };
export type Deps = {
  key: () => string | null;
  size: () => string;
  staff: (request: Request) => Promise<unknown>;
  call: (key: string, body: Record<string, unknown>) => Promise<BgAnswer>;
};

export const notConfigured = () => new HttpError(503, 'Background removal is not set up yet. Your photo is kept as it is.', undefined, 'bg_not_configured');

/** The one remove.bg call: base64 in, base64 PNG out (Accept: application/json). */
export async function removeBgCall(key: string, body: Record<string, unknown>): Promise<BgAnswer> {
  const res = await fetch(REMOVE_BG_URL, {
    method: 'POST',
    headers: { 'X-Api-Key': key, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(45_000),
  });
  let json: unknown = null;
  try {
    json = await res.json();
  } catch {
    /* an empty or non-JSON answer: handled by the status below */
  }
  return { status: res.status, json };
}

export const defaultDeps: Deps = {
  key: () => process.env.REMOVE_BG_API_KEY?.trim() || null,
  size: () => process.env.REMOVE_BG_SIZE?.trim() || 'auto',
  staff: requireStaff,
  call: removeBgCall,
};

export async function removeBackground({ request, args }: SecureCtx, deps: Deps = defaultDeps) {
  const { image_b64 } = parse(RemoveBg, args);
  const key = deps.key();
  if (!key) throw notConfigured();                                   // before anything else: an unconfigured server spends no credit
  await deps.staff(request);

  let out: BgAnswer;
  try {
    out = await deps.call(key, { image_file_b64: image_b64, size: deps.size(), format: 'png' });
  } catch (e) {
    console.error('[remove_bg] call failed', e instanceof Error ? e.name : 'error');
    throw new HttpError(502, 'Background removal did not answer. Try again.', undefined, 'bg_failed');
  }
  const b64 = (out.json as { data?: { result_b64?: unknown } } | null)?.data?.result_b64;
  if (out.status === 200 && typeof b64 === 'string' && b64.length > 0) return { image_b64: b64, content_type: 'image/png' };

  // remove.bg refusals: 400 the photo (no subject found, unreadable), 402 out of credits, 403 key refused, 429 too many requests.
  console.error('[remove_bg] refused', out.status);
  switch (out.status) {
    case 400:
      throw new HttpError(422, 'Background removal could not find the product in this photo. Try a clearer photo.', undefined, 'bg_unusable');
    case 402:
      throw new HttpError(503, 'Background removal is out of credits. Your photo is kept as it is.', undefined, 'bg_no_credits');
    case 401:
    case 403:
      throw notConfigured();
    case 429:
      throw new HttpError(503, 'Background removal is busy right now. Try again in a minute.', undefined, 'bg_busy');
    default:
      throw new HttpError(502, 'Background removal did not answer. Try again.', undefined, 'bg_failed');
  }
}
