// Unit tests that need no database: section G error mapping and id checks.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dbFail, needUuid } from '../../src/modules/pos_db.ts';
import { HttpError } from '../../src/http.ts';

const status = (message: string, code?: string) => {
  try { dbFail({ message, code }); } catch (e) { return e instanceof HttpError ? [e.status, e.message, (e as any).code] : [0]; }
  return [];
};

test('database prefixes become HTTP statuses with a sentence', () => {
  assert.deepEqual(status('POS_TAX_REQUIRED: complete the HSN and GST rate'), [422, 'Complete the HSN and GST rate.', 'tax_required']);
  assert.equal(status('POS_STALE: this item was changed on another device')[0], 409);
  assert.equal(status('POS_DUPLICATE: another item already uses SKU A')[0], 409);
  assert.equal(status('GRN_UNRESOLVED: resolve the exceptions')[0], 422);
  assert.equal(status('GRN_NOT_APPROVED: x')[0], 409);
  assert.equal(status('INV_FORBIDDEN: your role cannot change stock')[0], 403);
  assert.equal(status('GRN_NOT_FOUND: receipt not found')[0], 404);
});

test('permission errors are 403; anything unknown is a plain 500 that leaks nothing', () => {
  assert.equal(status('permission denied for function x', '42501')[0], 403);
  const [s, m] = status('relation "secret_table" does not exist for org 123');
  assert.equal(s, 500); assert.ok(!String(m).includes('secret_table'));
});

test('ids must be uuids', () => {
  assert.equal(needUuid('0b7e8e2e-8f4c-4f0a-9d54-4f9d6f0f0a11', 'Item'), '0b7e8e2e-8f4c-4f0a-9d54-4f9d6f0f0a11');
  assert.throws(() => needUuid('nope', 'Item'), (e: any) => e.status === 404);
});
