import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);
const R = '55000000-0000-0000-0000-0000000000a1', T = '55000000-0000-0000-0000-0000000000c1';

test('reservations (0642): list is a read, seat a write; helpers unreachable; sign-in needed', async () => {
  assert.equal(lookup('tbl_reservations_list')?.rate, 'read');
  assert.equal(lookup('tbl_reserve_seat')?.rate, 'write');
  assert.equal(lookup('tbl_reserve_cancel')?.rate, 'write');
  for (const a of ['tbl__reservation_can', 'tbl_reservation_json', 'orders_seat_reservation']) assert.equal(lookup(a), undefined, a);
  assert.equal((await post('/rpc/tbl_reserve_seat', JSON.stringify({ id: R }))).status, 401);
});

test('reservations: request shapes', () => {
  assert.equal(parse('tbl_reservations_list', {}).success, true);
  assert.equal(parse('tbl_reservations_list', { date: '2026-11-03', status: 'no_show' }).success, true);
  assert.equal(parse('tbl_reservations_list', { date: '3 Nov' }).success, false);
  assert.equal(parse('tbl_reservations_list', { status: 'late' }).success, false);
  assert.equal(parse('tbl_reserve_seat', { id: R }).success, true);
  assert.equal(parse('tbl_reserve_seat', { id: R, table_id: T }).success, true);
  assert.equal(parse('tbl_reserve_seat', { id: 'nope' }).success, false);
  assert.equal(parse('tbl_reserve_cancel', { id: R, outcome: 'no_show', reason: 'Did not answer' }).success, true);
  assert.equal(parse('tbl_reserve_cancel', { id: R, reason: 'x'.repeat(201) }).success, false);
  assert.equal(parse('tbl_reserve_cancel', { id: R, outcome: 'cancel' }).success, false);
});
