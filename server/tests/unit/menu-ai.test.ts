// Unit tests that need no database and no Claude API: the restaurant menu entries and "Write with AI" (secure handler menu_ai_describe).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import Anthropic from '@anthropic-ai/sdk';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { dbFunctions, lookup } from '../../src/rpc-manifest.ts';
import { mapDbError } from '../../src/db.ts';
import { HttpError } from '../../src/http.ts';
import * as rst from '../../src/schemas/restaurant.ts';
import { AI_MODEL, describeDish, OUTPUT_MAX, tidy, type Deps } from '../../src/modules/secure/menuAi.ts';

const ID = '0b7e8e2e-8f4c-4f0a-9d54-4f9d6f0f0a11';
const req = new Request('http://x/rpc/menu_ai_describe', { method: 'POST' });
const DISH = { name: 'Americano (Large)', category: 'Hot Cafe', food_type: 'veg', course: 'drink', ingredients: ['Coffee shot', 'Hot water'] };

function fake(over: Partial<Deps> = {}) {
  const calls: { begin: unknown[]; finish: Record<string, unknown>[]; write: unknown[] } = { begin: [], finish: [], write: [] };
  const deps: Deps = {
    key: () => 'test-key',
    begin: async (_r, p) => { calls.begin.push(p); return { request_id: 'r1', dish: DISH }; },
    finish: async (_r, p) => { calls.finish.push(p); return { recorded: true }; },
    write: async (_k, dish, notes) => { calls.write.push({ dish, notes }); return { text: 'Bold espresso topped with hot water.', model: AI_MODEL, refused: false }; },
    ...over,
  };
  return { deps, calls };
}
const status = (e: unknown) => (e as HttpError).status;
const code = (e: unknown) => (e as HttpError).code;

test('menu entries: four database functions and one secure handler; the AI gate functions are not reachable through the gateway', () => {
  for (const a of ['rst_menu', 'rst_menu_item_view', 'rst_menu_item_save', 'rst_menu_stock_set']) assert.equal(lookup(a)?.kind, 'db', a);
  assert.equal(lookup('rst_menu_item_save')?.rate, 'write');
  const ai = lookup('menu_ai_describe');
  assert.equal(ai?.kind, 'secure');
  assert.equal(ai?.rate, 'secure');
  assert.equal(typeof (ai as any).handler, 'function');
  for (const hidden of ['rst_menu_ai_begin', 'rst_menu_ai_finish']) { assert.equal(lookup(hidden), undefined); assert.ok(!dbFunctions().includes(hidden)); }
});

test('request shapes', () => {
  assert.ok(rst.Menu.safeParse({ q: 'capp', filter: 'needs_image' }).success);
  assert.ok(!rst.Menu.safeParse({ filter: 'drafts' }).success);
  assert.ok(rst.MenuItemSave.safeParse({ id: ID, version: 3, description: 'x', availability: [{ slot: 'morning' }, { slot: 'custom', starts_at: '22:30', ends_at: '02:00', days: [1, 5] }] }).success);
  assert.ok(rst.MenuItemSave.safeParse({ id: ID, version: 3, availability: [{ slot: 'night', starts_at: '20:00', ends_at: '24:00' }] }).success);
  assert.ok(!rst.MenuItemSave.safeParse({ id: ID, description: 'x' }).success, 'a save needs the version');
  assert.ok(!rst.MenuItemSave.safeParse({ id: ID, version: 1, availability: [{ slot: 'afternoon' }] }).success, 'afternoon is not a preset (open question)');
  assert.ok(!rst.MenuItemSave.safeParse({ id: ID, version: 1, availability: [{ slot: 'custom', starts_at: '25:00', ends_at: '02:00' }] }).success);
  assert.ok(!rst.MenuItemSave.safeParse({ id: ID, version: 1, description: 'a'.repeat(501) }).success);
  assert.ok(rst.MenuStockSet.safeParse({ category_id: ID, in_stock: true }).success);
  assert.ok(!rst.MenuStockSet.safeParse({ in_stock: true }).success);
  assert.ok(!rst.MenuStockSet.safeParse({ id: ID, category_id: ID, in_stock: true }).success);
  assert.ok(!rst.AiDescribe.safeParse({ item_id: ID, notes: 'n'.repeat(1001) }).success, 'notes are capped');
  assert.ok(!rst.AiDescribe.safeParse({ item_id: ID, dish: { name: 'spoofed' } }).success, 'dish facts never come from the phone');
});

