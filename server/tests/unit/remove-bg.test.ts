// Unit tests that need no database and no remove.bg account: "Remove background (AI)" (secure handler cat_image_remove_bg).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lookup } from '../../src/rpc-manifest.ts';
import { HttpError } from '../../src/http.ts';
import { removeBackground, type Deps } from '../../src/modules/secure/removeBg.ts';

const req = new Request('http://x/rpc/cat_image_remove_bg', { method: 'POST' });
const PHOTO = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const args = { image_b64: PHOTO, content_type: 'image/png' };

function fake(over: Partial<Deps> = {}) {
  const calls: { staff: number; call: Record<string, unknown>[] } = { staff: 0, call: [] };
  const deps: Deps = {
    key: () => 'test-key',
    size: () => 'auto',
    staff: async () => { calls.staff++; return {}; },
    call: async (_k, body) => { calls.call.push(body); return { status: 200, json: { data: { result_b64: 'Q0xFQU4=' } } }; },
    ...over,
  };
  return { deps, calls };
}
const status = (e: unknown) => (e as HttpError).status;
const code = (e: unknown) => (e as HttpError).code;

test('cat_image_remove_bg is a secure entry with room for a 5 MB photo', () => {
  const e = lookup('cat_image_remove_bg');
  assert.equal(e?.kind, 'secure');
  assert.ok((e as { maxBytes?: number }).maxBytes! >= Math.ceil((5 * 1024 * 1024) / 3) * 4);
});

test('the photo goes to remove.bg as base64 PNG output and comes back as image_b64', async () => {
  const { deps, calls } = fake();
  const out = await removeBackground({ request: req, userId: 'u', args }, deps);
  assert.deepEqual(out, { image_b64: 'Q0xFQU4=', content_type: 'image/png' });
  assert.equal(calls.staff, 1);
  assert.deepEqual(calls.call, [{ image_file_b64: PHOTO, size: 'auto', format: 'png' }]);
});

test('no key: 503 bg_not_configured before the staff check or any call', async () => {
  const { deps, calls } = fake({ key: () => null });
  await assert.rejects(removeBackground({ request: req, userId: 'u', args }, deps), e => status(e) === 503 && code(e) === 'bg_not_configured');
  assert.equal(calls.staff, 0);
  assert.equal(calls.call.length, 0);
});

test('a bad request shape is refused before any call', async () => {
  const { deps, calls } = fake();
  await assert.rejects(removeBackground({ request: req, userId: 'u', args: { image_b64: PHOTO, content_type: 'image/gif' } }, deps), e => status(e) === 400);
  await assert.rejects(removeBackground({ request: req, userId: 'u', args: { image_b64: 'not base64 !!', content_type: 'image/png' } }, deps), e => status(e) === 400);
  assert.equal(calls.call.length, 0);
});

test('remove.bg refusals become plain answers', async () => {
  for (const [s, want] of [[400, 'bg_unusable'], [402, 'bg_no_credits'], [403, 'bg_not_configured'], [429, 'bg_busy'], [500, 'bg_failed']] as const) {
    const { deps } = fake({ call: async () => ({ status: s, json: { errors: [{ title: 'x' }] } }) });
    await assert.rejects(removeBackground({ request: req, userId: 'u', args }, deps), e => code(e) === want, `status ${s}`);
  }
  const { deps } = fake({ call: async () => { throw new Error('network'); } });
  await assert.rejects(removeBackground({ request: req, userId: 'u', args }, deps), e => status(e) === 502 && code(e) === 'bg_failed');
});
