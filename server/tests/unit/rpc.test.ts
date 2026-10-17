import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { dbFunctions, lookup, MANIFEST } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as ob from '../../src/schemas/onboarding.ts';

const post = (path: string, body = '{}', headers: Record<string, string> = {}) =>
  dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body }));

test('manifest: unique aliases, every secure entry has a handler, every db entry names a function', () => {
  const aliases = MANIFEST.map(e => e.alias);
  assert.equal(new Set(aliases).size, aliases.length);
  for (const e of MANIFEST) {
    assert.match(e.alias, /^[a-z][a-z0-9_]{1,63}$/);
    if (e.kind === 'secure') assert.equal(typeof e.handler, 'function', e.alias);
    if (e.kind === 'db') assert.match(e.fn, /^[a-z][a-z0-9_]+$/, e.alias);
  }
});

test('manifest: nothing that takes a user id, runs SQL or opens a table is listed', () => {
  for (const fn of dbFunctions()) assert.ok(!/^(exec|sql|pg_|ol_partner_act$|partner_(app|setup)_(?!.*gw_))/.test(fn) || fn.startsWith('gw_'), fn);
  assert.equal(lookup('orders'), undefined);
  assert.equal(lookup('ol_partner_act'), undefined);
  assert.equal(lookup('partner_app_get')?.alias, 'partner_app_get');
});

test('the door: unknown name is 404 even without a token; a known name without a token is 401; GET is 405', async () => {
  assert.equal((await post('/rpc/not_listed')).status, 404);
  assert.equal((await post('/rpc/pos_order_view')).status, 401);
  assert.equal((await post('/rpc/pos_order_view', '{}', { authorization: 'Bearer short' })).status, 401);
  assert.equal((await dispatch(new Request('http://x/rpc/pos_order_view'))).status, 405);
  assert.equal((await post('/rpc', '{}')).status, 401);
});

test('database error prefixes of every family map to a status and a code', () => {
  const t = (message: string, status: number, code: string) =>
    assert.throws(() => mapDbError({ message }), (e: HttpError) => e.status === status && e.code === code, message);
  t('POS_STALE: changed', 409, 'version_conflict');
  t('POS_FORBIDDEN: your role cannot move orders', 403, 'forbidden');
  t('POS_UNDERPAID: short', 422, 'underpaid');
  t('GRN_NOT_FOUND: nope', 404, 'not_found');
  t('INV_FROZEN: x', 409, 'wrong_state');
  t('INV_SHORT: only 3 left', 409, 'short');
  t('INV_CAPACITY: bin full', 422, 'capacity');
  t('INV_STALE: changed', 409, 'version_conflict');
  t('OL_BAD_REQUEST: x', 400, 'bad_request');
  assert.throws(() => mapDbError({ message: 'new row violates row-level security policy', code: '42501' }), (e: HttpError) => e.status === 403);
  assert.throws(() => mapDbError({ message: 'PLAN_LIMIT: x' }), (e: HttpError) => e.status === 500);
});

test('profile arguments are checked against the lists', () => {
  const base = { partner_type: 'restaurant' as const, business_name: 'Cafe One', owner_name: 'Asha Rao', phone: '98765 43210', selling_mode: 'physical' as const };
  const ok = ob.profileArgs(ob.Profile.parse({ ...base, category: 'Indian' }));
  assert.equal(ok.phone, '9876543210');
  assert.deepEqual(ok.subcategories, ['Indian']);
  assert.throws(() => ob.profileArgs(ob.Profile.parse({ ...base, category: 'Not a type' })), (e: HttpError) => e.status === 400);
});

