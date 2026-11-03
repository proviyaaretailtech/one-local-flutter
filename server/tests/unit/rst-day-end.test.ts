import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';

const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);

test('Day end (0650): the count, confirm_open_bills and a note; reopen with a reason; both are money-rate', () => {
  assert.equal(lookup('rmoney_close_day')?.rate, 'money');
  assert.equal(lookup('rmoney_reopen_day')?.rate, 'money');
  assert.equal(lookup('rmoney__open_bills'), undefined, 'the helper is not reachable');
  assert.equal(parse('rmoney_close_day', { counted_minor: 50000 }).success, true);
  assert.equal(parse('rmoney_close_day', { counted_minor: 50000, confirm_open_bills: true, note: 'Table T7 still eating' }).success, true);
  assert.equal(parse('rmoney_close_day', { counted_minor: -5 }).success, false);
  assert.equal(parse('rmoney_close_day', { counted_minor: 50000, note: 'x'.repeat(201) }).success, false);
  assert.equal(parse('rmoney_reopen_day', { reason: 'Counted the float twice' }).success, true);
  assert.equal(parse('rmoney_reopen_day', { reason: 'no' }).success, false);
  assert.equal(parse('rmoney_reopen_day', {}).success, false);
});

test('Day end with bills still open reaches the app as 409 open_bills', () => {
  try {
    mapDbError({ message: 'MONEY_OPEN_BILLS: 3 bills are still open (₹735.00); settle them, or end the day with a note and they go to Revenue leakage' });
  } catch (e) {
    assert.ok(e instanceof HttpError);
    assert.equal((e as HttpError).status, 409);
    assert.equal((e as unknown as { code?: string }).code, 'open_bills');
    return;
  }
  assert.fail('not refused');
});
