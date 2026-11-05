// THE GUEST DOOR: POST /guest/<name> for a customer who scanned a table's QR code (spec specs/table-qr-guest-menu, database 0561).
// Nobody is signed in here, so this door is separate from /rpc and has its own, much smaller allowlist:
//   1. the name must be on GUEST_DOOR (anything else is 404);
//   2. limits per network address (and per table code / session) before anything else is read;
//   3. the body is checked strictly (zod, no extra keys, 16 KB at most);
//   4. the database function is called with the service-role key, because the guest functions are executable by service_role ONLY (never
//      anon, never authenticated): nobody can reach them around these limits with the public key. The function itself checks the code /
//      session and only ever answers about the session's own table, outlet and business. The gateway adds a hash of the network address
//      (never the address) so the database can apply its own per-address limit.
// No business rule lives here: what may be ordered, the limits that matter and every state check are in the database.
import type { z } from 'zod';
import { db, mapDbError } from './db.ts';
import { clientIp, HttpError, json, limit, readBody, sha256 } from './http.ts';
import { parse } from './validate.ts';
import { withStorefrontLinks } from './modules/secure/storefront.ts';
import * as gst from './schemas/guest.ts';

// perMinute: per network address (and per subject unless subjectPerMinute says otherwise: a page every guest of a restaurant reads, like
// the live feed, is limited per address, not once for the whole restaurant)
export type GuestEntry = { alias: string; fn: string; args: z.ZodTypeAny; perMinute: number; subject: 'code' | 'session' | 'slug' | 'phone' | 'track'; subjectPerMinute?: number };

export const GUEST_DOOR: GuestEntry[] = [
  { alias: 'open', fn: 'guest_qr_open', args: gst.Open, perMinute: 30, subject: 'code' },
  { alias: 'menu', fn: 'guest_menu', args: gst.Session, perMinute: 60, subject: 'session' },
  { alias: 'send', fn: 'guest_order_send', args: gst.Send, perMinute: 12, subject: 'session' },
  { alias: 'status', fn: 'guest_order_status', args: gst.Session, perMinute: 120, subject: 'session' },
  // the table's bill and one feedback per visit (0572): read-only bill, feedback into the restaurant's inbox
  { alias: 'bill', fn: 'guest_bill', args: gst.Session, perMinute: 60, subject: 'session' },
  { alias: 'feedback', fn: 'guest_feedback', args: gst.Feedback, perMinute: 6, subject: 'session' },
  // the public menu link (0571): read-only menu of a live business by its address name, no table and no session
  { alias: 'card', fn: 'guest_menu_by_slug', args: gst.Card, perMinute: 60, subject: 'slug' },
  // the brand page's pre-order (0656): slots of a live business, a pre-order (limited per phone), its tracking by the link it returns
  { alias: 'slots', fn: 'gx_preorder_slots', args: gst.Slots, perMinute: 60, subject: 'slug' },
  { alias: 'preorder', fn: 'gx_preorder_place', args: gst.Preorder, perMinute: 6, subject: 'phone' },
  { alias: 'pretrack', fn: 'gx_preorder_status', args: gst.PreorderTrack, perMinute: 120, subject: 'track' },
  // the page's live order feed (0662): the restaurant's dishes of the last 20 minutes with the table label; no people, phones or money
  { alias: 'feed', fn: 'gx_live_feed', args: gst.Feed, perMinute: 30, subject: 'slug', subjectPerMinute: 600 },
];
// answers that carry the restaurant's guest page: its welcome picture is a storage path, turned into a short-lived link here
const WITH_PICTURES = new Set(['open', 'menu', 'card']);
const byAlias = new Map(GUEST_DOOR.map(e => [e.alias, e]));
export const guestFunctions = (): string[] => GUEST_DOOR.map(e => e.fn);

const PER_ADDRESS = 240;   // every guest call from one network address, per minute (a restaurant's guests may share one Wi-Fi)

/** POST /guest/:name */
export async function guestCall(request: Request, params: Record<string, string>): Promise<Response> {
  const entry = byAlias.get(params.name ?? '');
  if (!entry) throw new HttpError(404, 'Not found');
  const ip = clientIp(request, request.headers.get('x-ol-peer') ?? undefined);
  limit(ip, 'guest:any', PER_ADDRESS, 60_000);
  limit(ip, `guest:${entry.alias}`, entry.perMinute, 60_000);
  const args = parse(entry.args, await readBody(request, 16 * 1024)) as Record<string, unknown>;
  const subject = String(args[entry.subject]);
  limit(await sha256(subject), `guest:${entry.alias}:subject`, entry.subjectPerMinute ?? entry.perMinute, 60_000);
  // a scan and a pre-order carry a hash of the address (never the address): the database limits one phone / browser with it
  const p = entry.alias === 'open' || entry.alias === 'preorder' ? { ...args, client: ip === 'direct' ? null : (await sha256(`guest-client:${ip}`)).slice(0, 32) } : args;
  const { data, error } = await db().rpc(entry.fn, { p });
  if (error) {
    try { mapDbError(error); } catch (e) {
      // a guest whose session ended scans again: say so with a code the page can act on
      if (e instanceof HttpError && /^GUEST_EXPIRED:/.test(error.message ?? '')) e.code = 'session_expired';
      throw e;
    }
  }
  return json(WITH_PICTURES.has(entry.alias) && data ? await withStorefrontLinks(data) : data ?? null);
}
