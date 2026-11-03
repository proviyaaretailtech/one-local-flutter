import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);

test('restaurant Checkout (0649): a bill opens by its table, or a takeaway / delivery bill by its order, never both or neither', () => {
  const t = '6f1c2a34-5b6d-4e7f-8a9b-0c1d2e3f4a5b', o = '7a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';
  assert.equal(parse('rst_bill_view', { table_id: t }).success, true);
  assert.equal(parse('rst_bill_view', { order_id: o }).success, true);
  assert.equal(parse('rst_bill_view', { order_id: o, location_id: t }).success, true);
  assert.equal(parse('rst_bill_view', {}).success, false);
  assert.equal(parse('rst_bill_view', { table_id: t, order_id: o }).success, false);
  assert.equal(parse('rst_bill_view', { order_id: 'P-00001' }).success, false);
});
