// Every endpoint the One Local POS app calls. See ENDPOINTS.md for request/response and the Dart caller of each.
import { add } from './router.ts';
import { json } from './http.ts';
import { requireSignedIn, requireStaff } from './staff.ts';
import { userClient } from './db.ts';
import { anonKey, supabaseUrl } from './config.ts';
import { VERSION } from './version.ts';
import * as home from './modules/home.ts';
import * as orders from './modules/orders.ts';
import * as sell from './modules/sell.ts';
import * as catalogue from './modules/catalogue.ts';
import * as grn from './modules/grn.ts';
import { rpcBatch, rpcOne } from './rpc.ts';
import { webhookRoutes } from './modules/secure/index.ts';

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

// ---- section F (sell) and G (catalogue, GRN): run as the caller; they move onto /rpc once their labels and receipt text leave src/modules/sell.ts (see specs/pos-figma-rebuild/PLAN-2)
const S = '/api/partner/sell';
add('GET', `${S}/catalog`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.catalog(r)); });
add('POST', `${S}/orders/:id/split-pay`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.splitPay(r, p.id)); });
add('POST', `${S}/orders/:id/refund`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.refundOrder(r, p.id)); });
add('POST', `${S}/orders/:id/attempts`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.recordAttempt(r, p.id)); });
add('POST', `${S}/orders/:id/online-checkout`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.onlineCheckout(r, p.id)); });
add('GET', `${S}/receipts`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.receipts(r)); });
add('GET', `${S}/returns`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.returnsList(r)); });
add('POST', `${S}/returns`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.returnCreate(r)); });
add('POST', `${S}/returns/:id/decide`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.returnDecide(r, p.id)); });
add('POST', `${S}/returns/:id/refund`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await sell.returnRefund(r, p.id)); });
add('GET', `${S}/coupons`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.couponsList(r)); });
add('POST', `${S}/coupons`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await sell.couponSave(r)); });

const C = '/api/partner/catalogue';
add('GET', C, async r => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.list(r)); });
add('GET', `${C}/search`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.search(r)); });
add('GET', `${C}/lookup`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.lookup(r)); });
add('POST', C, async r => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.create(r)); });
add('GET', `${C}/:id`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.getOne(r, p.id)); });
add('PUT', `${C}/:id`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await catalogue.update(r, p.id)); });
const G = '/api/partner/grn';
add('GET', G, async r => { await requireSignedIn(r, 'pos-orders'); return json(await grn.list(r)); });
add('POST', `${G}/open`, async r => { await requireSignedIn(r, 'pos-orders'); return json(await grn.open(r)); });
add('GET', `${G}/:id`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.view(r, p.id)); });
add('GET', `${G}/:id/matching`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.matching(r, p.id)); });
add('PUT', `${G}/:id/invoice`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.saveInvoice(r, p.id)); });
add('PUT', `${G}/:id/costs`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.saveCosts(r, p.id)); });
add('POST', `${G}/:id/resolve`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.resolve(r, p.id)); });
add('POST', `${G}/:id/request-approval`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.requestApproval(r, p.id)); });
add('POST', `${G}/:id/decide`, async (r, p) => { await requireSignedIn(r, 'pos-orders'); return json(await grn.decide(r, p.id)); });
