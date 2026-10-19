// Every endpoint the One Local POS app calls. See ENDPOINTS.md for request/response and the Dart caller of each.
import { add } from './router.ts';
import { json } from './http.ts';
import { requireSignedIn, requireStaff } from './staff.ts';
import { userClient } from './db.ts';
import { anonKey, supabaseUrl } from './config.ts';
import { VERSION } from './version.ts';
import * as home from './modules/home.ts';
import * as orders from './modules/orders.ts';
import { rpcBatch, rpcOne } from './rpc.ts';
import { webhookRoutes } from './modules/secure/index.ts';
import { guestCall } from './guest-door.ts';
import { guestWeb } from './guest-web.ts';

// Health probe: version and whether the database answers. Uses the public key only; nothing secret is read or shown.
add('GET', '/health', async () => {
  const url = supabaseUrl(), key = anonKey();
  let reachable = false;
  if (url && key) {
    try { reachable = (await fetch(`${url}/auth/v1/health`, { headers: { apikey: key }, signal: AbortSignal.timeout(3000) })).ok; } catch { /* unreachable */ }
  }
  return json({ ok: true, version: VERSION, db: reachable ? 'reachable' : 'unreachable' });
});

// ---- the one generic endpoint (allowlist: src/rpc-manifest.ts). Everything below this block is the older per-feature routes.
add('POST', '/rpc/:name', rpcOne);
add('POST', '/rpc', rpcBatch);
for (const w of webhookRoutes) add('POST', w.path, w.handler);

// ---- the guest door and the guest menu page (table QR codes, 0561): no sign-in; see src/guest-door.ts and src/guest-web.ts
add('POST', '/guest/:name', guestCall);
for (const path of ['/t', '/t/:a', '/t/:a/:b', '/t/:a/:b/:c', '/t/:a/:b/:c/:d', '/t/:a/:b/:c/:d/:e']) add('GET', path, guestWeb);

// ---- (the sign-in check `me`, onboarding and setup moved to the gateway: POST /rpc/<name>, see src/rpc-manifest.ts)

// ---- section D: control centre
add('GET', '/api/partner/home', async request => {
  const staff = await requireStaff(request);   // membership only names the business; every read below runs as the caller (row-level security)
  return json(await home.homeSummary(staff, new URL(request.url).searchParams.get('location'), new Date(), userClient(request)));
});
add('GET', '/api/partner/home/feed', async request => {
  const staff = await requireStaff(request);
  const q = new URL(request.url).searchParams;
  return json(await home.homeFeed(staff, { days: Number(q.get('days') ?? 7), compare: q.get('compare') !== '0', location: q.get('location') }, new Date(), userClient(request)));
});

// ---- section E: counter bill and order lifecycle
const O = '/api/partner/pos-orders';
add('GET', O, async r => { await requireSignedIn(r, 'pos-orders'); return json(await orders.history(r)); });
add('GET', `${O}/catalog`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await orders.catalog(r)); });
add('POST', `${O}/quote`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await orders.quote(r)); });
add('POST', `${O}/checkout`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await orders.checkout(r, false)); });
add('POST', `${O}/hold`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await orders.checkout(r, true)); });
add('GET', `${O}/:id`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await orders.getOne(r, p.id)); });
add('POST', `${O}/:id/pay`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await orders.pay(r, p.id)); });
add('POST', `${O}/:id/cancel`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await orders.cancel(r, p.id)); });
add('POST', `${O}/:id/act`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await orders.actOn(r, p.id)); });
