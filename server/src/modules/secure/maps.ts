// Secret-bearing: Google Maps Platform for the map pin (the business address in onboarding, a new outlet). The key stays on this server.
//   maps_search  {q, lat?, lng?, session?} -> {results: [{place_id, title, subtitle}]}  Places API (New) autocomplete, India only
//   maps_place   {place_id, session?}       -> Place                                     Places API (New) place details
//   maps_reverse {lat, lng}                 -> Place                                     Geocoding API. When Google refuses it (API not enabled
//                                                                                        or not billed) or finds nothing, the nearest place from
//                                                                                        Places API (New) nearby search gives the area, city,
//                                                                                        state and PIN; the address line stays empty then.
// GOOGLE_MAPS_API_KEY must be set (never printed; the geocoding address carries it, so failures are logged through redact()).
// Without it: 503 "Maps are not set up yet", code maps_not_configured. Nothing is saved here: the screen fills its fields and the
// person checks and saves them as usual.
import { HttpError, redact } from '../../http.ts';
import type { SecureCtx } from './index.ts';

const TIMEOUT_MS = 8000;

export type Place = { lat: number; lng: number; formatted: string; line: string; locality: string; city: string; state: string; pin_code: string };
export type Deps = { key: () => string | null; fetcher: typeof fetch };
const live: Deps = { key: () => process.env.GOOGLE_MAPS_API_KEY?.trim() || null, fetcher: (...a) => fetch(...a) };

export const notConfigured = () => new HttpError(503, 'Maps are not set up yet. Please type the address.', undefined, 'maps_not_configured');
const unavailable = () => new HttpError(502, 'Map search is unavailable right now. Please try again.');

function keyOf(deps: Deps): string {
  const key = deps.key();
  if (!key) throw notConfigured();
  return key;
}

type Component = { types?: string[]; long_name?: string; longText?: string };

/** The parts of a Google address the address fields need. `line` is the formatted address without its locality, city, state, PIN and country. */
export function describe(lat: number, lng: number, formatted: string, components: Component[], withLine = true): Place {
  const pick = (...types: string[]) => {
    for (const type of types) {
      const c = components.find(x => x.types?.includes(type));
      const v = (c?.long_name ?? c?.longText ?? '').trim();
      if (v) return v;
    }
    return '';
  };
  const city = pick('locality', 'administrative_area_level_3', 'administrative_area_level_2');
  const locality = pick('sublocality_level_1', 'sublocality', 'sublocality_level_2', 'neighborhood');
  const state = pick('administrative_area_level_1');
  const pin = pick('postal_code').replace(/\D/g, '');
  const tail = new Set([city, locality, state, pick('country'), pin, `${state} ${pin}`.trim()].filter(Boolean).map(s => s.toLowerCase()));
  const parts = formatted.split(',').map(s => s.trim()).filter(Boolean);
  while (parts.length && tail.has(parts[parts.length - 1].toLowerCase())) parts.pop();
  return { lat, lng, formatted, line: withLine ? parts.join(', ') : '', locality, city, state, pin_code: /^\d{6}$/.test(pin) ? pin : '' };
}

async function google(deps: Deps, url: string, init: RequestInit = {}): Promise<Record<string, any>> {
  let response: Response;
  try {
    response = await deps.fetcher(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (e) {
    console.warn('[maps] request failed:', redact(e instanceof Error ? e.name : 'error'));
    throw unavailable();
  }
  const body = (await response.json().catch(() => ({}))) as Record<string, any>;
  if (!response.ok) {
    console.warn('[maps]', response.status, redact(JSON.stringify(body).slice(0, 300)));
    throw unavailable();
  }
  return body;
}

export async function mapsSearch(ctx: SecureCtx, deps: Deps = live) {
  const { q, lat, lng, session } = ctx.args as { q: string; lat?: number; lng?: number; session?: string };
  const key = keyOf(deps);
  const near = typeof lat === 'number' && typeof lng === 'number';
  const body = await google(deps, 'https://places.googleapis.com/v1/places:autocomplete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': key },
    body: JSON.stringify({
      input: q, includedRegionCodes: ['in'], languageCode: 'en', ...(session ? { sessionToken: session } : {}),
      ...(near ? { locationBias: { circle: { center: { latitude: lat, longitude: lng }, radius: 30000 } } } : {}),
    }),
  });
  type Prediction = { placeId: string; text?: { text: string }; structuredFormat?: { mainText?: { text: string }; secondaryText?: { text: string } } };
  const results = ((body.suggestions ?? []) as { placePrediction?: Prediction }[])
    .map(s => s.placePrediction)
    .filter((p): p is Prediction => !!p?.placeId)
    .slice(0, 6)
    .map(p => ({ place_id: p.placeId, title: p.structuredFormat?.mainText?.text ?? p.text?.text ?? '', subtitle: p.structuredFormat?.secondaryText?.text ?? '' }));
  return { results };
}

export async function mapsPlace(ctx: SecureCtx, deps: Deps = live): Promise<Place> {
  const { place_id, session } = ctx.args as { place_id: string; session?: string };
  const key = keyOf(deps);
  const query = session ? `?sessionToken=${encodeURIComponent(session)}` : '';
  const body = await google(deps, `https://places.googleapis.com/v1/places/${encodeURIComponent(place_id)}${query}`, {
    headers: { 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'formattedAddress,location,addressComponents' },
  });
  if (typeof body.location?.latitude !== 'number') throw new HttpError(404, 'That place has no map position. Try another result.');
  return describe(body.location.latitude, body.location.longitude, body.formattedAddress ?? '', body.addressComponents ?? []);
}

export async function mapsReverse(ctx: SecureCtx, deps: Deps = live): Promise<Place> {
  const { lat, lng } = ctx.args as { lat: number; lng: number };
  const key = keyOf(deps);
  const geo = await google(deps, `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&language=en&region=in&key=${encodeURIComponent(key)}`)
    .catch(() => ({ status: 'UNAVAILABLE' }) as Record<string, any>);
  if (geo.status === 'OK' && geo.results?.length) {
    const best = geo.results[0];
    return describe(lat, lng, best.formatted_address ?? '', best.address_components ?? []);
  }
  if (geo.status !== 'ZERO_RESULTS') console.warn('[maps] geocode', redact(String(geo.status)), redact(String(geo.error_message ?? '').slice(0, 120)));

  // The nearest place's own address names the area around the pin; its street line belongs to that place, so it is not used.
  const near = await google(deps, 'https://places.googleapis.com/v1/places:searchNearby', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'places.formattedAddress,places.addressComponents' },
    body: JSON.stringify({ maxResultCount: 5, rankPreference: 'DISTANCE', locationRestriction: { circle: { center: { latitude: lat, longitude: lng }, radius: 500 } } }),
  }).catch(() => ({}) as Record<string, any>);
  for (const p of (near.places ?? []) as { formattedAddress?: string; addressComponents?: Component[] }[]) {
    const d = describe(lat, lng, p.formattedAddress ?? '', p.addressComponents ?? [], false);
    if (d.city || d.pin_code) return { ...d, formatted: [d.locality, d.city, [d.state, d.pin_code].filter(Boolean).join(' ')].filter(Boolean).join(', ') };
  }
  return describe(lat, lng, '', []);
}
