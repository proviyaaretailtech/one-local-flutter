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
