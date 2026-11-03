import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);

test('admin PIN (0645): set and check are rate-limited as secure; helpers unreachable; sign-in needed', async () => {
  assert.equal(lookup('rst_admin_pin_set')?.rate, 'secure');
  assert.equal(lookup('rst_admin_pin_check')?.rate, 'secure');
  assert.equal(lookup('rst_admin_pin_status')?.rate, 'read');
  for (const a of ['rst_admin__consume', 'rst_admin__guard', 'rst_admin__is_admin']) assert.equal(lookup(a), undefined, a);
  assert.equal(parse('rst_admin_pin_set', { pin: '482915' }).success, true);
  assert.equal(parse('rst_admin_pin_set', { pin: '4829' }).success, false);
  assert.equal(parse('rst_admin_pin_set', { pin: '48291a' }).success, false);
  assert.equal(parse('rst_admin_pin_set', { pin: '482915', extra: 1 }).success, false);
  assert.equal(parse('rst_admin_pin_check', { pin: '482915' }).success, true);
  assert.equal((await post('/rpc/rst_admin_pin_check', JSON.stringify({ pin: '482915' }))).status, 401);
});

test('admin PIN: "needed" reaches the app as 403 admin_pin_required; too many tries as 429', () => {
  const st = (m: string) => { try { mapDbError({ message: m }); } catch (e) { return e instanceof HttpError ? [e.status, (e as unknown as { code?: string }).code] : [-1]; } return [0]; };
  assert.deepEqual(st('POS_ADMIN_PIN: this bill is generated, so it can only be changed with an admin PIN; enter an admin PIN and a note'), [403, 'admin_pin_required']);
  assert.equal(st('POS_RATE_LIMITED: too many wrong PINs; try again in 15 minutes')[0], 429);
});
