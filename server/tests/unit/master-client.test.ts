// The POS server's Master client: key in x-internal-key, no redirects followed, statuses for health, the key never leaked. fetch is a stub.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkMaster, masterFetch, masterStatus, MasterError, resetMasterStatusCache } from '../../src/master-client.ts';

const KEY = 'k'.repeat(64);
const env = { MASTER_SERVER_URL: 'http://localhost:8000/', INTERNAL_KEY_POS: KEY };
type Seen = { url: string; init: RequestInit };
function stub(answer: (url: string) => Response | Error) {
  const seen: Seen[] = [];
  const fetchImpl = async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    const a = answer(url);
    if (a instanceof Error) throw a;
    return a;
  };
  return { seen, fetchImpl };
}
const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

test('whoami as pos: ok, with the key header and redirect manual', async () => {
  const { seen, fetchImpl } = stub(() => reply(200, { caller: 'pos' }));
  assert.equal(await checkMaster({ env, fetchImpl }), 'ok');
  assert.equal(seen[0].url, 'http://localhost:8000/api/internal/whoami');
  assert.equal((seen[0].init.headers as Record<string, string>)['x-internal-key'], KEY);
  assert.equal(seen[0].init.redirect, 'manual');
});

test('another server\'s key (Master says caller partner): wrong_key', async () => {
  assert.equal(await checkMaster({ env, fetchImpl: stub(() => reply(200, { caller: 'partner' })).fetchImpl }), 'wrong_key');
});

test('401 / 403: wrong_key', async () => {
  assert.equal(await checkMaster({ env, fetchImpl: stub(() => reply(401, {})).fetchImpl }), 'wrong_key');
  assert.equal(await checkMaster({ env, fetchImpl: stub(() => reply(403, {})).fetchImpl }), 'wrong_key');
});

test('network error or 5xx: unreachable, and the error never carries the key', async () => {
  assert.equal(await checkMaster({ env, fetchImpl: stub(() => new TypeError(`connect failed ${KEY}`)).fetchImpl }), 'unreachable');
  assert.equal(await checkMaster({ env, fetchImpl: stub(() => reply(502, {})).fetchImpl }), 'unreachable');
  const error = await masterFetch('/x', { env, fetchImpl: stub(() => new TypeError(`connect failed ${KEY}`)).fetchImpl }).catch(e => e);
  assert.ok(error instanceof MasterError);
  assert.ok(!String(error.message).includes(KEY) && !JSON.stringify(error).includes(KEY));
});

test('a redirect is not followed', async () => {
  const { seen, fetchImpl } = stub(() => new Response(null, { status: 302, headers: { location: 'http://evil.example' } }));
  assert.equal(await checkMaster({ env, fetchImpl }), 'unreachable');
  assert.equal(seen.length, 1);
});

test('no URL or no key: not_configured, nothing sent', async () => {
  const { seen, fetchImpl } = stub(() => reply(200, { caller: 'pos' }));
  assert.equal(await checkMaster({ env: { INTERNAL_KEY_POS: KEY }, fetchImpl }), 'not_configured');
  assert.equal(await checkMaster({ env: { MASTER_SERVER_URL: 'http://localhost:8000' }, fetchImpl }), 'not_configured');
  assert.equal(seen.length, 0);
});

test('plain http to another host in production: not_configured', async () => {
  const { seen, fetchImpl } = stub(() => reply(200, { caller: 'pos' }));
  assert.equal(await checkMaster({ env: { ...env, MASTER_SERVER_URL: 'http://master.example.com', NODE_ENV: 'production' }, fetchImpl }), 'not_configured');
  assert.equal(seen.length, 0);
});

test('masterStatus remembers the answer for 30 s', async () => {
  resetMasterStatusCache();
  const { seen, fetchImpl } = stub(() => reply(200, { caller: 'pos' }));
  let t = 0;
  const now = () => t;
  assert.equal(await masterStatus({ env, fetchImpl, now }), 'ok');
  t = 29_000;
  assert.equal(await masterStatus({ env, fetchImpl, now }), 'ok');
  assert.equal(seen.length, 1);
  t = 31_000;
  await masterStatus({ env, fetchImpl, now });
  assert.equal(seen.length, 2);
  resetMasterStatusCache();
});
