// Unit tests that need no database and no Petpooja / GoFrugal account: Settings -> Integrations (secure handlers pos_integration_connect and
// pos_integration_test, the provider checks, and the public-address guard on the GoFrugal store URL).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { dbFunctions, lookup } from '../../src/rpc-manifest.ts';
import { HttpError } from '../../src/http.ts';
import * as ig from '../../src/schemas/integrations.ts';
import { connect, gofrugalCheck, guardedGet, isPublicAddress, petpoojaCheck, plain, testConnection, type Check, type Deps } from '../../src/modules/secure/integrations.ts';

const req = new Request('http://x/rpc/pos_integration_connect', { method: 'POST' });
const PP = { provider: 'petpooja', restaurant_id: 'r4512', app_key: 'appkey-1', app_secret: 'secret-22', access_token: 'token-9876' };
const GF = { provider: 'gofrugal', store_url: 'store.example.com/WebReporter/', api_key: 'gk-abcd1111' };
const status = (e: unknown) => (e as HttpError).status;
const code = (e: unknown) => (e as HttpError).code;

function fake(over: Partial<Deps> = {}, answer: Check = { ok: true, message: 'Connected to Cafe A on Petpooja. 12 items on the menu.' }) {
  const calls = { canEdit: 0, check: [] as unknown[], save: [] as unknown[], secret: [] as unknown[], record: [] as unknown[] };
  const deps: Deps = {
    key: () => 'server-key-0123456789',
    canEdit: async () => { calls.canEdit++; return true; },
    check: async (provider, account, credentials) => { calls.check.push({ provider, account, credentials }); return answer; },
    save: async (userId, p, key) => { calls.save.push({ userId, p, key }); return { can_edit: true, integrations: [{ provider: p.provider, status: 'connected' }] }; },
    secret: async (userId, p, key) => { calls.secret.push({ userId, p, key }); return { account: { restaurant_id: 'r4512' }, credentials: { access_token: 'token-9876' } }; },
    record: async (userId, p) => { calls.record.push({ userId, p }); return { can_edit: true, integrations: [] }; },
    ...over,
  };
  return { deps, calls };
}

test('manifest: the page and the switches run as the caller; connect and test are secure handlers; the key-holding functions are not listed', () => {
  for (const a of ['pos_integrations_get', 'pos_integration_set_sync', 'pos_integration_disconnect']) assert.equal(lookup(a)?.kind, 'db', a);
  for (const a of ['pos_integration_connect', 'pos_integration_test']) {
    const e = lookup(a);
    assert.equal(e?.kind, 'secure', a);
    assert.equal(e?.rate, 'secure', a);
    assert.equal(typeof (e as any).handler, 'function', a);
  }
  for (const hidden of ['pos_integration_save', 'pos_integration_secret', 'pos_integration_record_check', 'pos__integration_actor', 'pos__integrations_state']) {
    assert.equal(lookup(hidden), undefined, hidden);
    assert.ok(!dbFunctions().includes(hidden), hidden);
  }
});

test('request shapes', () => {
  assert.ok(ig.PetpoojaConnect.safeParse(PP).success);
  assert.ok(!ig.PetpoojaConnect.safeParse({ ...PP, organization_id: 'x' }).success, 'no field the handler does not name');
  assert.equal(ig.PetpoojaConnect.safeParse({ ...PP, app_secret: '' }).error?.issues[0].message, 'Enter the app secret.');
  assert.equal(ig.PetpoojaConnect.safeParse({ ...PP, access_token: 'ab' }).error?.issues[0].message, 'The access token looks too short. Paste it again.');
  assert.ok(!ig.PetpoojaConnect.safeParse({ ...PP, app_key: 'has space' }).success);
  assert.ok(!ig.PetpoojaConnect.safeParse({ ...PP, restaurant_id: 'r 1' }).success);
  const gf = ig.GofrugalConnect.safeParse(GF);
  assert.ok(gf.success && gf.data.store_url === 'http://store.example.com/WebReporter', 'scheme added, trailing slash removed');
  assert.ok(ig.GofrugalConnect.safeParse({ ...GF, outlet_id: '' }).success, 'outlet is optional');
  for (const bad of ['ftp://store.example.com', 'http://user:pw@store.example.com/WebReporter', 'http://store.example.com/WebReporter?x=1', 'not a url at all', 'javascript:alert(1)']) {
    assert.ok(!ig.GofrugalConnect.safeParse({ ...GF, store_url: bad }).success, bad);
  }
  assert.equal(ig.storeUrl('https://hq.example.in:8443/RayMedi_HQ'), 'https://hq.example.in:8443/RayMedi_HQ');
  assert.ok(ig.Sync.safeParse({ provider: 'gofrugal', stock: true }).success);
  assert.equal(ig.Sync.safeParse({ provider: 'gofrugal' }).error?.issues[0].message, 'Choose what to sync.');
  assert.ok(!ig.Sync.safeParse({ provider: 'gofrugal', menu: 'on' }).success);
  assert.equal(ig.Which.safeParse({ provider: 'zomato' }).error?.issues[0].message, 'Choose Petpooja or GoFrugal.');
});

