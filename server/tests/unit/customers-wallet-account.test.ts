// Customers, One Local Wallet and Manage account on the gateway (database: 0510-0512).
import test from 'node:test';
import assert from 'node:assert/strict';
import { lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as cu from '../../src/schemas/customers.ts';

const ID = '51000000-0000-0000-0000-0000000000d1';

test('every function is listed as a db entry; reads are "read", writes are "write"; none uses the service role', () => {
  const reads = ['cust_list', 'cust_lookup', 'cust_view', 'wallet_overview', 'wallet_movements', 'wallet_settlement_view', 'acct_get'];
  const writes = ['cust_save', 'cust_attach_order', 'acct_save_name', 'acct_sync_contact', 'acct_signed_out_everywhere'];
  for (const a of [...reads, ...writes]) {
    const e = lookup(a);
    assert.ok(e, a);
    assert.equal(e!.kind, 'db', a);
    assert.equal(e!.rate, reads.includes(a) ? 'read' : 'write', a);
  }
});

test('S5.5 attach: a customer or walk-in, never both, never neither', () => {
  assert.ok(cu.Attach.safeParse({ order_id: ID, customer_id: ID }).success);
  assert.ok(cu.Attach.safeParse({ order_id: ID, walk_in: true }).success);
  assert.ok(!cu.Attach.safeParse({ order_id: ID }).success);
  assert.ok(!cu.Attach.safeParse({ order_id: ID, customer_id: ID, walk_in: true }).success);
  assert.ok(!cu.Attach.safeParse({ order_id: 'nope', walk_in: true }).success);
});

test('customer form: name and phone required, dates as YYYY-MM-DD, extra keys kept for the database', () => {
  const ok = cu.Save.safeParse({ first_name: 'Asha', phone: '+91 98765 43210', date_of_birth: '1990-05-01', extra: 1 });
  assert.ok(ok.success);
  assert.equal((ok.data as Record<string, unknown>).extra, 1);
  assert.ok(!cu.Save.safeParse({ first_name: '', phone: '9876543210' }).success);
  assert.ok(!cu.Save.safeParse({ first_name: 'A', phone: '123' }).success);
  assert.ok(!cu.Save.safeParse({ first_name: 'A', phone: '9876543210', date_of_birth: '01/05/1990' }).success);
  assert.ok(!cu.SaveName.safeParse({ name: ' x ' }).success);
});

test('CUST_, WALLET_ and ACCT_ errors map to statuses', () => {
  const t = (message: string, status: number) => assert.throws(() => mapDbError({ message }), (e: HttpError) => e.status === status, message);
  t('CUST_FORBIDDEN: your role cannot look up customers', 403);
  t('CUST_NOT_FOUND: customer not found', 404);
  t('CUST_DUPLICATE: another customer already has this mobile number', 409);
  t('CUST_WRONG_STATE: an online order keeps the customer who placed it', 409);
  t('WALLET_FORBIDDEN: only the owner and finance roles can see the One Local Wallet', 403);
  t('ACCT_BAD_REQUEST: enter your full name', 400);
});