test('inventory (section H): every function is listed, reads are "read", writes carry the Idempotency-Key, shapes are checked', async () => {
  const reads = ['inv_options', 'inv_dashboard', 'inv_stock_list', 'inv_stock_detail', 'inv_movement_list', 'inv_movement_detail', 'inv_document_list', 'inv_document_view', 'inv_forecast'];
  const writes = ['inv_document_save', 'inv_document_act', 'inv_audit_to_adjustment'];
  for (const a of reads) assert.equal(lookup(a)?.rate, 'read', a);
  for (const a of writes) { const e = lookup(a); assert.ok(e && e.kind === 'db' && e.idem && e.rate === 'write', a); }
  for (const a of [...reads, ...writes]) assert.equal(lookup(a)?.kind, 'db', a);
  assert.equal(lookup('inv_post_movement'), undefined);       // service-only helpers are not reachable
  assert.equal(lookup('inv_item_stats'), undefined);
  assert.equal((await post('/rpc/inv_dashboard')).status, 401);
  const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean; data?: any } } }).args.safeParse(body);
  assert.equal(parse('inv_document_act', { id: 'not-an-id', action: 'submit', version: 1 }).success, false);
  assert.equal(parse('inv_document_act', { id: '40000000-0000-0000-0000-0000000000a1', action: 'submit' }).success, false);
  assert.equal(parse('inv_stock_list', { filter: 'everything' }).success, false);
  assert.equal(parse('inv_stock_list', { page_size: 500 }).success, false);
  const keep = parse('inv_document_save', { doc_type: 'receipt', title: 'x', lines: [{ inventory_item_id: 'a', qty: 1 }] });
  assert.ok(keep.success && keep.data.title === 'x' && keep.data.lines.length === 1);   // fields the schema does not name still reach the database
});

test('purchasing (section H): eight functions listed, reads are "read", writes carry the Idempotency-Key where they create, shapes are checked', async () => {
  const reads = ['pur_options', 'pur_po_list', 'pur_po_view', 'pur_price_view'];
  const writes = ['pur_po_create', 'pur_po_receive', 'pur_sourcing_select', 'pur_audit_record'];
  for (const a of reads) assert.equal(lookup(a)?.rate, 'read', a);
  for (const a of writes) { const e = lookup(a); assert.ok(e && e.kind === 'db' && e.rate === 'write', a); }
  for (const a of ['pur_po_create', 'pur_po_receive', 'pur_sourcing_select']) assert.ok((lookup(a) as { idem?: boolean }).idem, a);
  assert.equal(lookup('pur_po_json'), undefined);               // service-only helpers are not reachable
  assert.equal(lookup('purchasing_receipt_posted'), undefined);
  assert.equal((await post('/rpc/pur_po_list')).status, 401);
  const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean; data?: any } } }).args.safeParse(body);
  const line = { inventory_item_id: '40000000-0000-0000-0000-0000000000a1', qty: 10, unit_cost_minor: 36000, gst_pct: 5 };
  assert.equal(parse('pur_po_create', { supplier_id: 'abc', lines: [line] }).success, true);
  assert.equal(parse('pur_po_create', { supplier_id: 'abc', lines: [] }).success, false);
  assert.equal(parse('pur_po_create', { supplier_id: '', lines: [line] }).success, false);
  assert.equal(parse('pur_po_create', { supplier_id: 'abc', lines: [{ ...line, qty: 0 }] }).success, false);
  assert.equal(parse('pur_po_create', { supplier_id: 'abc', lines: [{ ...line, unit_cost_minor: 1.5 }] }).success, false);
  assert.equal(parse('pur_po_create', { supplier_id: 'abc', lines: [{ ...line, gst_pct: 101 }] }).success, false);
  assert.equal(parse('pur_po_view', {}).success, false);
  assert.equal(parse('pur_po_list', { status: 'weird' }).success, false);
  assert.equal(parse('pur_audit_record', { price_id: '40000000-0000-0000-0000-0000000000a1', checks: [{ name: 'x', result: 'maybe' }] }).success, false);
  assert.equal(parse('pur_audit_record', { price_id: '40000000-0000-0000-0000-0000000000a1', checks: [{ name: 'Temp', result: 'fail', detail: '8.1C' }] }).success, true);
  const keep = parse('pur_po_create', { supplier_id: 'abc', notes: 'n', lines: [{ ...line, extra: 1 }] });
  assert.ok(keep.success && keep.data.lines[0].extra === 1);
});