test('connect: keys the provider accepts are saved with the user id, the server key and only the last four characters as a hint', async () => {
  const { deps, calls } = fake();
  const page = await connect({ request: req, userId: 'u1', args: PP }, deps);
  assert.deepEqual(calls.check, [{ provider: 'petpooja', account: { restaurant_id: 'r4512' }, credentials: { app_key: 'appkey-1', app_secret: 'secret-22', access_token: 'token-9876' } }]);
  assert.deepEqual(calls.save, [{
    userId: 'u1', key: 'server-key-0123456789',
    p: { provider: 'petpooja', account: { restaurant_id: 'r4512' }, credentials: { app_key: 'appkey-1', app_secret: 'secret-22', access_token: 'token-9876' }, key_hint: '9876', message: 'Connected to Cafe A on Petpooja. 12 items on the menu.' },
  }]);
  assert.deepEqual(page, { can_edit: true, integrations: [{ provider: 'petpooja', status: 'connected' }] });
});

test('connect GoFrugal: the store URL is normalised before the check; an empty outlet is not stored', async () => {
  const { deps, calls } = fake({}, { ok: true, message: 'Connected to GoFrugal. 3 items in your catalogue.' });
  await connect({ request: req, userId: 'u1', args: { ...GF, outlet_id: '' } }, deps);
  assert.deepEqual((calls.check[0] as any).account, { store_url: 'http://store.example.com/WebReporter' });
  assert.equal((calls.save[0] as any).p.key_hint, '1111');
});

test('connect refusals: not configured, not allowed and bad bodies stop before any provider is called', async () => {
  let f = fake({ key: () => '' });
  await assert.rejects(connect({ request: req, userId: 'u', args: PP }, f.deps), e => status(e) === 503 && code(e) === 'not_configured');
  assert.equal(f.calls.check.length, 0);
  f = fake({ canEdit: async () => false });
  await assert.rejects(connect({ request: req, userId: 'u', args: PP }, f.deps), e => status(e) === 403 && (e as HttpError).detail === 'Only the owner or a manager can change integrations.');
  assert.equal(f.calls.check.length, 0, 'staff who may not edit cannot use the server to try keys');
  f = fake();
  await assert.rejects(connect({ request: req, userId: 'u', args: { ...PP, app_key: '' } }, f.deps), e => status(e) === 400 && (e as HttpError).detail === 'Enter the app key.');
  await assert.rejects(connect({ request: req, userId: 'u', args: { provider: 'tally' } }, f.deps), e => status(e) === 400 && (e as HttpError).detail === 'Choose Petpooja or GoFrugal.');
  assert.equal(f.calls.canEdit + f.calls.check.length + f.calls.save.length, 0);
});

test('connect: keys the provider refuses are never saved; the provider\'s reason becomes the status', async () => {
  for (const [reason, http, c] of [['refused', 422, 'integration_refused'], ['unreachable', 502, 'integration_unreachable'], ['bad_address', 422, 'integration_bad_address'], ['not_api', 422, 'integration_bad_address']] as const) {
    const { deps, calls } = fake({}, { ok: false, reason, message: `nope (${reason})` });
    await assert.rejects(connect({ request: req, userId: 'u', args: PP }, deps), e => status(e) === http && code(e) === c && (e as HttpError).detail === `nope (${reason})`, reason);
    assert.equal(calls.save.length, 0, reason);
  }
});

