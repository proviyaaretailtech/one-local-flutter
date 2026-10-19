// Orders tab (0530-0531): the gateway lists the board, the hold list and resume; shapes are checked before the database sees them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { lookup } from '../../src/rpc-manifest.ts';
import { parse } from '../../src/validate.ts';
import * as ord from '../../src/schemas/orders.ts';
import { HttpError } from '../../src/http.ts';

const ID = '11111111-2222-4333-8444-555555555555';
const refused = (schema: Parameters<typeof parse>[0], raw: unknown, message: RegExp) =>
  assert.throws(() => parse(schema, raw), (e: HttpError) => e.status === 400 && message.test(e.message));

test('manifest: the Orders tab functions are listed, resume is a write with an idempotency key, nothing else new', () => {
  const board = lookup('pos_orders_board'), list = lookup('pos_hold_list'), upd = lookup('pos_hold_update');
  assert.equal(board?.kind, 'db'); assert.equal(board?.rate, 'read');
  assert.equal(list?.kind, 'db'); assert.equal(list?.rate, 'read');
  assert.equal(upd?.kind, 'db'); assert.equal(upd?.rate, 'write');
  assert.equal(upd?.kind === 'db' && upd.idem, true);
  assert.equal(lookup('pos_hold__open'), undefined);
  assert.equal(lookup('pos_order_items_text'), undefined);
  assert.equal(lookup('pos_hold_place'), undefined);   // reached through POST /pos-orders/hold only
});

test('board and hold list: channel and status are checked, extra keys kept', () => {
  assert.deepEqual(parse(ord.Board, { channel: 'zomato', status: 'dispatched', q: 'Aarav' }), { channel: 'zomato', status: 'dispatched', q: 'Aarav' });
  refused(ord.Board, { channel: 'ondc' }, /Unknown channel/);
  refused(ord.Board, { status: 'lost' }, /Unknown status/);
  refused(ord.HoldList, { q: 'x'.repeat(61) }, /60 characters/);
  refused(ord.HoldList, { location_id: 'nope' }, /valid id/);
  assert.equal(parse(ord.HoldList, {}).channel, undefined);
});

test('resume: needs the order, the version it resumed, 1-50 lines of 1-99, a short reason', () => {
  const ok = parse(ord.HoldUpdate, { order_id: ID, expected_updated_at: '2026-10-20T10:00:00.123+00:00', lines: [{ menu_item_id: ID, qty: 2 }], reason: ' Mains added ' });
  assert.equal(ok.reason, 'Mains added');
  refused(ord.HoldUpdate, { order_id: ID, lines: [{ menu_item_id: ID, qty: 1 }] }, /Refresh the held bill/);
  refused(ord.HoldUpdate, { order_id: ID, expected_updated_at: '2026-10-20T10:00:00Z', lines: [] }, /between 1 and 50/);
  refused(ord.HoldUpdate, { order_id: ID, expected_updated_at: '2026-10-20T10:00:00Z', lines: [{ menu_item_id: ID, qty: 100 }] }, /1 to 99/);
  refused(ord.HoldUpdate, { order_id: ID, expected_updated_at: '2026-10-20T10:00:00Z', reason: 'x'.repeat(201) }, /under 200/);
  refused(ord.HoldUpdate, { order_id: 'x', expected_updated_at: '2026-10-20T10:00:00Z' }, /valid id/);
});
