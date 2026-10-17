// Unit tests that need no database: section G on the /rpc gateway (manifest entries, request shapes, error mapping).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { dbFunctions, lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as cat from '../../src/schemas/catalogue.ts';
import * as grn from '../../src/schemas/grn.ts';

const APP = ['cat_item_list', 'cat_item_view', 'cat_item_lookup', 'cat_item_save', 'grn_list', 'grn_view', 'grn_matching_view', 'grn_open',
  'grn_invoice_save', 'grn_costs_save', 'grn_resolve', 'grn_request_approval', 'grn_decide'];
const HELPERS = ['cat_stock_map', 'cat_location', 'cat_item_json', 'cat_menu_rules_check', 'grn_rows', 'grn_totals', 'grn_signature', 'grn_person',
  'grn_receipt', 'grn_post_gate', 'grn_receipt_cancelled', 'grn_reviews_guard', 'grn_reviews_no_delete'];
const ID = '0b7e8e2e-8f4c-4f0a-9d54-4f9d6f0f0a11';

test('the 13 app functions are in the manifest; the helpers are not', () => {
  for (const a of APP) assert.equal(lookup(a)?.kind, 'db', a);
  for (const h of HELPERS) { assert.equal(lookup(h), undefined, h); assert.ok(!dbFunctions().includes(h), h); }
  assert.equal((lookup('cat_item_save') as any).idem, true);
  assert.equal(lookup('cat_item_list')?.rate, 'read');
  assert.equal(lookup('grn_decide')?.rate, 'write');
});

test('the old per-feature routes are gone', async () => {
  for (const path of ['/api/partner/catalogue', '/api/partner/grn']) assert.equal((await dispatch(new Request(`http://x${path}`))).status, 404, path);
});

test('request shapes: friendly first checks, the database decides the rest', () => {
  assert.ok(cat.List.safeParse({ q: 'cola', status: 'active', page: 1, page_size: 20 }).success);
  assert.ok(!cat.List.safeParse({ status: 'nope' }).success);
  assert.ok(!cat.View.safeParse({ id: 'nope' }).success);
  assert.ok(cat.Save.safeParse({ mode: 'quick', name: 'Cola', sku: 'CC500', price_minor: 4000 }).success);
  assert.ok(!cat.Save.safeParse({ id: ID, name: 'x' }).success, 'a change needs the version');
  assert.ok(!cat.Save.safeParse({ price_minor: 12.5 }).success, 'money is whole paise');
  assert.ok(!cat.Save.safeParse({ unknown_field: 1 }).success);
  assert.ok(grn.Invoice.safeParse({ receipt_document_id: ID, supplier_name: 'S', invoice_no: '1', invoice_date: '2026-10-10', lines: [{ product_name: 'x', qty: 1, unit_price_minor: 100 }] }).success);
  assert.ok(!grn.Invoice.safeParse({ receipt_document_id: ID, supplier_name: 'S', invoice_no: '1', invoice_date: '10/10/2026', lines: [] }).success);
  assert.ok(!grn.Decide.safeParse({ receipt_document_id: ID, decision: 'approve' }).success, 'deciding needs the version');
  assert.ok(grn.Decide.safeParse({ receipt_document_id: ID, version: 3, decision: 'reject', note: 'why' }).success);
});

test('section G database errors map to HTTP statuses with a sentence', () => {
  const t = (message: string) => { try { mapDbError({ message }); } catch (e) { return e instanceof HttpError ? [e.status, e.message] : [0]; } return []; };
  assert.deepEqual(t('POS_TAX_REQUIRED: complete the HSN and GST rate'), [422, 'Complete the HSN and GST rate.']);
  assert.equal(t('POS_STALE: this item was changed on another device')[0], 409);
  assert.equal(t('POS_DUPLICATE: another stock item already uses SKU A')[0], 409);
  assert.equal(t('POS_BAD_REQUEST: stock item FLOUR is counted in kg; sell it in kg too, or use another SKU')[0], 400);
  assert.equal(t('GRN_UNRESOLVED: resolve the exceptions')[0], 422);
  assert.equal(t('GRN_NOT_APPROVED: RCV-1 has no approved GRN yet')[0], 409);
  assert.equal(t('GRN_NOT_FOUND: receipt not found')[0], 404);
  assert.equal(t('GRN_FORBIDDEN: only an approver can decide a GRN')[0], 403);
});
