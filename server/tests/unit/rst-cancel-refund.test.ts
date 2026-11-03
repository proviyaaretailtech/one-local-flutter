import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean; data?: any } } }).args.safeParse(body);
const O = '55000000-0000-0000-0000-0000000000d1', I = '55000000-0000-0000-0000-0000000000e1';

test('cancel, refund and void (0640): seven functions listed; money ones idempotent; helpers unreachable', async () => {
  for (const [a, rate] of [['rst_items_cancel', 'write'], ['rst_bill_refund', 'money'], ['rst_bill_void', 'money'], ['rst_request_decide', 'money'],
    ['rst_requests_list', 'read'], ['rst_order_adjust', 'read'], ['rst_report_cancellations', 'read']] as const) assert.equal(lookup(a)?.rate, rate, a);
  for (const a of ['rst_items_cancel', 'rst_bill_refund', 'rst_bill_void']) assert.ok((lookup(a) as { idem?: boolean }).idem, a);
  for (const a of ['rst_adj__lock', 'rst_adj__cancel_apply', 'rst_adj__refund_apply', 'rst_adj__void_apply', 'rst_adj__ask', 'rst_adj__view', 'rst_adj__money', 'rst_adj__audit'])
    assert.equal(lookup(a), undefined, a);
  assert.equal((await post('/rpc/rst_bill_refund', JSON.stringify({ order_id: O, amount: 50, method: 'cash', reason: 'Cold' }))).status, 401);
});

test('cancel, refund and void: request shapes', () => {
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [{ item_id: I, qty: 2 }], reason: 'Added by mistake' }).success, true);
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [], reason: 'Added by mistake' }).success, false);
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [{ item_id: I, qty: 0 }], reason: 'Added by mistake' }).success, false);
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [{ item_id: I, qty: 1.5 }], reason: 'Added by mistake' }).success, false);
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [{ item_id: 'nope', qty: 1 }], reason: 'Added by mistake' }).success, false);
  assert.equal(parse('rst_items_cancel', { order_id: O, items: [{ item_id: I, qty: 1 }], reason: 'no' }).success, false);
  assert.equal(parse('rst_bill_refund', { order_id: O, amount: 50, method: 'upi', reason: 'Cold soup' }).success, true);
  assert.equal(parse('rst_bill_refund', { order_id: O, amount: 0, method: 'upi', reason: 'Cold soup' }).success, false);
  assert.equal(parse('rst_bill_refund', { order_id: O, amount: 50, method: 'cheque', reason: 'Cold soup' }).success, false);
  assert.equal(parse('rst_bill_refund', { order_id: O, amount: 50, method: 'cash' }).success, false);
  assert.equal(parse('rst_bill_void', { order_id: O, reason: 'Wrong table' }).success, true);
  assert.equal(parse('rst_bill_void', { order_id: O, reason: 'Wrong table', method: 'card' }).success, true);
  assert.equal(parse('rst_bill_void', { order_id: O, reason: 'x' }).success, false);
  assert.equal(parse('rst_request_decide', { request_id: I, decision: 'approve' }).success, true);
  assert.equal(parse('rst_request_decide', { request_id: I, decision: 'maybe' }).success, false);
  assert.equal(parse('rst_requests_list', {}).success, true);
  assert.equal(parse('rst_order_adjust', { order_id: O }).success, true);
});

test('cancel, refund and void: the database refusals reach the app with the right status', () => {
  const st = (m: string) => { try { mapDbError({ message: m }); } catch (e) { return e instanceof HttpError ? e.status : -1; } return 0; };
  assert.equal(st('POS_WRONG_STATE: Tikka is already cancelled'), 409);
  assert.equal(st('POS_FORBIDDEN: only a manager can approve this'), 403);
  assert.equal(st('POS_NOT_FOUND: order not found'), 404);
  assert.equal(st('POS_BAD_REQUEST: say why (3 to 200 characters)'), 400);
  assert.ok(st('POS_OVER_REFUND: at most 950.00 can be refunded on this bill') >= 400);
});
