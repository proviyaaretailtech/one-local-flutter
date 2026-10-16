import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { dbFunctions, lookup, MANIFEST } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as ob from '../../src/schemas/onboarding.ts';

const post = (path: string, body = '{}', headers: Record<string, string> = {}) =>
  dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body }));

test('manifest: unique aliases, every secure entry has a handler, every db entry names a function', () => {
  const aliases = MANIFEST.map(e => e.alias);
  assert.equal(new Set(aliases).size, aliases.length);
  for (const e of MANIFEST) {
    assert.match(e.alias, /^[a-z][a-z0-9_]{1,63}$/);
    if (e.kind === 'secure') assert.equal(typeof e.handler, 'function', e.alias);
    if (e.kind === 'db') assert.match(e.fn, /^[a-z][a-z0-9_]+$/, e.alias);
  }
});

test('manifest: nothing that takes a user id, runs SQL or opens a table is listed', () => {
  for (const fn of dbFunctions()) assert.ok(!/^(exec|sql|pg_|ol_partner_act$|partner_(app|setup)_(?!.*gw_))/.test(fn) || fn.startsWith('gw_'), fn);
  assert.equal(lookup('orders'), undefined);
  assert.equal(lookup('ol_partner_act'), undefined);
  assert.equal(lookup('partner_app_get')?.alias, 'partner_app_get');
});

test('the door: unknown name is 404 even without a token; a known name without a token is 401; GET is 405', async () => {
  assert.equal((await post('/rpc/not_listed')).status, 404);
  assert.equal((await post('/rpc/pos_order_view')).status, 401);
  assert.equal((await post('/rpc/pos_order_view', '{}', { authorization: 'Bearer short' })).status, 401);
  assert.equal((await dispatch(new Request('http://x/rpc/pos_order_view'))).status, 405);
  assert.equal((await post('/rpc', '{}')).status, 401);
});

test('database error prefixes of every family map to a status and a code', () => {
  const t = (message: string, status: number, code: string) =>
    assert.throws(() => mapDbError({ message }), (e: HttpError) => e.status === status && e.code === code, message);
  t('POS_STALE: changed', 409, 'version_conflict');
  t('POS_FORBIDDEN: your role cannot move orders', 403, 'forbidden');
  t('POS_UNDERPAID: short', 422, 'underpaid');
  t('GRN_NOT_FOUND: nope', 404, 'not_found');
  t('INV_FROZEN: x', 409, 'wrong_state');
  t('OL_BAD_REQUEST: x', 400, 'bad_request');
  assert.throws(() => mapDbError({ message: 'new row violates row-level security policy', code: '42501' }), (e: HttpError) => e.status === 403);
  assert.throws(() => mapDbError({ message: 'PLAN_LIMIT: x' }), (e: HttpError) => e.status === 500);
});

test('profile arguments are checked against the lists', () => {
  const base = { partner_type: 'restaurant' as const, business_name: 'Cafe One', owner_name: 'Asha Rao', phone: '98765 43210', selling_mode: 'physical' as const };
  const ok = ob.profileArgs(ob.Profile.parse({ ...base, category: 'Indian' }));
  assert.equal(ok.phone, '9876543210');
  assert.deepEqual(ok.subcategories, ['Indian']);
  assert.throws(() => ob.profileArgs(ob.Profile.parse({ ...base, category: 'Not a type' })), (e: HttpError) => e.status === 400);
});
