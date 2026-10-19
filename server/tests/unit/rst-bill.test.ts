import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean; data?: any } } }).args.safeParse(body);
const O = '55000000-0000-0000-0000-0000000000d1', T = '55000000-0000-0000-0000-0000000000c1';

test('restaurant bill and pay (0550): seven functions listed; pay is money and idempotent, split idempotent, helpers unreachable', async () => {
  assert.equal(lookup('rst_bill_view')?.rate, 'read');
  assert.equal(lookup('rst_receipt_view')?.rate, 'read');
  const pay = lookup('rst_bill_pay') as { rate: string; idem?: boolean };
  assert.equal(pay.rate, 'money');
  assert.ok(pay.idem);
  assert.ok((lookup('rst_bill_split') as { idem?: boolean }).idem);
  for (const a of ['rst_bill_coupon', 'rst_bill_note', 'rst_receipt_log']) assert.equal(lookup(a)?.rate, 'write', a);
  for (const a of ['rst_bill_lock', 'rst_can_pay', 'rst_pay_result', 'rst_bill_order_json', 'rst_split_json', 'rst_paid']) assert.equal(lookup(a), undefined, a);
  assert.equal((await post('/rpc/rst_bill_pay', JSON.stringify({ order_id: O, method: 'cash' }))).status, 401);
});

test('restaurant bill and pay: request shapes', () => {
  assert.equal(parse('rst_bill_view', { table_id: T }).success, true);
  assert.equal(parse('rst_bill_view', {}).success, false);
  assert.equal(parse('rst_bill_split', { order_id: O, mode: 'equal', guests: 3 }).success, true);
  assert.equal(parse('rst_bill_split', { order_id: O, mode: 'equal', guests: 1 }).success, false);
  assert.equal(parse('rst_bill_split', { order_id: O, mode: 'halves' }).success, false);
  assert.equal(parse('rst_bill_split', { order_id: O, mode: 'item', parts: [{ item_ids: [T] }, { item_ids: ['nope'] }] }).success, false);
  assert.equal(parse('rst_bill_split', { order_id: O, mode: 'amount', parts: [{ amount: 500, method: 'upi' }, { amount: -1 }] }).success, false);
  assert.equal(parse('rst_bill_pay', { order_id: O, method: 'cash', tendered: 700 }).success, true);
  assert.equal(parse('rst_bill_pay', { order_id: O, method: 'cheque' }).success, false);
  assert.equal(parse('rst_bill_pay', { order_id: O, method: 'cash', tendered: 0 }).success, false);
  assert.equal(parse('rst_bill_coupon', { order_id: O, code: 'DINE10' }).success, true);
  assert.equal(parse('rst_bill_coupon', { order_id: O, code: 'x' }).success, false);
  assert.equal(parse('rst_bill_note', { order_id: O, note: 'x'.repeat(301) }).success, false);
  assert.equal(parse('rst_receipt_log', { order_id: O, channel: 'fax' }).success, false);
  assert.equal(parse('rst_receipt_log', { order_id: O, channel: 'whatsapp', to: '+91 98765 43210' }).success, true);
});

test('restaurant bill and pay: the database refusals reach the app with the right status', () => {
  const st = (m: string) => { try { mapDbError({ message: m }); } catch (e) { return e instanceof HttpError ? e.status : -1; } return 0; };
  assert.equal(st('POS_WRONG_STATE: Asha has already paid'), 409);
  assert.equal(st('POS_STALE: the bill changed after it was split; split it again'), 409);
  assert.equal(st('POS_UNDERPAID: enter at least 420 received'), 422);
  assert.equal(st('POS_NOT_FOUND: bill not found'), 404);
  assert.equal(st('POS_FORBIDDEN: your role cannot take payments'), 403);
  assert.equal(st('POS_COUPON_UNKNOWN: this coupon code is not valid'), 422);
});
