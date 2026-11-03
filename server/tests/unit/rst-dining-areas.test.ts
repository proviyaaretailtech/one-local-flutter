import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';

const post = (path: string, body = '{}') => dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body }));
const parse = (alias: string, body: unknown) => (lookup(alias) as { args: { safeParse(v: unknown): { success: boolean } } }).args.safeParse(body);
const A = '55000000-0000-0000-0000-0000000000a1', T = '55000000-0000-0000-0000-0000000000c1';

test('dining areas (0646): one read and five writes; helpers unreachable; sign-in needed', async () => {
  assert.equal(lookup('tbl_areas')?.rate, 'read');
  for (const a of ['tbl_area_save', 'tbl_area_set_active', 'tbl_area_reorder', 'tbl_area_delete', 'tbl_area_tables']) assert.equal(lookup(a)?.rate, 'write', a);
  assert.equal(lookup('tbl__area_json'), undefined);
  assert.equal((await post('/rpc/tbl_area_save', JSON.stringify({ name: 'Rooftop' }))).status, 401);
});

test('dining areas: request shapes', () => {
  assert.equal(parse('tbl_area_save', { name: 'Rooftop', area_type: 'rooftop' }).success, true);
  assert.equal(parse('tbl_area_save', { name: '' }).success, false);
  assert.equal(parse('tbl_area_save', { name: 'x'.repeat(41) }).success, false);
  assert.equal(parse('tbl_area_save', { name: 'Cellar', area_type: 'cave' }).success, false);
  assert.equal(parse('tbl_area_set_active', { id: A, active: false }).success, true);
  assert.equal(parse('tbl_area_set_active', { id: A, active: 'no' }).success, false);
  assert.equal(parse('tbl_area_reorder', { ids: [A] }).success, true);
  assert.equal(parse('tbl_area_reorder', { ids: [] }).success, false);
  assert.equal(parse('tbl_area_tables', { id: A, table_ids: [T] }).success, true);
  assert.equal(parse('tbl_area_tables', { id: A, table_ids: ['nope'] }).success, false);
  assert.equal(parse('tbl_area_delete', { id: A }).success, true);
});
