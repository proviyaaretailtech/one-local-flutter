// Unit tests that need no database: the router, the error shape, the body cap, the rate limit, log redaction.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { add, dispatch } from '../../src/router.ts';
import { HttpError, json, limit, readBody, redact } from '../../src/http.ts';
import { mapDbError } from '../../src/db.ts';

add('GET', '/t/:id/x', (_r, p) => json({ id: p.id }));
add('POST', '/t/:id/x', () => { throw new HttpError(409, 'Already done.', undefined, 'wrong_state'); });
add('GET', '/t/boom', () => { throw new Error('secret=eyJabcdefgh.ijklmnopq.rstuvwxyz'); });
const req = (method: string, path: string, init: RequestInit = {}) => dispatch(new Request(`http://x${path}`, { method, ...init }));

test('params are decoded and matched by method', async () => {
  const r = await req('GET', '/t/a%20b/x');
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { id: 'a b' });
});
test('unknown path is 404, known path with another method is 405, both as {detail}', async () => {
  assert.deepEqual(await (await req('GET', '/nope')).json(), { detail: 'Not found' });
  assert.equal((await req('DELETE', '/t/1/x')).status, 405);
});
test('HttpError becomes {detail, code}; other errors become a plain 500 without the message', async () => {
  const a = await req('POST', '/t/1/x');
  assert.equal(a.status, 409);
  assert.deepEqual(await a.json(), { detail: 'Already done.', code: 'wrong_state' });
  const b = await req('GET', '/t/boom');
  assert.equal(b.status, 500);
  assert.deepEqual(await b.json(), { detail: 'Something went wrong. Please try again.' });
});
test('body: must be a JSON object, and is refused over the size cap', async () => {
  const post = (body: string) => new Request('http://x/', { method: 'POST', body });
  assert.deepEqual(await readBody(post('{"a":1}')), { a: 1 });
  await assert.rejects(readBody(post('[1]')), (e: HttpError) => e.status === 400);
  await assert.rejects(readBody(post('{"a":"' + 'x'.repeat(200) + '"}'), 100), (e: HttpError) => e.status === 413);
});
test('rate limit answers 429 with Retry-After after the cap', () => {
  for (let i = 0; i < 3; i++) limit('u1', 'unit', 3, 60_000);
  assert.throws(() => limit('u1', 'unit', 3, 60_000), (e: HttpError) => e.status === 429 && Number(e.headers?.['Retry-After']) > 0);
  limit('u2', 'unit', 3, 60_000); // another subject is unaffected
});
test('log redaction hides tokens and keys', () => {
  const out = redact('Bearer abcdefghijklmnop1234 and eyJabcdefgh.ijklmnopq.rstuvwxyz and ?apikey=SECRET1');
  assert.ok(!/abcdefghijklmnop1234|ijklmnopq|SECRET1/.test(out), out);
});
test('database OL_* errors map to a status and a code; unknown errors become a plain 500', () => {
  assert.throws(() => mapDbError({ message: 'OL_STALE: this order was already changed' }), (e: HttpError) => e.status === 409 && e.code === 'version_conflict' && e.detail === 'this order was already changed');
  assert.throws(() => mapDbError({ message: 'OL_NOT_FOUND: nope' }), (e: HttpError) => e.status === 404);
  assert.throws(() => mapDbError({ message: 'relation "x" does not exist', code: '42P01' }), (e: HttpError) => e.status === 500 && !/relation/.test(e.detail));
});
