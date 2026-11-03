import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);

test('payment reference (0648): a delivery collected at the door by card or UPI carries its reference number', () => {
  const at = { order_id: '6f1c2a34-5b6d-4e7f-8a9b-0c1d2e3f4a5b', step: 'delivered', payment_method: 'upi' };
  assert.equal(parse('rst_channel_delivery', at).success, true, 'no reference: the database says what is missing');
  assert.equal(parse('rst_channel_delivery', { ...at, reference: 'UTR998877' }).success, true);
  assert.equal(parse('rst_channel_delivery', { ...at, reference: null }).success, true);
  assert.equal(parse('rst_channel_delivery', { ...at, reference: 'x'.repeat(61) }).success, false);
  assert.equal(parse('rst_bill_pay', { order_id: at.order_id, method: 'card', reference: '4821' }).success, true);
});

test('split (0648 screens): equally between guests, and by dish with each guest\'s dishes', () => {
  const o = '6f1c2a34-5b6d-4e7f-8a9b-0c1d2e3f4a5b', i = '7a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';
  assert.equal(parse('rst_bill_split', { order_id: o, mode: 'equal', guests: 3, parts: [] }).success, true);
  assert.equal(parse('rst_bill_split', { order_id: o, mode: 'item', parts: [{ label: 'Guest 1', item_ids: [i] }, { label: 'Guest 2', item_ids: [i] }] }).success, true);
});
