// Every endpoint the VINII POS app calls. See ENDPOINTS.md for request/response and the Dart caller of each.
import { add } from './router.ts';
import { json, readBody } from './http.ts';
import { requireStaff } from './staff.ts';
import { me } from './modules/me.ts';
import * as onboarding from './modules/onboarding.ts';
import * as setup from './modules/setup.ts';
import * as home from './modules/home.ts';
import * as orders from './modules/orders.ts';
import * as catalogue from './modules/catalogue.ts';
import * as grn from './modules/grn.ts';

add('GET', '/health', () => json({ ok: true }));

// ---- sign-in check
add('GET', '/api/partner/me', async request => json(await me(await requireStaff(request))));

// ---- section B: onboarding (any signed-in person; no store yet)
const ob = (fn: (u: string, body: unknown) => Promise<unknown>) => async (request: Request) => json(await fn(await onboarding.applicant(request), await readBody(request)));
add('GET', '/api/onboarding/application', async r => json(await onboarding.getApplication(await onboarding.applicant(r))));
add('GET', '/api/onboarding/taxonomy', async r => { await onboarding.applicant(r); return json(onboarding.lists()); });
add('PUT', '/api/onboarding/profile', ob(onboarding.saveProfile));
add('PUT', '/api/onboarding/plan', ob(onboarding.choosePlan));
add('PUT', '/api/onboarding/address', ob(onboarding.saveAddress));
add('PUT', '/api/onboarding/tax', ob(onboarding.saveTax));
add('PUT', '/api/onboarding/identity', ob(onboarding.saveIdentity));
add('PUT', '/api/onboarding/bank', ob(onboarding.saveBank));
add('PUT', '/api/onboarding/consents', ob(onboarding.saveConsents));
add('PUT', '/api/onboarding/agreement', ob(onboarding.acceptAgreement));
add('POST', '/api/onboarding/submit', async r => json(await onboarding.submit(await onboarding.applicant(r))));
add('POST', '/api/onboarding/documents/upload', ob(onboarding.askUpload));
add('POST', '/api/onboarding/documents', ob(onboarding.confirmUpload));
add('GET', '/api/onboarding/documents/:kind/preview', async (r, p) => json(await onboarding.previewUrl(await onboarding.applicant(r), p.kind)));

// ---- section C: workspace setup (the database decides whether the caller owns an approved business)
const st = (fn: (u: string, body: unknown) => Promise<unknown>) => async (request: Request) => json(await fn(await setup.partner(request), await readBody(request)));
add('GET', '/api/setup/state', async r => json(await setup.getSetup(await setup.partner(r))));
add('PUT', '/api/setup/plan', st(setup.confirmPlan));
add('PUT', '/api/setup/payment', st(setup.savePayment));
add('PUT', '/api/setup/tax', st(setup.saveTax));
add('PUT', '/api/setup/pos', st(setup.registerPos));
add('POST', '/api/setup/staff', st(setup.inviteStaff));
add('POST', '/api/setup/items', st(setup.addItem));
add('PUT', '/api/setup/listing', st(setup.saveListing));
add('PUT', '/api/setup/fulfilment', st(setup.saveFulfilment));
add('POST', '/api/setup/tour', st(setup.tourSeen));
add('POST', '/api/setup/complete', async r => json(await setup.complete(await setup.partner(r))));
add('POST', '/api/setup/images/upload', st(setup.askImageUpload));
add('POST', '/api/setup/images', st(setup.confirmImageUpload));

// ---- section D: control centre
add('GET', '/api/partner/home', async request => {
  const staff = await requireStaff(request);
  return json(await home.homeSummary(staff, new URL(request.url).searchParams.get('location')));
});
add('GET', '/api/partner/home/feed', async request => {
  const staff = await requireStaff(request);
  const q = new URL(request.url).searchParams;
  return json(await home.homeFeed(staff, { days: Number(q.get('days') ?? 7), compare: q.get('compare') !== '0', location: q.get('location') }));
});

// ---- section E: counter bill and order lifecycle
const O = '/api/partner/pos-orders';
add('GET', O, async r => { await requireStaff(r); return json(await orders.history(r)); });
add('GET', `${O}/catalog`, async r => { await requireStaff(r); return json(await orders.catalog(r)); });
add('POST', `${O}/quote`, async r => { await requireStaff(r); return json(await orders.quote(r)); });
add('POST', `${O}/checkout`, async r => { await requireStaff(r); return json(await orders.checkout(r, false)); });
add('POST', `${O}/hold`, async r => { await requireStaff(r); return json(await orders.checkout(r, true)); });
add('GET', `${O}/:id`, async (r, p) => { await requireStaff(r); return json(await orders.getOne(r, p.id)); });
add('POST', `${O}/:id/pay`, async (r, p) => { await requireStaff(r); return json(await orders.pay(r, p.id)); });
add('POST', `${O}/:id/cancel`, async (r, p) => { await requireStaff(r); return json(await orders.cancel(r, p.id)); });
add('POST', `${O}/:id/act`, async (r, p) => json(await orders.actOn(r, await requireStaff(r), p.id)));

// ---- section G: store catalogue and GRN matching (static paths first, then :id)
const C = '/api/partner/catalogue';
add('GET', C, async r => { await requireStaff(r); return json(await catalogue.list(r)); });
add('GET', `${C}/search`, async r => { await requireStaff(r); return json(await catalogue.search(r)); });
add('GET', `${C}/lookup`, async r => { await requireStaff(r); return json(await catalogue.lookup(r)); });
add('POST', C, async r => { await requireStaff(r); return json(await catalogue.create(r)); });
add('GET', `${C}/:id`, async (r, p) => { await requireStaff(r); return json(await catalogue.getOne(r, p.id)); });
add('PUT', `${C}/:id`, async (r, p) => { await requireStaff(r); return json(await catalogue.update(r, p.id)); });

const G = '/api/partner/grn';
add('GET', G, async r => { await requireStaff(r); return json(await grn.list(r)); });
add('POST', `${G}/open`, async r => { await requireStaff(r); return json(await grn.open(r)); });
add('GET', `${G}/:id`, async (r, p) => { await requireStaff(r); return json(await grn.view(r, p.id)); });
add('GET', `${G}/:id/matching`, async (r, p) => { await requireStaff(r); return json(await grn.matching(r, p.id)); });
add('PUT', `${G}/:id/invoice`, async (r, p) => { await requireStaff(r); return json(await grn.saveInvoice(r, p.id)); });
add('PUT', `${G}/:id/costs`, async (r, p) => { await requireStaff(r); return json(await grn.saveCosts(r, p.id)); });
add('POST', `${G}/:id/resolve`, async (r, p) => { await requireStaff(r); return json(await grn.resolve(r, p.id)); });
add('POST', `${G}/:id/request-approval`, async (r, p) => { await requireStaff(r); return json(await grn.requestApproval(r, p.id)); });
add('POST', `${G}/:id/decide`, async (r, p) => { await requireStaff(r); return json(await grn.decide(r, p.id)); });
