// Store cash shift, payment pending and refund check (0500-0502): the gateway lists them, checks the request shape first, and maps the
// database's refusals to the right HTTP status. The rules themselves are tested in database/tests/500_store_shift_payments.sql.
import test from 'node:test';
import assert from 'node:assert/strict';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as sh from '../../src/schemas/shift.ts';

const ID = '50000000-0000-0000-0000-000000000001';

test('shift: every function is on the allowlist; money writes carry the idempotency key', () => {
  for (const a of ['pos_shift_current', 'pos_shift_list', 'pos_shift_open', 'pos_shift_cash_move', 'pos_shift_close', 'pos_shift_approve', 'pos_till_policy_set',
                   'pos_payment_start', 'pos_payment_confirm', 'pos_payment_fail', 'pos_payment_status', 'pos_refund_check']) {
    const e = lookup(a);
    assert.ok(e && e.kind === 'db' && e.fn === a, a);
  }
  for (const a of ['pos_shift_open', 'pos_shift_cash_move', 'pos_shift_close', 'pos_payment_start']) {
    const e = lookup(a); assert.ok(e && e.kind === 'db' && e.idem === true && e.rate === 'money', a);
  }
});

test('shift: request shapes', () => {
  assert.ok(sh.Open.safeParse({ opening_float: 0 }).success);
  assert.ok(!sh.Open.safeParse({ opening_float: -1 }).success);
  assert.ok(!sh.CashMove.safeParse({ shift_id: ID, kind: 'sideways', amount: 5, reason: 'abc' }).success);
  assert.ok(!sh.CashMove.safeParse({ shift_id: ID, kind: 'in', amount: 5, reason: 'x' }).success);
  assert.ok(sh.Close.safeParse({ shift_id: ID, counted_cash: 1250.5, variance_reason: 'Wrong change' }).success);
  assert.ok(!sh.PayStart.safeParse({ order_id: ID, method: 'cash' }).success, 'cash is never pending');
  assert.ok(!sh.PayConfirm.safeParse({ intent_id: ID, reference: 'ab' }).success);
  assert.ok(!sh.PayStatus.safeParse({}).success);
  assert.ok(sh.RefundCheck.safeParse({ order_id: ID, purpose: 'return' }).success);
});

test('shift: database refusals map to statuses', () => {
  const st = (m: string) => { try { mapDbError({ message: m }); } catch (e) { return (e as HttpError).status; } return 0; };
  assert.equal(st('POS_SHIFT_OPEN: a shift is already open'), 409);
  assert.equal(st('POS_NO_SHIFT: open the cash shift'), 409);
  assert.equal(st('POS_PAYMENT_PENDING: a payment on this bill is still waiting'), 409);
  assert.equal(st('POS_REASON_REQUIRED: give a reason'), 422);
  assert.equal(st('POS_NOT_ENOUGH_CASH: the drawer should hold only 5'), 422);
  assert.equal(st('POS_RETURN_WINDOW: paid 10 days ago'), 422);
});
