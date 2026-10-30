// Request shapes for the map pin (src/modules/secure/maps.ts): address search, a chosen place, and the address at a pin.
import { z } from 'zod';

const lat = z.number({ message: 'Not a valid map position.' }).min(-90, 'Not a valid map position.').max(90, 'Not a valid map position.');
const lng = z.number({ message: 'Not a valid map position.' }).min(-180, 'Not a valid map position.').max(180, 'Not a valid map position.');
// Places API session token: one per search, so the typing and the chosen place are billed as one session
const session = z.string().regex(/^[A-Za-z0-9_-]{8,36}$/, 'Not a valid search session.').optional();

export const Search = z.object({
  q: z.string({ message: 'Type an address to search.' }).trim().min(2, 'Type at least 2 letters.').max(120, 'The search is too long.'),
  // where the map is: results near it come first
  lat: lat.optional(),
  lng: lng.optional(),
  session,
}).strict();

export const PlaceAsk = z.object({ place_id: z.string({ message: 'Unknown place.' }).regex(/^[\w-]{10,300}$/, 'Unknown place.'), session }).strict();

export const Point = z.object({ lat, lng }).strict();