test('test: the saved keys are checked again and the outcome recorded, pass or fail; the answer carries the check', async () => {
  const { deps, calls } = fake({}, { ok: false, reason: 'refused', message: 'Petpooja refused these keys.' });
  const r = await testConnection({ request: req, userId: 'u9', args: { provider: 'petpooja' } }, deps) as any;
  assert.deepEqual(calls.secret, [{ userId: 'u9', p: { provider: 'petpooja' }, key: 'server-key-0123456789' }]);
  assert.deepEqual(calls.check, [{ provider: 'petpooja', account: { restaurant_id: 'r4512' }, credentials: { access_token: 'token-9876' } }]);
  assert.deepEqual(calls.record, [{ userId: 'u9', p: { provider: 'petpooja', ok: false, message: 'Petpooja refused these keys.' } }]);
  assert.deepEqual(r.check, { provider: 'petpooja', ok: false, message: 'Petpooja refused these keys.' });
  assert.equal(r.can_edit, true);
  await assert.rejects(testConnection({ request: req, userId: 'u', args: { provider: 'petpooja', extra: 1 } }, deps), e => status(e) === 400);
  await assert.rejects(testConnection({ request: req, userId: 'u', args: { provider: 'petpooja' } }, fake({ key: () => '' }).deps), e => status(e) === 503);
});

function fakeFetch(answer: { status: number; body?: unknown } | Error) {
  const seen: { url: string; init: RequestInit }[] = [];
  const call = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    if (answer instanceof Error) throw answer;
    return new Response(answer.body === undefined ? null : typeof answer.body === 'string' ? answer.body : JSON.stringify(answer.body), { status: answer.status });
  }) as unknown as typeof fetch;
  return { call, seen };
}
const PP_ACC = { restaurant_id: 'r4512' }, PP_KEYS = { app_key: 'appkey-1', app_secret: 'secret-22', access_token: 'token-9876' };

test('Petpooja check: the three keys go in headers, the restaurant in the body; success "1" names the restaurant and counts the menu', async () => {
  const f = fakeFetch({ status: 200, body: { success: '1', restaurants: [{ details: { restaurantname: 'Cafe A' } }], items: [{}, {}, {}] } });
  const r = await petpoojaCheck(PP_ACC, PP_KEYS, f.call, 'https://pp.test/menu');
  assert.deepEqual(r, { ok: true, message: 'Connected to Cafe A on Petpooja. 3 items on the menu.' });
  assert.equal(f.seen[0].url, 'https://pp.test/menu');
  const h = f.seen[0].init.headers as Record<string, string>;
  assert.equal(h['app-key'], 'appkey-1');
  assert.equal(h['app-secret'], 'secret-22');
  assert.equal(h['access-token'], 'token-9876');
  assert.deepEqual(JSON.parse(String(f.seen[0].init.body)), { restID: 'r4512' });
  assert.equal(f.seen[0].init.redirect, 'manual');
  assert.deepEqual(await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch({ status: 200, body: { success: 1 } }).call, 'https://pp.test/menu'), { ok: true, message: 'Connected to Petpooja.' });
});

test('Petpooja check: refusals and outages', async () => {
  let r = await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch({ status: 200, body: { success: '0', message: 'Invalid restaurant\n<b>id</b>' } }).call, 'https://pp.test/m');
  assert.deepEqual(r, { ok: false, reason: 'refused', message: 'Petpooja refused these details: Invalid restaurant b id /b' });
  r = await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch({ status: 200, body: { success: '0' } }).call, 'https://pp.test/m');
  assert.equal(r.message, 'Petpooja refused these details. Check the restaurant ID and keys.');
  r = await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch({ status: 403, body: { message: 'Forbidden' } }).call, 'https://pp.test/m');
  assert.equal(r.reason, 'refused');
  r = await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch({ status: 502, body: '<html>bad gateway</html>' }).call, 'https://pp.test/m');
  assert.deepEqual(r, { ok: false, reason: 'unreachable', message: 'Petpooja did not answer properly. Try again in a few minutes.' });
  r = await petpoojaCheck(PP_ACC, PP_KEYS, fakeFetch(new TypeError('fetch failed')).call, 'https://pp.test/m');
  assert.equal(r.reason, 'unreachable');
});

