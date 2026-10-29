// Unit tests that need no Google account: the map pin calls (maps_search, maps_place, maps_reverse). Google is a stub.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lookup } from '../../src/rpc-manifest.ts';
import { HttpError } from '../../src/http.ts';
import { describe, mapsPlace, mapsReverse, mapsSearch, type Deps } from '../../src/modules/secure/maps.ts';
import { PlaceAsk, Point, Search } from '../../src/schemas/maps.ts';

const req = new Request('http://x/rpc/maps_search', { method: 'POST' });
const ctx = (args: Record<string, unknown>) => ({ request: req, userId: 'u', args });

type Call = { url: string; init?: RequestInit };
function google(answers: ((url: string) => unknown)[]) {
  const calls: Call[] = [];
  const deps: Deps = {
    key: () => 'test-key',
    fetcher: (async (url: string, init?: RequestInit) => {
      calls.push({ url: String(url), init });
      const answer = answers[calls.length - 1]?.(String(url));
      if (answer instanceof Error) throw answer;
      const { status = 200, json = {} } = (answer ?? {}) as { status?: number; json?: unknown };
      return new Response(JSON.stringify(json), { status, headers: { 'content-type': 'application/json' } });
    }) as typeof fetch,
  };
  return { deps, calls };
}

const LATUR = [
  { types: ['sublocality_level_1', 'sublocality'], longText: 'Vishal Nagar' },
  { types: ['locality', 'political'], longText: 'Latur' },
  { types: ['administrative_area_level_1'], longText: 'Maharashtra' },
  { types: ['country'], longText: 'India' },
  { types: ['postal_code'], longText: '413531' },
];

test('the three calls are secure entries any signed-in person can use', () => {
  for (const name of ['maps_search', 'maps_place', 'maps_reverse']) {
    const e = lookup(name);
    assert.equal(e?.kind, 'secure', name);
    assert.equal(e?.rate, 'secure', name);
  }
});

test('shapes: a short search, a bad place id, a point off the map and unknown keys are refused', () => {
  assert.equal(Search.safeParse({ q: 'a' }).success, false);
  assert.equal(Search.safeParse({ q: 'Ganj Golai', lat: 18.4, lng: 76.5, session: 'abcdefgh1234' }).success, true);
  assert.equal(Search.safeParse({ q: 'Ganj Golai', session: 'has spaces!' }).success, false);
  assert.equal(PlaceAsk.safeParse({ place_id: '../../etc' }).success, false);
  assert.equal(Point.safeParse({ lat: 91, lng: 0 }).success, false);
  assert.equal(Point.safeParse({ lat: 18.4, lng: 76.5, extra: 1 }).success, false);
});

test('describe: the line is the address without locality, city, state, PIN and country', () => {
  const d = describe(18.4, 76.56, 'Shop 4, Main Road, Vishal Nagar, Latur, Maharashtra 413531, India', LATUR);
  assert.deepEqual(d, { lat: 18.4, lng: 76.56, formatted: 'Shop 4, Main Road, Vishal Nagar, Latur, Maharashtra 413531, India', line: 'Shop 4, Main Road', locality: 'Vishal Nagar', city: 'Latur', state: 'Maharashtra', pin_code: '413531' });
});

test('no key: 503 maps_not_configured before any call to Google', async () => {
  const { deps, calls } = google([]);
  for (const run of [() => mapsSearch(ctx({ q: 'Latur' }), { ...deps, key: () => null }), () => mapsReverse(ctx({ lat: 1, lng: 1 }), { ...deps, key: () => null })]) {
    await assert.rejects(run, (e: unknown) => (e as HttpError).status === 503 && (e as HttpError).code === 'maps_not_configured');
  }
  assert.equal(calls.length, 0);
});

