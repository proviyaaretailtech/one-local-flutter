// Guest experience builder (0654): the AI wording reviewer (with a fake model), the brand page address and the pre-order door shapes.
import test from 'node:test';
import assert from 'node:assert/strict';
import '../../src/routes.ts';
import { dispatch } from '../../src/router.ts';
import { lookup } from '../../src/rpc-manifest.ts';
import { askModel, prompt, readVerdict, SYSTEM, type Pending } from '../../src/modules/secure/experienceAi.ts';
import { RESERVED_SLUGS } from '../../src/guest-web.ts';

const pending: Pending = { id: 'x', version: 3, business: 'Niks Cafe', wording: [{ label: 'Welcome: headline', from: 'Hello', to: 'Fresh coffee, made slow' }] };
const fakeFetch = (content: string, status = 200) => (async () => new Response(JSON.stringify({ model: 'fake', choices: [{ message: { content } }] }), { status })) as typeof fetch;
const post = (path: string, body: unknown, peer = '10.0.9.1') =>
  dispatch(new Request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-ol-peer': peer }, body: JSON.stringify(body) }));

test('AI reviewer: sends only the changed wording, never the page', () => {
  const p = prompt(pending);
  assert.match(p, /Niks Cafe/);
  assert.match(p, /"Hello" -> "Fresh coffee, made slow"/);
  assert.match(SYSTEM, /JSON only/);
});

test('AI reviewer: ok and flag are read; anything else is "unavailable" so the rules result stands', async () => {
  assert.deepEqual(readVerdict('{"verdict":"ok","note":"fine"}', 'm'), { verdict: 'ok', category: undefined, note: 'fine', model: 'm' });
  assert.equal(readVerdict('{"verdict":"flag","category":"money","note":"claims a discount"}', 'm').category, 'money');
  assert.equal(readVerdict('{"verdict":"flag","category":"weird"}', 'm').category, 'content');
  assert.equal(readVerdict('not json', 'm').verdict, 'unavailable');
  assert.equal(readVerdict('{"verdict":"maybe"}', 'm').verdict, 'unavailable');
  assert.equal((await askModel(pending, 'k', 'm', fakeFetch('{"verdict":"flag","category":"content","note":"x"}'))).verdict, 'flag');
  assert.equal((await askModel(pending, 'k', 'm', fakeFetch('', 500))).verdict, 'unavailable');
  assert.equal((await askModel(pending, null, 'm', fakeFetch('{"verdict":"ok"}'))).verdict, 'unavailable', 'no key: the AI never runs');
});

test('builder names: publish is a secure entry (AI step), the rest run as the caller', () => {
  assert.equal(lookup('gx_publish')?.kind, 'secure');
  for (const n of ['gx_builder_get', 'gx_draft_save', 'gx_rollback']) assert.equal(lookup(n)?.kind, 'db', n);
  for (const n of ['gx_ai_verdict', 'gx_ai_pending', 'gx_review_decide', 'gx_review_queue']) assert.equal(lookup(n), undefined, `${n} is never reachable from the app`);
});

test('brand page: /<store link> and /r/<store link> are the guest page; OneLocal page names and bad names are not', async () => {
  for (const path of ['/niks-cafe', '/r/niks-cafe']) assert.notEqual((await dispatch(new Request(`http://x${path}`))).status, 404, path);
  for (const path of ['/privacy', '/rpc', '/Niks..', '/-x', '/a_b']) assert.equal((await dispatch(new Request(`http://x${path}`))).status, 404, path);
  assert.equal((await dispatch(new Request('http://x/health'))).status, 200, 'fixed paths win over a store link');
  assert.ok(RESERVED_SLUGS.has('delete-account') && RESERVED_SLUGS.has('t') && RESERVED_SLUGS.has('m'));
});

test('pre-order door: strict shapes, checked before the database', async () => {
  const line = { menu_item_id: '56000000-0000-0000-0000-0000000000f1', qty: 1 };
  const ok = { slug: 'niks-cafe', idempotency_key: 'pre-12345678', lines: [line], guest_name: 'Asha', phone: '9876500011', pickup_at: '2026-11-05T10:30:00+05:30' };
  assert.equal((await post('/guest/preorder', { ...ok, phone: '12345' })).status, 400);
  assert.equal((await post('/guest/preorder', { ...ok, guest_name: '' })).status, 400);
  assert.equal((await post('/guest/preorder', { ...ok, table: 'T1' })).status, 400, 'extra keys are refused');
  assert.equal((await post('/guest/pretrack', { track: 'nope' })).status, 400);
  assert.equal((await post('/guest/slots', { slug: '../x' })).status, 400);
});
