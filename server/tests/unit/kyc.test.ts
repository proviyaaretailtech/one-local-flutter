// Unit tests that need no apitxt account and no database: the PAN / GSTIN checks run by partner_app_save_tax. apitxt is a stub.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { HttpError } from '../../src/http.ts';
import { checkTax, CHECKS_PER_HOUR, type KycEnv } from '../../src/modules/secure/kyc.ts';
import { saveTax } from '../../src/modules/secure/pii.ts';

const env: KycEnv = { authKey: 'test-key', baseUrl: 'https://apitxt.test' };
const PAN = 'ABCDE1234F';
const GSTIN = '27ABCDE1234F1Z5';
let n = 0;
const user = () => `user-${++n}`; // a fresh limit bucket per test

type Call = { url: string; body: Record<string, unknown> };
function apitxt(answer: (url: string) => { status?: number; json: unknown } | Error) {
  const calls: Call[] = [];
  const fetcher = (async (url: string, init?: RequestInit) => {
    calls.push({ url: String(url), body: JSON.parse(String(init?.body ?? '{}')) });
    const a = answer(String(url));
    if (a instanceof Error) throw a;
    return new Response(JSON.stringify(a.json), { status: a.status ?? 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
  return { fetcher, calls };
}

const PAN_VALID = { status: 200, message: 'success', data: { status: 'VALID', registered_name: 'RAVI SHARMA', name_pan_card: 'RAVI SHARMA', type: 'Individual or Person', masked_aadhaar_number: 'XXXXXXXX1234', mobile_number: '98XXXXXX10', email: 'r*@x.com', address: { city: 'LATUR' } } };
const GST_ACTIVE = { status: 200, message: 'success', data: { gstin: GSTIN, verified: true, status: 'Active', legal_name: 'RAVI SHARMA', trade_name: 'SHARMA KIRANA', state: 'Maharashtra', pincode: '413512' } };
const both = (url: string) => ({ json: url.includes('panAdvanceVerify') ? PAN_VALID : GST_ACTIVE });
const code = (c: string) => (e: unknown) => e instanceof HttpError && e.status === 422 && e.code === c;

test('valid PAN and active GSTIN: both checked once, key and PAN in the body, only the verdict and names come back', async () => {
  const { fetcher, calls } = apitxt(both);
  const out = await checkTax(user(), { pan: PAN, gst_registered: true, gstin: GSTIN }, { env, fetcher });
  assert.deepEqual(out, {
    pan: { status: 'verified', name: 'RAVI SHARMA', holder_type: 'Individual or Person' },
    gstin: { status: 'active', legal_name: 'RAVI SHARMA', trade_name: 'SHARMA KIRANA', state: 'Maharashtra' },
  });
  assert.equal(calls.length, 2);
  const pan = calls.find(c => c.url.endsWith('/api/panAdvanceVerify'))!;
  assert.deepEqual(pan.body, { authkey: 'test-key', pan: PAN });
  assert.ok(calls.some(c => c.url.endsWith(`/api/gst/${GSTIN}`) && c.body.authkey === 'test-key'));
  assert.ok(!JSON.stringify(out).includes('XXXX'), 'no masked Aadhaar, phone or email in the answer');
});

test('PAN not valid in Income Tax records: refused (422 pan_invalid)', async () => {
  const { fetcher } = apitxt(() => ({ json: { status: 200, message: 'success', data: { status: 'INVALID', registered_name: null } } }));
  await assert.rejects(checkTax(user(), { pan: PAN, gst_registered: false }, { env, fetcher }), code('pan_invalid'));
});

test('GSTIN cancelled or not found: refused with what the portal says', async () => {
  const cancelled = apitxt(() => ({ json: { status: 200, message: 'success', data: { gstin: GSTIN, verified: true, status: 'Cancelled', legal_name: 'X' } } }));
  await assert.rejects(checkTax(user(), { gst_registered: true, gstin: GSTIN }, { env, fetcher: cancelled.fetcher }), (e: unknown) => code('gstin_inactive')(e) && /cancelled/.test((e as HttpError).detail));
  const missing = apitxt(() => ({ json: { status: 404, message: 'GSTIN not found' } }));
  await assert.rejects(checkTax(user(), { gst_registered: true, gstin: GSTIN }, { env, fetcher: missing.fetcher }), code('gstin_not_found'));
});

test('free checks first: a GSTIN for another PAN or a malformed GSTIN is refused before any paid call', async () => {
  const { fetcher, calls } = apitxt(both);
  await assert.rejects(checkTax(user(), { pan: 'ZZZZZ9999Z', gst_registered: true, gstin: GSTIN }, { env, fetcher }), code('gstin_pan_mismatch'));
  await assert.rejects(checkTax(user(), { pan: PAN, gst_registered: true, gstin: '27ABCDE1234F1X5' }, { env, fetcher }), code('gstin_format'));
  assert.equal(calls.length, 0);
});

test('nothing typed (PAN kept, not GST-registered): nothing checked; a GSTIN when not registered is ignored', async () => {
  const { fetcher, calls } = apitxt(both);
  assert.deepEqual(await checkTax(user(), { pan: '', gst_registered: false, gstin: GSTIN }, { env, fetcher }), {});
  assert.equal(calls.length, 0);
});

test('apitxt cannot answer (outage, empty wallet, bad key, no key): saved unchecked, never refused', async () => {
  for (const answer of [() => new Error('down'), () => ({ json: { status: 301, message: 'Insufficient wallet balance' } }), () => ({ status: 401, json: { status: 'AUTH_FAILED', message: 'Invalid Auth Key' } })]) {
    const { fetcher } = apitxt(answer);
    assert.deepEqual(await checkTax(user(), { pan: PAN, gst_registered: true, gstin: GSTIN }, { env, fetcher }), { pan: { status: 'unchecked' }, gstin: { status: 'unchecked' } });
  }
  const { fetcher, calls } = apitxt(both);
  assert.deepEqual(await checkTax(user(), { pan: PAN, gst_registered: false }, { env: { ...env, authKey: null }, fetcher }), { pan: { status: 'unchecked' } });
  assert.equal(calls.length, 0);
});

test(`at most ${CHECKS_PER_HOUR} checking saves an hour per person`, async () => {
  const { fetcher } = apitxt(both);
  const who = user();
  for (let i = 0; i < CHECKS_PER_HOUR; i++) await checkTax(who, { pan: PAN, gst_registered: false }, { env, fetcher });
  await assert.rejects(checkTax(who, { pan: PAN, gst_registered: false }, { env, fetcher }), (e: unknown) => (e as HttpError).status === 429);
});

test('saveTax: a refused PAN never reaches the database', async () => {
  const before = process.env.PARTNER_PII_KEY;
  process.env.PARTNER_PII_KEY = 'unit-test-pii-key-0123456789';
  try {
    const refuse = async () => { throw new HttpError(422, 'This PAN is not valid in Income Tax records. Check it and try again.', undefined, 'pan_invalid'); };
    // the database is not reachable in unit tests: reaching it would fail differently from the 422
    await assert.rejects(saveTax({ request: new Request('http://x'), userId: 'u', args: { pan: PAN, gst_registered: false } }, { check: refuse }), code('pan_invalid'));
  } finally {
    if (before === undefined) delete process.env.PARTNER_PII_KEY; else process.env.PARTNER_PII_KEY = before;
  }
});