test('search: India only, biased to the map, key in a header, results trimmed to place id, title and subtitle', async () => {
  const { deps, calls } = google([() => ({ json: { suggestions: [
    { placePrediction: { placeId: 'ChIJabcdefghij', structuredFormat: { mainText: { text: 'Ganj Golai' }, secondaryText: { text: 'Latur, Maharashtra' } } } },
    { queryPrediction: { text: { text: 'ganj golai market' } } },
  ] } })]);
  const out = await mapsSearch(ctx({ q: 'Ganj Golai', lat: 18.4, lng: 76.56, session: 'abcdefgh1234' }), deps);
  assert.deepEqual(out, { results: [{ place_id: 'ChIJabcdefghij', title: 'Ganj Golai', subtitle: 'Latur, Maharashtra' }] });
  const body = JSON.parse(String(calls[0].init?.body));
  assert.deepEqual(body.includedRegionCodes, ['in']);
  assert.equal(body.sessionToken, 'abcdefgh1234');
  assert.equal(body.locationBias.circle.center.latitude, 18.4);
  assert.equal((calls[0].init?.headers as Record<string, string>)['X-Goog-Api-Key'], 'test-key');
  assert.ok(!calls[0].url.includes('test-key'));
});

test('place: position and address fields from Places details; Google down becomes 502', async () => {
  const { deps } = google([() => ({ json: { formattedAddress: 'Shop 4, Main Road, Vishal Nagar, Latur, Maharashtra 413531, India', location: { latitude: 18.41, longitude: 76.57 }, addressComponents: LATUR } })]);
  const p = await mapsPlace(ctx({ place_id: 'ChIJabcdefghij' }), deps);
  assert.equal(p.line, 'Shop 4, Main Road');
  assert.equal(p.pin_code, '413531');
  assert.equal(p.lat, 18.41);
  const down = google([() => ({ status: 500, json: { error: { message: 'boom key=test-key' } } })]);
  await assert.rejects(() => mapsPlace(ctx({ place_id: 'ChIJabcdefghij' }), down.deps), (e: unknown) => (e as HttpError).status === 502);
});

test('reverse: the Geocoding answer when Google gives one', async () => {
  const { deps, calls } = google([() => ({ json: { status: 'OK', results: [{ formatted_address: '12, Station Road, Vishal Nagar, Latur, Maharashtra 413531, India', address_components: LATUR.map(c => ({ types: c.types, long_name: c.longText })) }] } })]);
  const p = await mapsReverse(ctx({ lat: 18.4, lng: 76.56 }), deps);
  assert.equal(calls.length, 1);
  assert.equal(p.line, '12, Station Road');
  assert.equal(p.city, 'Latur');
});

test('reverse: Geocoding refused -> the nearest place names the area, city, state and PIN, with no street line', async () => {
  const { deps, calls } = google([
    () => ({ json: { status: 'REQUEST_DENIED', error_message: 'You must enable Billing' } }),
    () => ({ json: { places: [{ formattedAddress: 'HDFC Bank, Sonavane Complex, Vishal Nagar, Latur, Maharashtra 413531, India', addressComponents: LATUR }] } }),
  ]);
  const p = await mapsReverse(ctx({ lat: 18.4088, lng: 76.5604 }), deps);
  assert.equal(calls.length, 2);
  assert.ok(calls[1].url.endsWith(':searchNearby'));
  assert.deepEqual(p, { lat: 18.4088, lng: 76.5604, formatted: 'Vishal Nagar, Latur, Maharashtra 413531', line: '', locality: 'Vishal Nagar', city: 'Latur', state: 'Maharashtra', pin_code: '413531' });
});

test('reverse: nothing found anywhere -> the pin with empty address fields, not an error', async () => {
  const { deps } = google([() => ({ json: { status: 'ZERO_RESULTS' } }), () => new Error('network')]);
  const p = await mapsReverse(ctx({ lat: 10, lng: 70 }), deps);
  assert.deepEqual(p, { lat: 10, lng: 70, formatted: '', line: '', locality: '', city: '', state: '', pin_code: '' });
});
