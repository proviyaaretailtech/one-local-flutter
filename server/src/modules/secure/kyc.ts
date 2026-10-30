// PAN and GSTIN checks for onboarding section 4 (founder, 30 Oct 2026), run by partner_app_save_tax before anything is saved.
//   PAN:   apitxt PAN 360 (POST /api/panAdvanceVerify, PAN only). VALID passes; any other verdict refuses the save. Only the verdict,
//          the name on Income Tax records and the holder type come back: the masked Aadhaar, phone, email and address apitxt also
//          returns are dropped here and never logged.
//   GSTIN: apitxt GST (POST /api/gst/:gstin). Active passes; cancelled, suspended or not found refuses the save. Free first check:
//          a GSTIN carries its PAN in characters 3-12, so it must match the PAN typed with it.
// APITXT_AUTH_KEY (same key as the sign-in texts; never printed). Each check costs apitxt credits, so a person gets at most
// CHECKS_PER_HOUR saves that check something. When apitxt cannot answer (no key, wallet empty, outage) the save goes ahead
// unchecked: a vendor problem must not stop onboarding, and One Local reviews every application before approval.
import { HttpError, limit } from '../../http.ts';

const TIMEOUT_MS = 10_000;
export const CHECKS_PER_HOUR = 10;

export type KycEnv = { authKey: string | null; baseUrl: string };
export const kycEnv = (): KycEnv => ({
  authKey: process.env.APITXT_AUTH_KEY?.trim() || null,
  baseUrl: (process.env.APITXT_BASE_URL?.trim() || 'https://apitxt.com').replace(/\/+$/, ''),
});

export type PanCheck = { status: 'verified'; name: string; holder_type: string } | { status: 'unchecked' };
export type GstCheck = { status: 'active'; legal_name: string; trade_name: string; state: string } | { status: 'unchecked' };
export type TaxChecks = { pan?: PanCheck; gstin?: GstCheck };

type Answer = { ok: true; data: Record<string, unknown> } | { ok: false; reason: string };

/** One apitxt call; the key and [fields] go in the JSON body. ok only for a success reply with data; anything else is a reason that is
 *  safe to log (no key, no PAN). */
async function apitxt(env: KycEnv, path: string, fields: Record<string, string>, fetcher: typeof fetch): Promise<Answer> {
  let status = 0, body: Record<string, unknown> = {};
  try {
    const r = await fetcher(`${env.baseUrl}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ authkey: env.authKey, ...fields }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    status = r.status;
    const parsed = await r.json().catch(() => null);
    if (parsed && typeof parsed === 'object') body = parsed as Record<string, unknown>;
  } catch (e) {
    return { ok: false, reason: `unreachable (${e instanceof Error ? e.name : 'error'})` };
  }
  // success is {status: 200 | "success", data: {...}}; errors come as HTTP 200 or 4xx with status 304, "error", "AUTH_FAILED", ...
  const s = String(body.status ?? '').toLowerCase();
  if (status >= 200 && status < 300 && (s === '200' || s === 'success') && body.data && typeof body.data === 'object') {
    return { ok: true, data: body.data as Record<string, unknown> };
  }
  return { ok: false, reason: `${status} ${String(body.status ?? '')} ${String(body.message ?? '')}`.slice(0, 160) };
}

const text = (v: unknown) => (typeof v === 'string' ? v.trim() : '');

const refused = (message: string, code: string) => new HttpError(422, message, undefined, code);

/** The PAN check. Throws 422 when the Income Tax records say the PAN is not valid. */
export async function checkPan(env: KycEnv, pan: string, fetcher: typeof fetch = fetch): Promise<PanCheck> {
  const a = await apitxt(env, '/api/panAdvanceVerify', { pan }, fetcher);
  if (!a.ok) {
    console.warn('[kyc] PAN check unavailable:', a.reason);
    return { status: 'unchecked' };
  }
  const verdict = text(a.data.status).toUpperCase();
  if (verdict !== 'VALID') throw refused('This PAN is not valid in Income Tax records. Check it and try again.', 'pan_invalid');
  return { status: 'verified', name: text(a.data.registered_name) || text(a.data.name_pan_card), holder_type: text(a.data.type) };
}

/** The GSTIN check. Throws 422 when the GST portal has no active registration for it. */
export async function checkGstin(env: KycEnv, gstin: string, fetcher: typeof fetch = fetch): Promise<GstCheck> {
  const a = await apitxt(env, `/api/gst/${encodeURIComponent(gstin)}`, {}, fetcher);
  if (!a.ok) {
    // apitxt answers a GSTIN it does not know with an error; that is a refusal, not an outage
    if (/not\s*found|no record|invalid gstin/i.test(a.reason)) throw refused('This GSTIN was not found on the GST portal. Check it, or choose Not registered.', 'gstin_not_found');
    console.warn('[kyc] GSTIN check unavailable:', a.reason);
    return { status: 'unchecked' };
  }
  const state = text(a.data.status);
  if (a.data.verified === false && !state) throw refused('This GSTIN was not found on the GST portal. Check it, or choose Not registered.', 'gstin_not_found');
  if (state.toLowerCase() !== 'active') {
    throw refused(`This GSTIN is ${state ? state.toLowerCase() : 'not active'} on the GST portal. Enter an active GSTIN, or choose Not registered.`, 'gstin_inactive');
  }
  return { status: 'active', legal_name: text(a.data.legal_name), trade_name: text(a.data.trade_name), state: text(a.data.state) };
}

/**
 * The checks for one tax save: what was typed this time (an empty PAN keeps the saved one and is not checked again).
 * Order: the free PAN-in-GSTIN match, then the limit, then the paid calls. Throws 422 on a refusal, 429 over the limit.
 */
export async function checkTax(userId: string, p: { pan?: string; gst_registered: boolean; gstin?: string }, deps: { env?: KycEnv; fetcher?: typeof fetch } = {}): Promise<TaxChecks> {
  const env = deps.env ?? kycEnv();
  const pan = (p.pan ?? '').trim().toUpperCase();
  const gstin = p.gst_registered ? (p.gstin ?? '').trim().toUpperCase() : '';
  if (gstin && !/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/.test(gstin)) throw refused('GSTIN looks wrong. It has 15 characters, like 29ABCDE1234F1Z5.', 'gstin_format');
  if (gstin && pan && gstin.slice(2, 12) !== pan) throw refused('This GSTIN belongs to a different PAN. Use the PAN of the business the GSTIN is registered to.', 'gstin_pan_mismatch');
  if (!pan && !gstin) return {};
  if (!env.authKey) {
    console.warn('[kyc] APITXT_AUTH_KEY is not set; PAN/GSTIN saved unchecked');
    return { ...(pan ? { pan: { status: 'unchecked' } as const } : {}), ...(gstin ? { gstin: { status: 'unchecked' } as const } : {}) };
  }
  limit(userId, 'kyc:tax', CHECKS_PER_HOUR, 60 * 60_000);
  const fetcher = deps.fetcher ?? fetch;
  const [panCheck, gstCheck] = await Promise.all([pan ? checkPan(env, pan, fetcher) : undefined, gstin ? checkGstin(env, gstin, fetcher) : undefined]);
  return { ...(panCheck ? { pan: panCheck } : {}), ...(gstCheck ? { gstin: gstCheck } : {}) };
}
