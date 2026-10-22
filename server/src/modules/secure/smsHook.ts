// Supabase Auth "Send SMS" hook: Supabase Auth makes the sign-in code and calls this endpoint with {user.phone, sms.otp}; we deliver it
// through apitxt.com (POST /api/sendOTP). Supabase still stores and checks the code, so both apps keep using Supabase phone sign-in unchanged.
//   1. Signature: Standard Webhooks (webhook-id, webhook-timestamp, webhook-signature) signed with SEND_SMS_HOOK_SECRET ("v1,whsec_<base64>",
//      the value Supabase shows when the hook is created). Unsigned, stale (over 5 minutes) or wrongly signed calls get 401; nothing is sent.
//   2. Only Indian mobile numbers (91 + 10 digits starting 6-9).
//   3. apitxt: APITXT_AUTH_KEY (required), APITXT_OTP_TEMPLATE_ID (optional: the template's id in the apitxt dashboard; unset = apitxt's default
//      OTP template), APITXT_BASE_URL (optional, default https://apitxt.com; tests point it at a stub). The key travels in the POST body.
//   4. Failures answer 200 with {error:{http_code, message}}: that is how a hook hands Supabase Auth a message for the app to show.
// Never logged: the code, the key, or the full number.
// Test numbers (Supabase auth.sms.test_otp) never reach this endpoint: Supabase Auth uses the fixed code and skips the hook.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { json, readText, type Handler } from '../../http.ts';

export const TOLERANCE_SECONDS = 5 * 60;
const APITXT_TIMEOUT_MS = 4000; // Supabase Auth gives an HTTP hook about 5 seconds

export type SmsEnv = { secret: string | null; authKey: string | null; templateId: string | null; baseUrl: string };
export const smsEnv = (): SmsEnv => ({
  secret: process.env.SEND_SMS_HOOK_SECRET?.trim() || null,
  authKey: process.env.APITXT_AUTH_KEY?.trim() || null,
  templateId: process.env.APITXT_OTP_TEMPLATE_ID?.trim() || null,
  baseUrl: (process.env.APITXT_BASE_URL?.trim() || 'https://apitxt.com').replace(/\/+$/, ''),
});

const hookError = (http_code: number, message: string) => json({ error: { http_code, message } });

/** Standard Webhooks check. `secret` is "v1,whsec_<base64>" (or the bare base64). */
export function verifySignature(secret: string, headers: Headers, body: string, nowSeconds = Math.floor(Date.now() / 1000)): boolean {
  const id = headers.get('webhook-id'), ts = headers.get('webhook-timestamp'), sigs = headers.get('webhook-signature');
  if (!id || !ts || !sigs || !/^\d{1,12}$/.test(ts)) return false;
  if (Math.abs(nowSeconds - Number(ts)) > TOLERANCE_SECONDS) return false;
  const key = Buffer.from(secret.replace(/^v1,/, '').replace(/^whsec_/, ''), 'base64');
  if (key.length === 0) return false;
  const expected = createHmac('sha256', key).update(`${id}.${ts}.${body}`).digest();
  for (const part of sigs.split(' ')) {
    const [version, value] = part.split(',', 2);
    if (version !== 'v1' || !value) continue;
    const given = Buffer.from(value, 'base64');
    if (given.length === expected.length && timingSafeEqual(given, expected)) return true;
  }
  return false;
}

/** "+91 98765 43210" / "919876543210" → "919876543210"; null when it is not an Indian mobile number. */
export function indianMobile(phone: unknown): string | null {
  const digits = String(phone ?? '').replace(/\D/g, '');
  const national = digits.length === 12 && digits.startsWith('91') ? digits.slice(2) : digits.length === 10 ? digits : null;
  return national && /^[6-9]\d{9}$/.test(national) ? `91${national}` : null;
}

export const mask = (mobile: string) => `${mobile.slice(0, 4)}xxxx${mobile.slice(-2)}`;

/** One apitxt sendOTP call. Resolves to null on success, else the reason (safe to log: no key, no code). */
export async function sendViaApitxt(env: SmsEnv, mobile: string, otp: string, fetcher: typeof fetch = fetch): Promise<string | null> {
  const form = new URLSearchParams({ authkey: env.authKey ?? '', mobile, otp, channel: 'sms', country: '91' });
  if (env.templateId) form.set('template_id', env.templateId);
  let status = 0, text = '';
  try {
    const r = await fetcher(`${env.baseUrl}/api/sendOTP`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: form,
      signal: AbortSignal.timeout(APITXT_TIMEOUT_MS),
    });
    status = r.status;
    text = (await r.text()).slice(0, 500);
  } catch (e) {
    return `apitxt unreachable (${e instanceof Error ? e.name : 'error'})`;
  }
  let body: Record<string, unknown> = {};
  try { const parsed = JSON.parse(text); if (parsed && typeof parsed === 'object') body = parsed; } catch { /* not JSON */ }
  if (status >= 200 && status < 300 && String(body.status ?? '').toLowerCase() === 'success') return null;
  return `apitxt ${status} ${String(body.status ?? '')} ${String(body.message ?? text)}`.replaceAll(otp, '[otp]').trim().slice(0, 200);
}

export function smsHook(deps: { env?: () => SmsEnv; fetcher?: typeof fetch; now?: () => number } = {}): Handler {
  return async request => {
    const env = (deps.env ?? smsEnv)();
    if (!env.secret) {
      console.error('[sms-hook] SEND_SMS_HOOK_SECRET is not set; refusing');
      return hookError(500, 'Sign-in by SMS is not set up yet.');
    }
    const body = await readText(request, 16 * 1024);
    if (!verifySignature(env.secret, request.headers, body, deps.now?.())) return json({ error: { http_code: 401, message: 'Invalid signature' } }, { status: 401 });

    let payload: { user?: { phone?: unknown }; sms?: { otp?: unknown } } = {};
    try { payload = JSON.parse(body); } catch { /* handled below */ }
    const otp = String(payload.sms?.otp ?? '');
    if (!/^\d{4,10}$/.test(otp)) return hookError(400, 'Could not send the code. Please try again.');
    const mobile = indianMobile(payload.user?.phone);
    if (!mobile) return hookError(400, 'Please use an Indian mobile number.');
    if (!env.authKey) {
      console.error('[sms-hook] APITXT_AUTH_KEY is not set; no SMS sent');
      return hookError(500, 'Sign-in by SMS is not set up yet.');
    }

    const failure = await sendViaApitxt(env, mobile, otp, deps.fetcher);
    if (failure) {
      console.error('[sms-hook] send failed', mask(mobile), failure);
      return hookError(/rate|limit|too many/i.test(failure) ? 429 : 500, 'Could not send the code. Please try again in a minute.');
    }
    console.log('[sms-hook] sent', mask(mobile));
    return json({});
  };
}
