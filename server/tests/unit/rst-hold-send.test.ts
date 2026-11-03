import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);
const O = '55000000-0000-0000-0000-0000000000d1';

test('send a held order to the kitchen (0643): a write, idempotent; helpers unreachable; sign-in needed', async () => {
  const e = lookup('rst_hold_send') as { rate: string; idem?: boolean };
  assert.equal(e.rate, 'write');
  assert.ok(e.idem);
  for (const a of ['pos_org_is_restaurant', 'pos_order_held_for_kitchen', 'tbl_kot_fire']) assert.equal(lookup(a), undefined, a);
  assert.equal(parse('rst_hold_send', { order_id: O }).success, true);
  assert.equal(parse('rst_hold_send', { order_id: 'nope' }).success, false);
  assert.equal((await post('/rpc/rst_hold_send', JSON.stringify({ order_id: O }))).status, 401);
});
