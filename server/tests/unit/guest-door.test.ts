import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { GUEST_DOOR, guestFunctions } from '../../src/guest-door.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as gst from '../../src/schemas/guest.ts';
import entry from '../../src/vercel.ts';

const post = (path: string, body: string, headers: Record<string, string> = {}) =>
  dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body }));
const get = (path: string) => dispatch(new Request(`http://x${path}`));
const code = 'a'.repeat(64), session = 'b'.repeat(64);
const line = { menu_item_id: '56000000-0000-0000-0000-0000000000f1', qty: 2 };

test('guest door: four names only, none of them reachable through /rpc', () => {
  assert.deepEqual(GUEST_DOOR.map(e => e.alias), ['open', 'menu', 'send', 'status']);
  assert.deepEqual(guestFunctions(), ['guest_qr_open', 'guest_menu', 'guest_order_send', 'guest_order_status']);
  for (const fn of guestFunctions()) assert.equal(lookup(fn), undefined, fn);
  assert.equal(lookup('tbl_qr_list')?.kind, 'db');
});

test('guest door: unknown name 404, GET 405, a bad body is 400 before the database', async () => {
  assert.equal((await post('/guest/nope', '{}', { 'x-ol-peer': '10.0.0.1' })).status, 404);
  assert.equal((await get('/guest/open')).status, 405);
  const r = await post('/guest/open', JSON.stringify({ code: 'not-hex' }), { 'x-ol-peer': '10.0.0.2' });
  assert.equal(r.status, 400);
  assert.equal(((await r.json()) as { code?: string }).code, 'validation');
  assert.equal((await post('/guest/open', JSON.stringify({ code, table_id: 'x' }), { 'x-ol-peer': '10.0.0.2' })).status, 400, 'extra keys are refused');
  assert.equal((await post('/guest/send', 'x'.repeat(20_000), { 'x-ol-peer': '10.0.0.2' })).status, 413);
});

test('guest door: limited per network address before the body is even read', async () => {
  const peer = { 'x-ol-peer': '10.9.9.9' };
  const codes: number[] = [];
  for (let i = 0; i < 31; i++) codes.push((await post('/guest/open', '{"code":"zz"}', peer)).status);
  assert.deepEqual([...new Set(codes.slice(0, 30))], [400]);
  assert.equal(codes[30], 429);
  assert.equal((await post('/guest/open', '{"code":"zz"}', { 'x-ol-peer': '10.9.9.8' })).status, 400, 'another address is not limited');
});

test('guest shapes: strict lines, quantities 1-20, up to 30 dishes, a request key', () => {
  assert.ok(gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: [line] }).success);
  assert.ok(!gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: [{ ...line, qty: 21 }] }).success);
  assert.ok(!gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: [{ ...line, qty: 1.5 }] }).success);
  assert.ok(!gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: [{ ...line, unit_price: 1 }] }).success, 'a guest cannot send a price');
  assert.ok(!gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: Array(31).fill(line) }).success);
  assert.ok(!gst.Send.safeParse({ session, lines: [line] }).success);
  assert.ok(!gst.Send.safeParse({ session, idempotency_key: 'k-12345678', lines: [line], table_id: line.menu_item_id }).success, 'no table from the guest');
  assert.ok(gst.QrIssue.safeParse({ table_id: line.menu_item_id, replace: true, confirm_label: 'T1' }).success);
});

test('guest errors map to a status and a code the page can act on', () => {
  const t = (message: string, status: number, code: string) =>
    assert.throws(() => mapDbError({ message }), (e: HttpError) => e.status === status && e.code === code, message);
  t('GUEST_RATE_LIMITED: too many', 429, 'rate_limited');
  t('GUEST_NOT_PUBLISHED: not yet', 409, 'not_published');
  t('GUEST_NOT_FOUND: not in use', 404, 'not_found');
  t('GUEST_ITEM_UNAVAILABLE: Dosa is not available', 409, 'item_unavailable');
  t('TBL_CONFIRM: type the table name T1', 422, 'confirm');
});

test('guest page: served from the build folder, any code path gets the page, no way out of the folder', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'guestweb-'));
  writeFileSync(join(dir, 'index.html'), '<html>guest</html>');
  writeFileSync(join(dir, 'main.dart.js'), 'console.log(1)');
  mkdirSync(join(dir, 'assets'));
  writeFileSync(join(dir, 'assets', 'a.json'), '{}');
  const before = process.env.GUEST_WEB_DIR;
  process.env.GUEST_WEB_DIR = dir;
  try {
    const page = await get(`/t/${code}`);
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type') ?? '', /text\/html/);
    assert.equal(page.headers.get('referrer-policy'), 'no-referrer', 'the code in the address never leaks to other sites');
    assert.equal(await page.text(), '<html>guest</html>');
    assert.match((await get('/t/main.dart.js')).headers.get('content-type') ?? '', /javascript/);
    assert.equal((await get('/t/assets/a.json')).status, 200);
    assert.equal((await get('/t/assets/missing.json')).status, 404);
    assert.equal((await get('/t/missing.js')).status, 404);
    assert.equal((await get('/t/..%2F..%2Fetc%2Fpasswd')).status, 404);
    assert.equal((await get('/t/assets/..%2F..%2Findex.html')).status, 404);
    assert.equal((await get('/t/.env')).status, 404);
  } finally {
    if (before === undefined) delete process.env.GUEST_WEB_DIR; else process.env.GUEST_WEB_DIR = before;
  }
  process.env.GUEST_WEB_DIR = join(dir, 'nothing-here');
  try { assert.equal((await get(`/t/${code}`)).status, 503); } finally { if (before === undefined) delete process.env.GUEST_WEB_DIR; else process.env.GUEST_WEB_DIR = before; }
});

test('vercel entry: a caller-sent x-ol-peer is dropped, the guest door still answers', async () => {
  assert.equal((await entry.fetch(new Request('https://x/guest/nope', { method: 'POST', body: '{}', headers: { 'x-ol-peer': '1.2.3.4' } }))).status, 404);
  assert.equal((await entry.fetch(new Request('https://x/guest/open', { method: 'POST', body: '{"code":"q"}', headers: { 'x-ol-peer': '1.2.3.4' } }))).status, 400);
});
