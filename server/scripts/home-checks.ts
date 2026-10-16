// VINII POS control centre (src/modules/home.ts, GET /api/partner/home and /home/feed) against the LOCAL Supabase from
// .env. Covers: today's sales from bills only (cancelled excluded), top items, active orders with the One Local
// delivery status and ETA, catalogue gaps, low stock, KOT made on a cancelled bill, goods received, the 7-day feed with the
// previous period, and tenancy: another organisation sees none of it, a person assigned to one outlet sees only that outlet,
// and naming another organisation's outlet is a 404. With BASE_URL set (default http://localhost:8090 if reachable) it also calls the running POS server over HTTP.
// Needs Docker with the local stack (supabase_db_onelocal-dev): fixture bills are moved to paid/cancelled through status_gate().
// Fixtures: each run makes its own organisations (slug zz-home-checks-<run>) and users (zz-home-*-<run>@example.test), because bills are
// part of the financial record and the database refuses to delete them. Bills are tagged notes = 'ZZ-TEST partner-home-checks'.
// Run from server/:  npm run dev (other terminal), then  node scripts/home-checks.ts   (BASE_URL=http://localhost:8090 for the HTTP part)
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';

const localEnv: Record<string, string> = {};
for (const line of readFileSync(`${process.cwd()}/.env`, 'utf8').split('\n')) { const m = line.match(/^([A-Z_]+)=(.*)$/); if (m) localEnv[m[1]] = m[2]; }
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(localEnv.SUPABASE_URL ?? '')) throw new Error('refusing to run: not a local database');
for (const k of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY', 'ALLOW_REMOTE']) delete process.env[k];
for (const k of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY']) if (localEnv[k]) process.env[k] = localEnv[k];
const RUN = randomBytes(3).toString('hex');
const TAG = 'ZZ-TEST partner-home-checks';
const BASE_URL = (process.env.BASE_URL ?? '').replace(/\/+$/, '');

let passed = 0;
const check = (what: string, ok: boolean | undefined, detail?: unknown) => { if (!ok) { console.error('FAIL ', what, JSON.stringify(detail ?? '')); process.exitCode = 1; } else { passed++; console.log('ok   ', what); } };
async function refused(what: string, status: number, run: () => Promise<unknown>) {
  try { await run(); check(what, false, 'was accepted'); } catch (e) { const x = e as { status?: number; detail?: string; message?: string }; check(what, x.status === status, `${x.status} ${x.detail ?? x.message}`); }
}

async function main() {
  const { db } = await import('../src/db.ts');
  const home = await import('../src/modules/home.ts');
  const d = db();
  const must = (r: { data: any; error: { message: string } | null }): any => { if (r.error) throw new Error(r.error.message); return r.data; };

  // ---------------- pure helpers ----------------
  check('start of an IST day is 18:30 UTC the day before', home.startOfLocalDay('Asia/Kolkata', '2026-10-05').toISOString() === '2026-10-04T18:30:00.000Z');
  check('local date in IST flips at 18:30 UTC', home.localDate('Asia/Kolkata', new Date('2026-10-04T18:29:00Z')) === '2026-10-04' && home.localDate('Asia/Kolkata', new Date('2026-10-04T18:30:00Z')) === '2026-10-05');
  check('addDays crosses months', home.addDays('2026-10-31', 1) === '2026-11-01' && home.addDays('2026-03-01', -1) === '2026-02-28');
  check('kind: Retail = store, Restaurant = restaurant, unknown falls back to the outlet kind',
    home.kindOf('Retail', 'restaurant') === 'store' && home.kindOf('Restaurant', null) === 'restaurant' && home.kindOf(null, 'restaurant') === 'restaurant' && home.kindOf(null, null) === 'store');
  check('One Local status speaks for the bill (out = out_for_delivery); POS sent_to_kitchen = preparing',
    home.cardStatus('sent_to_kitchen', 'out') === 'out_for_delivery' && home.cardStatus('sent_to_kitchen', null) === 'preparing' && home.cardStatus('new', null) === 'new');
  check('fulfilment: online with an address is delivery, without is pickup', home.fulfilment('online', true) === 'delivery' && home.fulfilment('online', false) === 'pickup' && home.fulfilment('dine_in', false) === 'dine_in');

  // ---------------- fixtures ----------------
  async function org(slug: string, name: string, domain: string) {
    const o = must(await d.from('organizations').insert({ name, slug, type: 'franchise', business_domain: domain }).select('id, name').single());
    return o as { id: string; name: string };
  }
  async function outlet(organizationId: string, name: string) {
    // A new organisation comes with a '<name> - Main' outlet; the first outlet asked for reuses (renames) it.
    const found = (await d.from('locations').select('id').eq('organization_id', organizationId).like('name', '% - Main').maybeSingle()).data;
    if (found) must(await d.from('locations').update({ name }).eq('id', found.id));
    return (found ?? must(await d.from('locations').insert({ organization_id: organizationId, name, code: `ZZ-${name.replace(/[^A-Za-z0-9]/g, '')}`.slice(0, 20), kind: 'restaurant', status: 'active', timezone: 'Asia/Kolkata' }).select('id').single())).id as string;
  }
  const users: Record<string, string> = {};
  async function user(email: string, role: string, organizationId: string, organizationName: string, onlyAt?: string) {
    const password = `Zz-${randomBytes(12).toString('base64url')}`;
    // generateLink answers with the existing user (listUsers can come back empty on this local stack).
    const link = await d.auth.admin.generateLink({ type: 'magiclink', email });
    let id = link.data?.user?.id;
    if (!id) {
      const made = await d.auth.admin.createUser({ email, password, email_confirm: true });
      if (made.error) throw new Error(`create ${email}: ${made.error.message}`);
      id = made.data.user!.id;
    }
    const set = await d.auth.admin.updateUserById(id, { password, email_confirm: true });
    if (set.error) throw new Error(`password ${email}: ${set.error.message}`);
    users[email] = password;
    const roleId = must(await d.from('roles').select('id').eq('slug', role).single()).id;
    const existing = (await d.from('org_users').select('id').eq('organization_id', organizationId).eq('user_id', id).maybeSingle()).data as { id: string } | null;
    const ouId: string = existing?.id ?? must(await d.from('org_users').insert({ organization_id: organizationId, user_id: id, role_id: roleId, email, full_name: email, status: 'active' }).select('id').single()).id;
    must(await d.from('org_user_locations').delete().eq('user_id', id).eq('organization_id', organizationId));
    if (onlyAt) must(await d.from('org_user_locations').insert({ organization_id: organizationId, org_user_id: ouId, user_id: id, location_id: onlyAt }));
    return { userId: id, email, name: email, role, organizationId, organizationName };
  }

  const A = await org(`zz-home-checks-${RUN}`, 'ZZ Home checks', 'Restaurant');
  const B = await org(`zz-home-checks-b-${RUN}`, 'ZZ Home checks B', 'Retail');
  const a1 = await outlet(A.id, 'ZZ Main Branch');
  const a2 = await outlet(A.id, 'ZZ Second Branch');
  const b1 = await outlet(B.id, 'ZZ B Branch');
  const owner = await user(`zz-home-owner-${RUN}@example.test`, 'org_owner', A.id, A.name);
  const branch2 = await user(`zz-home-branch2-${RUN}@example.test`, 'manager', A.id, A.name, a2);
  const ownerB = await user(`zz-home-owner-b-${RUN}@example.test`, 'org_owner', B.id, B.name);
  must(await d.from('ol_merchant_channels').insert({ organization_id: A.id, accepting: true }));

  const now = new Date();
  const hoursAgo = (h: number) => new Date(now.getTime() - h * 3600_000).toISOString();
  const todayStart = home.startOfLocalDay('Asia/Kolkata', home.localDate('Asia/Kolkata', now));
  // Placed today but never before today's local midnight (the check may run just after midnight).
  const earlyToday = new Date(Math.max(todayStart.getTime() + 60_000, now.getTime() - 3600_000)).toISOString();
  let no = Number((await d.from('orders').select('order_no').eq('organization_id', A.id).order('order_no', { ascending: false }).limit(1)).data?.[0]?.order_no ?? 0);
  const moves: [string, string, string, number][] = [];
  async function bill(o: { org?: string; loc: string | null; total: number; status: string; channel?: string; at?: string; pax?: number; items?: [string, number, number][] }) {
    const id = must(await d.from('orders').insert({
      organization_id: o.org ?? A.id, location_id: o.loc, order_no: ++no, display_no: `ZZ-${RUN}-${no}`, channel: o.channel ?? 'dine_in', status: 'new',
      subtotal: o.total, gst_amount: 0, total: o.total, ...(o.pax == null ? {} : { guest_count: o.pax }), created_at: o.at ?? earlyToday, notes: TAG,
    }).select('id').single()).id as string;
    for (const [name, qty, price] of o.items ?? []) must(await d.from('order_items').insert({ order_id: id, name, qty, unit_price: price, status: 'pending' }));
    // Lines go on while the bill is open; the database freezes a paid or cancelled bill, and only the status gate may move it.
    if (o.status !== 'new') moves.push([id, o.status, o.org ?? A.id, o.total]);
    return id;
  }
  await bill({ loc: a1, total: 340, status: 'paid', pax: 2, items: [['Cold Coffee', 2, 120], ['Fries', 1, 100]] });
  await bill({ loc: a1, total: 160, status: 'sent_to_kitchen', items: [['Cold Coffee', 1, 120], ['Fries', 1, 40]] });
  const outFor = await bill({ loc: a1, total: 820, status: 'sent_to_kitchen', channel: 'online', items: [['Pasta', 4, 205]] });
  must(await d.from('ol_orders').insert({ organization_id: A.id, pos_order_id: outFor, customer_hash: `zz-${RUN}`, status: 'out', total: 820, subtotal: 820, delivery_fee: 0, items: [], delivery_address: { line: 'ZZ' }, promised_eta_at: new Date(now.getTime() + 12 * 60_000).toISOString(), payment_method: 'cod', payment_status: 'pending' }));
  const voided = await bill({ loc: a1, total: 999, status: 'cancelled', items: [['Burger', 3, 333]] });
  must(await d.from('kot_tickets').insert({ organization_id: A.id, order_id: voided, kot_no: 1, station: 'main', status: 'delivered' }));
  await bill({ loc: a2, total: 500, status: 'delivered', items: [['Thali', 2, 250]] });
  await bill({ loc: a1, total: 700, status: 'paid', at: hoursAgo(24 * 3) });   // earlier this week
  await bill({ loc: a1, total: 300, status: 'paid', at: hoursAgo(24 * 9) });   // the week before
  await bill({ org: B.id, loc: b1, total: 4444, status: 'paid', items: [['Rice 5kg', 1, 4444]] });
  // Paid bills get their cash payment first (the database refuses a paid bill it cannot see paid). Status moves in one transaction on the local database, each armed by status_gate() as the POS functions do.
  const sqlMoves = moves.map(([id, st, orgId, total]) => (st === 'paid' ? `insert into public.payments (organization_id, order_id, method, amount) values ('${orgId}', '${id}', 'cash', ${total});\n` : '') + `select public.status_gate('orders', '${id}', 'set_${st}'); update public.orders set status = '${st}' where id = '${id}';`).join('\n');
  execFileSync('docker', ['exec', '-i', 'supabase_db_onelocal-dev', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'], { input: `begin;\n${sqlMoves}\ncommit;\n` });
  must(await d.from('menu_items').insert([
    { organization_id: A.id, name: 'Cold Coffee', price: 120, description: 'Iced', image_url: 'https://example.test/c.jpg' },
    { organization_id: A.id, name: 'Fries', price: 100, description: '' },
    { organization_id: A.id, name: 'Pasta', price: 205 },
  ]));
  must(await d.from('pos_raw_materials').insert([
    { row_id: randomUUID(), organization_id: A.id, location_id: a1, id: `zz-milk-${RUN}`, code: `zz-milk-${RUN}`, category: 'ZZ', name: 'Amul Gold', unit: 'L', stock_qty: 0, reorder_level: 5 },
    { row_id: randomUUID(), organization_id: A.id, location_id: a1, id: `zz-bacon-${RUN}`, code: `zz-bacon-${RUN}`, category: 'ZZ', name: 'Bacon Pkt', unit: 'pkt', stock_qty: 2, reorder_level: 4 },
    { row_id: randomUUID(), organization_id: A.id, location_id: a1, id: `zz-flour-${RUN}`, code: `zz-flour-${RUN}`, category: 'ZZ', name: 'Flour', unit: 'kg', stock_qty: 40, reorder_level: 10 },
    { row_id: randomUUID(), organization_id: A.id, location_id: a2, id: `zz-rice-${RUN}`, code: `zz-rice-${RUN}`, category: 'ZZ', name: 'Rice', unit: 'kg', stock_qty: 1, reorder_level: 10 },
  ]));
  must(await d.from('pos_goods_receipts').insert({ row_id: randomUUID(), organization_id: A.id, location_id: a1, id: `zz-grn-${RUN}`, po_number: 'ZZ-PO', received_at: earlyToday, subtotal: 2500, tax: 0, total: 2500 }));

  // ---------------- 1. the dashboard, whole organisation ----------------
  const h = await home.homeSummary(owner);
  check('owner sees both outlets; header says All outlets (2)', h.outlets.length === 2 && h.outlet.name === 'All outlets (2)', h.outlet);
  check('restaurant kind from business_domain; open from ol_merchant_channels', h.outlet.kind === 'restaurant' && h.outlet.is_open === true);
  check('sales today = 340 + 160 + 820 + 500 (cancelled 999 and older bills excluded), 4 orders', h.sales.total === 1820 && h.sales.orders === 4, h.sales);
  check('settled bills 2 (paid + delivered), pax 2+1+1+1 (guest_count defaults to 1), units 2+1+1+1+4+2 = 11', h.sales.settled === 2 && h.sales.pax === 5 && h.sales.units === 11, h.sales);
  check('active orders: 2 still moving', h.sales.active === 2 && h.active_orders.length === 2, h.active_orders);
  const card = h.active_orders.find(o => o.id === outFor);
  check('delivery card: out for delivery, delivery, 4 items, 820, ETA about 12 min', card?.status === 'out_for_delivery' && card.fulfilment === 'delivery' && card.items === 4 && card.total === 820 && card.eta_minutes != null && card.eta_minutes >= 10 && card.eta_minutes <= 12, card);
  check('dine-in card: preparing, no ETA', h.active_orders.some(o => o.id !== outFor && o.status === 'preparing' && o.eta_minutes === null));
  check('top items by quantity: Pasta 4 (820), Cold Coffee 3 (360), then Fries or Thali',
    h.top_items[0]?.name === 'Pasta' && h.top_items[0].qty === 4 && h.top_items[0].revenue === 820 && h.top_items[1]?.name === 'Cold Coffee' && h.top_items[1].revenue === 360 && h.top_items.length === 3, h.top_items);
  check('catalogue: 3 items, 2 without description, 2 without photo, 3 without recipe', h.catalogue.items === 3 && h.catalogue.missing_descriptions === 2 && h.catalogue.missing_photos === 2 && h.catalogue.missing_recipes === 3, h.catalogue);
  check('stock: tracked; out first (Amul Gold), then low by quantity (Rice 1, Bacon 2); Flour is fine',
    h.stock_tracked && h.stock_low_count === 3 && h.stock_health[0].name === 'Amul Gold' && h.stock_health[0].level === 'out' && h.stock_health[1].name === 'Rice' && h.stock_health[2].name === 'Bacon Pkt' && !h.stock_health.some(s => s.name === 'Flour'), h.stock_health);
  check('leakage: 1 KOT on a cancelled bill; GRN 1 bill of 2500; expenses and price trend have no source (null)',
    h.insights.kot_not_billed === 1 && h.insights.grn.bills === 1 && h.insights.grn.amount === 2500 && h.insights.expenses === null && h.insights.price_trend === null, h.insights);
  check('nothing from organisation B leaks in', !JSON.stringify(h).includes('4444') && !JSON.stringify(h).includes('Rice 5kg'));

  // ---------------- 2. one outlet ----------------
  const one = await home.homeSummary(owner, a2);
  check('?location narrows to one outlet: its name, 500 sales, 1 order, its stock only', one.outlet.name === 'ZZ Second Branch' && one.sales.total === 500 && one.sales.orders === 1 && one.stock_health.length === 1 && one.stock_health[0].name === 'Rice', one);
  const assigned = await home.homeSummary(branch2);
  check('a manager assigned to the second branch sees only it, without asking', assigned.outlets.length === 1 && assigned.outlet.name === 'ZZ Second Branch' && assigned.sales.total === 500 && assigned.active_orders.length === 0, assigned.outlet);
  await refused('that manager cannot open the main branch (404)', 404, () => home.homeSummary(branch2, a1));
  await refused('another organisation\'s outlet id is a 404', 404, () => home.homeSummary(owner, b1));
  await refused('a malformed outlet id is a 400', 400, () => home.homeSummary(owner, "x' or 1=1"));

  // ---------------- 3. organisation B ----------------
  const hb = await home.homeSummary(ownerB);
  check('organisation B: its own outlet and bill only, store kind, open status unknown (no channel row)',
    hb.outlet.name === 'ZZ B Branch' && hb.sales.total === 4444 && hb.sales.orders === 1 && hb.outlet.kind === 'store' && hb.outlet.is_open === null && hb.catalogue.missing_recipes === null && !hb.stock_tracked, hb);

  // ---------------- 4. the feed ----------------
  const f = await home.homeFeed(owner, { days: 7, compare: true });
  check('feed 7 days: net sales 1820 + 700, 5 bills, 3 completed (paid, delivered, paid)', f.period.net_sales === 2520 && f.period.orders === 5 && f.period.orders_completed === 3, f.period);
  check('feed: average bill 504, previous week 300 from one bill', f.period.aov === 504 && f.previous?.net_sales === 300 && f.previous?.orders === 1, f.previous);
  check('feed: 7 daily slots ending today, today 1820, totals add up', f.daily.length === 7 && f.daily[6].date === f.date && f.daily[6].sales === 1820 && f.daily.reduce((n, x) => n + x.sales, 0) === 2520, f.daily);
  check('feed: today 1820 from 4 orders, open', f.today.sales === 1820 && f.today.orders === 4 && f.today.is_open === true);
  const f1 = await home.homeFeed(owner, { days: 1, compare: false });
  check('feed 1 day without compare: no previous block', f1.previous === null && f1.daily.length === 1 && f1.period.net_sales === 1820);
  await refused('feed refuses 5 days (400)', 400, () => home.homeFeed(owner, { days: 5, compare: true }));
  const fb = await home.homeFeed(branch2, { days: 7, compare: true });
  check('feed for the second-branch manager: 500 only', fb.period.net_sales === 500 && fb.scope === 'ZZ Second Branch', fb.period);

  // ---------------- 5. over HTTP (the running dev server) ----------------
  if (BASE_URL) {
    const anon = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || '';
    const token = async (email: string) => {
      const r = await fetch(`${process.env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: anon, 'content-type': 'application/json' }, body: JSON.stringify({ email, password: users[email] }) });
      return (await r.json()).access_token as string;
    };
    const get = (path: string, tok?: string) => fetch(`${BASE_URL}/api/partner${path}`, { headers: tok ? { Authorization: `Bearer ${tok}` } : {} });
    const tOwner = await token(owner.email);
    const tB = await token(ownerB.email);
    check('HTTP: no token is 401', (await get('/home')).status === 401);
    const r = await get('/home', tOwner);
    const body = await r.json();
    check('HTTP: owner gets 200 with the same sales', r.status === 200 && body.sales?.total === 1820, { status: r.status, body: body.detail ?? body.sales });
    const rb = await get(`/home?location=${a1}`, tB);
    check('HTTP: organisation B naming A\'s outlet is 404', rb.status === 404);
    const rf = await get('/home/feed?days=7&compare=1', tOwner);
    const fbody = await rf.json();
    check('HTTP: feed 200, 7 days, net 2520', rf.status === 200 && fbody.period?.net_sales === 2520 && fbody.daily?.length === 7, fbody.period ?? fbody);
    check('HTTP: feed refuses days=2 with 400', (await get('/home/feed?days=2', tOwner)).status === 400);
  } else {
    console.log('skip  HTTP checks (set BASE_URL to the running dev server)');
  }

  console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`);
}

main().catch(e => { console.error(e); process.exit(1); });
