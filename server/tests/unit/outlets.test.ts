// Unit tests that need no database: the multi-outlet calls on the /rpc gateway (manifest entries, request shapes, error mapping).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dbFunctions, lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as out from '../../src/schemas/outlets.ts';

const ID = '0b7e8e2e-8f4c-4f0a-9d54-4f9d6f0f0a11';
const form = { name: 'Dosa House Barshi Road', address_line: '21 Barshi Road', pin_code: '413512', lat: 18.41, lng: 76.57,
  hours: { opens: '09:00', closes: '23:00', days: ['mon', 'tue'] }, fssai: '12345678901234' };

test('the three outlet calls are in the manifest; the helper is not', () => {
  assert.equal(lookup('outlet_list')?.rate, 'read');
  assert.equal(lookup('outlet_set_channel')?.rate, 'write');
  assert.equal((lookup('outlet_add') as any).idem, true, 'adding an outlet carries the Idempotency-Key');
  assert.equal(lookup('outlet_json'), undefined);
  assert.ok(!dbFunctions().includes('outlet_json'));
  assert.ok(!dbFunctions().includes('master_outlet_application_decide'), 'only Master Admin decides');
});

test('request shapes: friendly first checks, the database decides the rest', () => {
  assert.ok(out.List.safeParse({}).success);
  assert.ok(out.List.safeParse({ q: 'ausa', location_id: ID }).success);
  assert.ok(!out.List.safeParse({ location_id: 'nope' }).success);
  assert.ok(out.SetChannel.safeParse({ location_id: ID, accepting: false }).success);
  assert.ok(out.SetChannel.safeParse({ location_id: ID, rush_mode: true, rush_extra_minutes: 20 }).success);
  assert.ok(!out.SetChannel.safeParse({ location_id: ID }).success, 'nothing to change');
  assert.ok(!out.SetChannel.safeParse({ location_id: ID, rush_extra_minutes: 90 }).success);
  assert.ok(!out.SetChannel.safeParse({ accepting: true }).success, 'which outlet');
  assert.ok(out.Add.safeParse(form).success);
  assert.ok(out.Add.safeParse({ ...form, gstin: '27abcde1234f1z5' }).success, 'GSTIN is upper-cased');
  assert.ok(!out.Add.safeParse({ ...form, lat: undefined }).success, 'map pin required');
  assert.ok(!out.Add.safeParse({ ...form, pin_code: '01234' }).success);
  assert.ok(!out.Add.safeParse({ ...form, hours: { opens: '9am', closes: '23:00', days: ['mon'] } }).success);
  assert.ok(!out.Add.safeParse({ ...form, hours: { opens: '09:00', closes: '23:00', days: [] } }).success);
  assert.ok(!out.Add.safeParse({ ...form, fssai: '123' }).success);
});

test('outlet database errors map to HTTP statuses with a sentence', () => {
  const t = (message: string) => { try { mapDbError({ message }); } catch (e) { return e instanceof HttpError ? [e.status, e.message] : [0]; } return []; };
  assert.deepEqual(t('OUTLET_NOT_VERIFIED: this outlet is waiting for One Local to verify it'), [409, 'This outlet is waiting for One Local to verify it.']);
  assert.equal(t('OUTLET_FORBIDDEN: your role cannot change this outlet')[0], 403);
  assert.equal(t('OUTLET_NOT_FOUND: outlet not found')[0], 404);
  assert.equal(t('OUTLET_NOT_LISTED: your business is not listed on One Local yet')[0], 409);
  assert.equal(t('OUTLET_CONFLICT: you already have an outlet called X')[0], 409);
  assert.equal(t('OUTLET_BAD_REQUEST: place the map pin on the outlet')[0], 400);
});

test('drafts and the all-outlets home are in the manifest with friendly shapes', () => {
  for (const a of ['outlet_draft_get', 'outlet_draft_save', 'outlet_draft_submit', 'outlet_draft_discard', 'rst_dashboard_scope']) assert.equal(lookup(a)?.kind, 'db', a);
  assert.equal((lookup('outlet_draft_save') as any).idem, true);
  for (const h of ['outlet_draft_json', 'outlet_draft_missing', 'outlet_draft_guard_caller', 'outlet_home_state', 'jsonb_num_sum', 'gst_states']) assert.ok(!dbFunctions().includes(h), h);
  assert.ok(out.DraftSave.safeParse({ idempotency_key: 'key-12345678', state_code: '29', step: 'details' }).success, 'a draft may be partial');
  assert.ok(out.DraftSave.safeParse({ id: ID, name: '', gstin: null }).success, 'empty clears a field');
  assert.ok(!out.DraftSave.safeParse({ id: ID, state_code: 'KA' }).success);
  assert.ok(!out.DraftSave.safeParse({ id: ID, step: 'payment' }).success);
  assert.ok(!out.DraftRef.safeParse({}).success);
  assert.ok(out.Add.safeParse({ ...form, state_code: '29', gstin: '29ABCDE1234F1Z5', contact_name: 'Ravi', contact_mobile: '9845012345', contact_email: 'r@x.in' }).success);
  const rs = lookup('rst_dashboard_scope') as any;
  assert.ok(rs.args.safeParse({ location_id: 'all' }).success && rs.args.safeParse({ location_id: ID }).success && !rs.args.safeParse({ location_id: 'some' }).success);
});

test('an incomplete draft is 422 with the missing fields in words', () => {
  try { mapDbError({ message: 'OUTLET_INCOMPLETE: still missing: map pin, fssai' }); } catch (e) {
    assert.ok(e instanceof HttpError); assert.equal(e.status, 422); assert.equal(e.message, 'Still missing: map pin, fssai.'); return;
  }
  assert.fail('no error');
});
