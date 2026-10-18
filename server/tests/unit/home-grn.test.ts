// Unit tests that need no database: the control centre's "Goods received today" figure counts receipts posted into stock (section H/G),
// not only the old device app's pos_goods_receipts, and never shows a partial amount as the whole.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { goodsReceived } from '../../src/modules/home.ts';

test('posted receipts count, valued at accepted units x the cost recorded at receiving', () => {
  const lines = [{ id: 'l1', qty: '10', rejected_qty: '2' }, { id: 'l2', qty: 3, rejected_qty: 0 }];
  const costs = [{ line_id: 'l1', unit_cost_minor: 2500 }, { line_id: 'l2', unit_cost_minor: '1000' }];
  assert.deepEqual(goodsReceived([], 1, lines, costs), { bills: 1, amount: 230 });   // 8 x 25 + 3 x 10
});

test('old device receipts and posted receipts add up', () => {
  assert.deepEqual(goodsReceived([{ total: 99.5 }], 1, [{ id: 'l1', qty: 1, rejected_qty: 0 }], [{ line_id: 'l1', unit_cost_minor: 50 }]), { bills: 2, amount: 100 });
});

test('a posted line with no recorded cost makes the amount unknown, not smaller', () => {
  assert.deepEqual(goodsReceived([{ total: 10 }], 1, [{ id: 'l1', qty: 4, rejected_qty: 0 }], []), { bills: 2, amount: null });
});

test('fully rejected lines need no cost; nothing received is zero, not null', () => {
  assert.deepEqual(goodsReceived([], 1, [{ id: 'l1', qty: 5, rejected_qty: 5 }], []), { bills: 1, amount: 0 });
  assert.deepEqual(goodsReceived([], 0, [], []), { bills: 0, amount: 0 });
});
