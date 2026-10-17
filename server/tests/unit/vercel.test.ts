import test from 'node:test';
import assert from 'node:assert/strict';
import entry from '../../src/vercel.ts';

test('vercel entry: same router; health shows version and db state without secrets', async () => {
  const r = await entry.fetch(new Request('https://x/health'));
  const j = await r.json() as Record<string, unknown>;
  assert.equal(r.status, 200);
  assert.equal(j.ok, true);
  assert.match(String(j.version), /^0\.1\.0/);
  assert.ok(j.db === 'reachable' || j.db === 'unreachable');
  assert.deepEqual(Object.keys(j).sort(), ['db', 'ok', 'version']);
  assert.equal(r.headers.get('cache-control'), 'no-store');
});

test('vercel entry: gateway door answers like the local server, CORS off by default', async () => {
  assert.equal((await entry.fetch(new Request('https://x/rpc/not_listed', { method: 'POST', body: '{}', headers: { origin: 'https://evil.test' } }))).status, 404);
  const r = await entry.fetch(new Request('https://x/rpc/pos_order_view', { method: 'POST', body: '{}', headers: { origin: 'https://evil.test' } }));
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('access-control-allow-origin'), null);
  assert.equal((await entry.fetch(new Request('https://x/rpc/pos_order_view', { method: 'POST', body: 'x'.repeat(70_000), headers: { authorization: 'Bearer ' + 'a'.repeat(30) } }))).status, 401);
});
