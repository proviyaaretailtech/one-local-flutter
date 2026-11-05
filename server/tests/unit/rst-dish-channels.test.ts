import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);

test('Apply to Channels (0652): a dish save takes Table QR and the OneLocal app, each on or off, and nothing else', () => {
  const d = { id: '6f1c2a34-5b6d-4e7f-8a9b-0c1d2e3f4a5b', version: 7 };
  assert.equal(parse('rst_menu_item_save', { ...d, channels: { qr: false, one_local: true } }).success, true);
  assert.equal(parse('rst_menu_item_save', { ...d, channels: { qr: true } }).success, true);
  assert.equal(parse('rst_menu_item_save', d).success, true, 'channels are optional');
  assert.equal(parse('rst_menu_item_save', { ...d, channels: { swiggy: false } }).success, false, 'Swiggy and Zomato are switched in their own apps');
  assert.equal(parse('rst_menu_item_save', { ...d, channels: { qr: 'no' } }).success, false);
});
