import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes } from 'node:crypto';
import { indianMobile, sendViaApitxt, smsHook, verifySignature, type SmsEnv } from '../../src/modules/secure/smsHook.ts';
import { dispatch } from '../../src/router.ts';
import '../../src/routes.ts';

const raw = randomBytes(32).toString('base64');
const SECRET = `v1,whsec_${raw}`;
const NOW = 1_800_000_000;
const env = (over: Partial<SmsEnv> = {}): SmsEnv => ({ secret: SECRET, authKey: 'k-test', templateId: null, baseUrl: 'https://stub.test', ...over });

function signed(body: string, opts: { ts?: number; secret?: string } = {}) {
  const id = 'msg_1', ts = String(opts.ts ?? NOW);
  const key = Buffer.from((opts.secret ?? raw), 'base64');
  const sig = createHmac('sha256', key).update(`${id}.${ts}.${body}`).digest('base64');
  return new Request('https://x/hooks/send-sms', { method: 'POST', body, headers: { 'webhook-id': id, 'webhook-timestamp': ts, 'webhook-signature': `v1,${sig}` } });
}
const payload = (phone: string, otp = '482913') => JSON.stringify({ user: { id: 'u1', phone }, sms: { otp } });

type Call = { url: string; form: URLSearchParams };
function stub(reply: { status?: number; body: unknown } = { body: { status: 'success', message: 'Sms OTP Sent Successfully', data: { request_id: 'SMS-OTP-1' } } }) {
  const calls: Call[] = [];
  const fetcher = (async (url: string, init: RequestInit) => {
    calls.push({ url, form: new URLSearchParams(String(init.body)) });
    return new Response(JSON.stringify(reply.body), { status: reply.status ?? 200 });
  }) as unknown as typeof fetch;
  return { calls, fetcher };
}

test('signature: accepts a Standard Webhooks signature, refuses wrong key, stale time, missing headers', () => {
  const body = payload('919876543210');
  const r = signed(body);
  assert.equal(verifySignature(SECRET, r.headers, body, NOW), true);
  assert.equal(verifySignature(raw, r.headers, body, NOW), true, 'bare base64 secret also works');
  assert.equal(verifySignature(SECRET, r.headers, body + ' ', NOW), false, 'body changed');
  assert.equal(verifySignature(`v1,whsec_${randomBytes(32).toString('base64')}`, r.headers, body, NOW), false, 'other secret');
  assert.equal(verifySignature(SECRET, r.headers, body, NOW + 301), false, 'older than 5 minutes');
  assert.equal(verifySignature(SECRET, new Headers(), body, NOW), false);
});

test('indianMobile: Indian mobiles only, normalised to 91 + 10 digits', () => {
  assert.equal(indianMobile('919876543210'), '919876543210');
  assert.equal(indianMobile('+91 98765 43210'), '919876543210');
  assert.equal(indianMobile('9876543210'), '919876543210');
  assert.equal(indianMobile('915876543210'), null, 'landline-style first digit');
  assert.equal(indianMobile('14155551234'), null);
  assert.equal(indianMobile(undefined), null);
});

test('hook: signed request sends one apitxt sendOTP with the code and answers {}', async () => {
  const s = stub();
  const r = await smsHook({ env: () => env({ templateId: '42' }), fetcher: s.fetcher, now: () => NOW })(signed(payload('919876543210')), {});
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), {});
  assert.equal(s.calls.length, 1);
  assert.equal(s.calls[0].url, 'https://stub.test/api/sendOTP');
  assert.equal(s.calls[0].form.get('authkey'), 'k-test');
  assert.equal(s.calls[0].form.get('mobile'), '919876543210');
  assert.equal(s.calls[0].form.get('otp'), '482913');
  assert.equal(s.calls[0].form.get('template_id'), '42');
  assert.equal(s.calls[0].url.includes('k-test'), false, 'key never in the address');
});

test('hook: unsigned or forged calls get 401 and nothing is sent', async () => {
  const s = stub();
  const h = smsHook({ env: () => env(), fetcher: s.fetcher, now: () => NOW });
  const forged = signed(payload('919876543210'), { secret: randomBytes(32).toString('base64') });
  assert.equal((await h(forged, {})).status, 401);
  assert.equal((await h(new Request('https://x/hooks/send-sms', { method: 'POST', body: payload('919876543210') }), {})).status, 401);
  assert.equal(s.calls.length, 0);
});

test('hook: non-Indian number, missing key, missing secret → hook error, nothing sent', async () => {
  const s = stub();
  const foreign = await (await smsHook({ env: () => env(), fetcher: s.fetcher, now: () => NOW })(signed(payload('14155551234')), {})).json() as any;
  assert.equal(foreign.error.http_code, 400);
  const noKey = await (await smsHook({ env: () => env({ authKey: null }), fetcher: s.fetcher, now: () => NOW })(signed(payload('919876543210')), {})).json() as any;
  assert.equal(noKey.error.http_code, 500);
  const noSecret = await (await smsHook({ env: () => env({ secret: null }), fetcher: s.fetcher, now: () => NOW })(signed(payload('919876543210')), {})).json() as any;
  assert.equal(noSecret.error.http_code, 500);
  assert.equal(s.calls.length, 0);
});

test('hook: apitxt failure becomes a hook error the app can show; the code is never in the reason', async () => {
  const s = stub({ status: 200, body: { status: 'AUTH_FAILED', message: 'Invalid Auth Key' } });
  const r = await smsHook({ env: () => env(), fetcher: s.fetcher, now: () => NOW })(signed(payload('919876543210')), {});
  const j = await r.json() as any;
  assert.equal(r.status, 200);
  assert.equal(j.error.http_code, 500);
  assert.match(j.error.message, /Could not send the code/);
  const echo = stub({ status: 429, body: { status: 'error', message: 'Rate limit: 482913 too many' } });
  const reason = await sendViaApitxt(env(), '919876543210', '482913', echo.fetcher);
  assert.ok(reason && !reason.includes('482913'));
  const limited = await (await smsHook({ env: () => env(), fetcher: echo.fetcher, now: () => NOW })(signed(payload('919876543210')), {})).json() as any;
  assert.equal(limited.error.http_code, 429);
});

test('route: POST /hooks/send-sms is wired (unsigned → 401 or not-set-up error, GET → 405)', async () => {
  const r = await dispatch(new Request('https://x/hooks/send-sms', { method: 'POST', body: '{}' }));
  assert.ok(r.status === 401 || r.status === 200);
  assert.equal((await dispatch(new Request('https://x/hooks/send-sms'))).status, 405);
});
