// Media manager (1 Nov 2026): Master media is narrowed by brand or by OL subcategory (a 3-letter code).
import test from 'node:test';
import assert from 'node:assert/strict';
import { parse } from '../../src/validate.ts';
import { HttpError } from '../../src/http.ts';
import * as media from '../../src/schemas/media.ts';

test('master media: search, brand and subcategory filters are accepted; a bad subcategory or extra key is not', () => {
  assert.deepEqual(parse(media.Search, { brand: 'Tata' }), { brand: 'Tata' });
  assert.deepEqual(parse(media.Search, { sub: 'ATT', q: 'atta' }), { sub: 'ATT', q: 'atta' });
  assert.throws(() => parse(media.Search, { sub: 'ATTA' }), (e: HttpError) => e.status === 400 && /subcategory/.test(e.message));
  assert.throws(() => parse(media.Search, { brand: 'x'.repeat(61) }), (e: HttpError) => e.status === 400);
  assert.throws(() => parse(media.Search, { colour: 'red' }), (e: HttpError) => e.status === 400);
});