test('AI not configured: 503 ai_not_configured, before any quota is spent', async () => {
  const { deps, calls } = fake({ key: () => null });
  await assert.rejects(describeDish({ request: req, userId: 'u', args: { item_id: ID, notes: 'coffee' } }, deps),
    e => status(e) === 503 && code(e) === 'ai_not_configured' && (e as HttpError).detail === 'AI writing is not set up yet.');
  assert.equal(calls.begin.length, 0);
});

test('AI result accepted: tidy text returned, outcome recorded with sizes only, nothing saved', async () => {
  const { deps, calls } = fake({ write: async () => ({ text: '**"Bold espresso   topped with hot water."**', model: AI_MODEL, refused: false }) });
  const out = await describeDish({ request: req, userId: 'u', args: { item_id: ID, notes: '  coffee shot,\n hot water ' } }, deps);
  assert.equal(out.text, 'Bold espresso topped with hot water.');
  assert.equal(out.model, AI_MODEL);
  assert.deepEqual(calls.begin[0], { item_id: ID, input_chars: 'coffee shot, hot water'.length });
  assert.deepEqual(calls.finish[0], { request_id: 'r1', status: 'ok', model: AI_MODEL, output_chars: out.text.length });
  assert.ok(!JSON.stringify(calls.finish).includes('espresso'), 'the text is never sent back to the database');
});

test('the model gets the dish facts from the database gate, and the notes capped', async () => {
  const { deps, calls } = fake();
  await describeDish({ request: req, userId: 'u', args: { item_id: ID, notes: 'x'.repeat(1000) } }, deps);
  const w = calls.write[0] as { dish: typeof DISH; notes: string };
  assert.equal(w.dish.name, 'Americano (Large)');
  assert.equal(w.notes.length, 1000);
});

test('rate limited by the database: 429 rate_limited, no Claude call', async () => {
  const { deps, calls } = fake({ begin: async () => mapDbError({ message: 'POS_RATE_LIMITED: AI writing is limited to 20 dishes an hour for your business' }) });
  await assert.rejects(describeDish({ request: req, userId: 'u', args: { item_id: ID } }, deps), e => status(e) === 429 && code(e) === 'rate_limited');
  assert.equal(calls.write.length, 0);
});

test('refused by the model: 422 ai_refused and recorded as refused', async () => {
  const { deps, calls } = fake({ write: async () => ({ text: '', model: AI_MODEL, refused: true }) });
  await assert.rejects(describeDish({ request: req, userId: 'u', args: { item_id: ID } }, deps), e => status(e) === 422 && code(e) === 'ai_refused');
  assert.equal(calls.finish[0].status, 'refused');
});

test('a bad server key reads as not set up; an outage is 502 and recorded as failed', async () => {
  const auth = new Anthropic.AuthenticationError(401, { type: 'error', error: { type: 'authentication_error', message: 'x' } }, 'x', new Headers());
  let f = fake({ write: async () => { throw auth; } });
  await assert.rejects(describeDish({ request: req, userId: 'u', args: { item_id: ID } }, f.deps), e => status(e) === 503 && code(e) === 'ai_not_configured');
  f = fake({ write: async () => { throw new Error('socket hang up'); } });
  await assert.rejects(describeDish({ request: req, userId: 'u', args: { item_id: ID } }, f.deps), e => status(e) === 502 && code(e) === 'ai_failed');
  assert.equal(f.calls.finish[0].status, 'failed');
});

test('output is capped and plain', () => {
  const long = 'A rich and smooth coffee. '.repeat(40);
  assert.ok(tidy(long).length <= OUTPUT_MAX);
  assert.ok(tidy(long).endsWith('.'));
  assert.equal(tidy('Description: # Masala dosa, crisp and golden'), 'Masala dosa, crisp and golden');
});

test('the door: menu_ai_describe without a token is 401', async () => {
  const res = await dispatch(new Request('http://x/rpc/menu_ai_describe', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }));
  assert.equal(res.status, 401);
});