test('GoFrugal check: X-Auth-Token on the items list of the store URL; answers read from the status and the list', async () => {
  const seen: { url: string; headers: Record<string, string> }[] = [];
  const get = (answer: { status: number; body: string } | Error) => (async (url: string, headers: Record<string, string>) => {
    seen.push({ url, headers });
    if (answer instanceof Error) throw answer;
    return answer;
  }) as typeof guardedGet;
  const acc = { store_url: 'https://store.example.com/WebReporter' }, keys = { api_key: 'gk-abcd1111' };
  let r = await gofrugalCheck(acc, keys, get({ status: 200, body: JSON.stringify({ items: [{ itemId: 1 }], total_records: 245 }) }));
  assert.deepEqual(r, { ok: true, message: 'Connected to GoFrugal. 245 items in your catalogue.' });
  assert.equal(seen[0].url, 'https://store.example.com/WebReporter/api/v1/items?page=1&limit=1');
  assert.equal(seen[0].headers['X-Auth-Token'], 'gk-abcd1111');
  r = await gofrugalCheck(acc, keys, get({ status: 401, body: '' }));
  assert.equal(r.reason, 'refused');
  r = await gofrugalCheck(acc, keys, get({ status: 404, body: 'Not Found' }));
  assert.equal(r.reason, 'not_api');
  r = await gofrugalCheck(acc, keys, get({ status: 302, body: '' }));
  assert.equal(r.reason, 'not_api');
  r = await gofrugalCheck(acc, keys, get({ status: 200, body: '<html>login</html>' }));
  assert.equal(r.reason, 'not_api');
  r = await gofrugalCheck(acc, keys, get(Object.assign(new Error('address not allowed'), { code: 'EBLOCKED' })));
  assert.equal(r.reason, 'bad_address');
  r = await gofrugalCheck(acc, keys, get(new Error('ECONNREFUSED')));
  assert.equal(r.reason, 'unreachable');
  r = await gofrugalCheck({ store_url: 'ftp://x' }, keys, get({ status: 200, body: '{}' }));
  assert.equal(r.reason, 'bad_address');
});

test('public-address guard', () => {
  for (const ip of ['8.8.8.8', '13.234.10.1', '2606:4700:4700::1111', '::ffff:8.8.8.8']) assert.ok(isPublicAddress(ip), ip);
  for (const ip of ['127.0.0.1', '10.1.2.3', '172.20.0.5', '192.168.1.10', '169.254.169.254', '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255',
    '::1', '::', 'fe80::1', 'fd00::1', 'fc12:3456::1', '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:a9fe:a9fe', '64:ff9b::a00:1', '2002:c0a8:101::1', 'ff02::1', 'not-an-ip']) {
    assert.ok(!isPublicAddress(ip), ip);
  }
});

test('guardedGet never connects to a private address, by IP or by a name that resolves to one', async () => {
  let hits = 0;
  const server = createServer((_q, s) => { hits++; s.end('{"items":[]}'); });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  try {
    await assert.rejects(guardedGet(`http://127.0.0.1:${port}/WebReporter/api/v1/items`, {}), (e: any) => e.code === 'EBLOCKED');
    await assert.rejects(guardedGet(`http://localhost:${port}/WebReporter/api/v1/items`, {}), (e: any) => e.code === 'EBLOCKED');
    await assert.rejects(guardedGet(`http://[::ffff:127.0.0.1]:${port}/x`, {}), (e: any) => e.code === 'EBLOCKED');
    assert.equal(hits, 0);
  } finally {
    server.close();
  }
});

test('plain: provider sentences are one short line', () => {
  assert.equal(plain('  a\n\tb  '), 'a b');
  assert.equal(plain(42), '');
  assert.equal(plain('x'.repeat(200)).length, 160);
});
