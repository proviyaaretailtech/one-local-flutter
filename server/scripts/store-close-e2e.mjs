// E2E (database 0665), over HTTP against the standalone POS server, as real signed-in staff of a store and of a service business:
//  1. a paid counter bill is not an online order waiting to be accepted;
//  2. Home and the feed count paid bills less refunds, and an unpaid held bill is no sale;
//  3. Close day: a closed day refuses sales, refunds and cash entries until it is reopened, then late sales are in the day end and it is counted again;
//  4. the next day opens with the counted cash; an exact opening count records a shortage or excess, in the feed too;
//  5. a store with one login may approve its own stock adjustment, a store with a second approver may not;
//  6. a service business, which shares smoney_register and smoney_close_day, keeps its old behaviour. LOCAL ONLY.
// The local database has no store Money functions of its own: load them from the hosted export first (see hosted-push/run/43_*).
// Usage (from one-local-flutter/server, server running):  node scripts/store-close-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const DB = process.env.OL_DB ?? 'supabase_db_onelocal-local-db';
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).trim().replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q0 => { const q = q0.split('\n').join(' '); return execSync(`docker exec ${DB} psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim(); };
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 700)); } };

const run = Date.now().toString(36);
async function staff(org, role, tag) {
  const email = `zz-close-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function call(url, who, method, body, key) {
  const r = await fetch(url, { method, headers: { Authorization: `Bearer ${who.token}`, ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const rpc = (who, fn, body = {}, key) => call(`${API}/rpc/${fn}`, who, 'POST', body, key);
const api = (who, method, path, body, key) => call(`${API}/api/partner${path}`, who, method, body, key);
const k = () => `e2e-${randomUUID()}`;
const newOrg = (tag, domain) => {
  const org = randomUUID();
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ CLOSE ${tag} ${run}','zz-close-${tag}-${run}','franchise','${domain}')`);
  sql(`insert into org_bill_settings(organization_id,service_charge_pct,round_off_enabled,gst_registered,prices_include_tax) values ('${org}',0,false,false,false)`);
  return { org, loc: sql(`select id from locations where organization_id='${org}' order by created_at limit 1`) };
};
const item = (org, name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,sku,price,is_available) values ('${id}','${org}','${name}','${name.replace(/\W/g, '').toUpperCase()}${run}',${price},true)`); return id; };
const sell = (who, id, qty, tendered) => api(who, 'POST', '/pos-orders/checkout', { lines: [{ menu_item_id: id, qty }], method: 'cash', tendered }, k());

try {
  const S = newOrg('s', 'Retail');
  const OWN = await staff(S.org, 'org_owner', 'own'), BIL = await staff(S.org, 'biller', 'bil');
  const cola = item(S.org, 'Cola', 40);
  ok('a store owner and a biller signed in', OWN.token && BIL.token);

  // ---- 1. a paid counter bill
  let sold = await sell(OWN, cola, 2, 100);
  ok('a ₹80 cash bill is paid', sold.s === 200 && sold.j.id, sold);
  const hist = await api(OWN, 'GET', '/pos-orders');
  const card = (hist.j.orders ?? []).find(o => o.id === sold.j.id);
  ok('it is a counter sale, not a new online order', card?.state === 'counter' && card?.status === 'completed', card);
  ok('its delivery line says it was completed at the counter', card?.delivery_status === 'Completed at counter', card);

  // ---- 2. sales
  const held = await api(OWN, 'POST', '/pos-orders/hold', { lines: [{ menu_item_id: cola, qty: 5 }] }, k());
  ok('a ₹200 bill is held unpaid', held.s === 200, held);
  let r = await rpc(OWN, 'pos_refund', { order_id: sold.j.id, amount: 40, method: 'cash', kind: 'goodwill', reason: 'Goodwill gesture' }, k());
  ok('₹40 refunded on the ₹80 bill', r.s === 200, r);
  const home = await api(OWN, 'GET', '/home');
  ok('Home: sales are ₹40 (paid less refunds, no held bill), from 1 bill', home.j.sales?.total === 40 && home.j.sales?.orders === 1, home.j.sales);
  let feed = await api(OWN, 'GET', '/home/feed?days=7&compare=false');
  ok('Feed: net sales ₹40, 1 order, average ₹40', feed.j.period?.net_sales === 40 && feed.j.period?.orders === 1 && feed.j.period?.aov === 40, feed.j.period);
  ok('Feed: today ₹40, the daily chart agrees', feed.j.today?.sales === 40 && feed.j.daily?.at(-1)?.sales === 40, feed.j.today);

  // ---- 3. Close day, reopen
  let reg = await rpc(OWN, 'smoney_register');
  ok('the register: ₹80 cash sales, ₹40 refund, ₹40 expected, 1 bill still unpaid', reg.j.sales_minor === 8000 && reg.j.refunds_minor === 4000 && reg.j.expected_minor === 4000 && reg.j.open_bills?.count === 1 && reg.j.open_bills?.due_minor === 20000, reg.j);
  ok('nobody may reopen an open day', reg.j.can_reopen === false, reg.j);
  r = await rpc(OWN, 'smoney_close_day', { counted_minor: 3000 });
  ok('Close day, counted ₹30: short ₹10', r.s === 200 && r.j.closed?.difference_minor === -1000, r);
  ok('the shortage is the count, not cash paid out', r.j.cash_out_minor === 0 && r.j.expected_minor === 4000, r.j);
  ok('the owner may reopen it', r.j.can_reopen === true, r.j);
  r = await sell(OWN, cola, 1, 40);
  ok('a sale on the closed day is refused with day_ended', r.s === 409 && r.j.code === 'day_ended', r);
  r = await sell(BIL, cola, 1, 40);
  ok('for the biller too', r.s === 409 && r.j.code === 'day_ended', r);
  r = await rpc(OWN, 'pos_refund', { order_id: sold.j.id, amount: 10, method: 'cash', kind: 'goodwill', reason: 'Goodwill gesture' }, k());
  ok('a refund on the closed day is refused', r.s === 409 && r.j.code === 'day_ended', r);
  r = await rpc(OWN, 'smoney_record', { direction: 'in', kind: 'other_in', category: 'Other', method: 'cash', amount_minor: 500, note: 'Late' }, k());
  ok('a cash entry on the closed day is refused', r.s === 409 && r.j.code === 'day_ended', r);
  r = await rpc(BIL, 'smoney_reopen_day', { reason: 'Late customer' });
  ok('a biller cannot reopen', r.s === 403, r);
  r = await rpc(OWN, 'smoney_reopen_day', { reason: 'x' });
  ok('reopening needs a reason', r.s === 400 || r.s === 422, r);
  r = await rpc(OWN, 'smoney_reopen_day', { reason: 'Late customer' });
  ok('the owner reopens: no close, one reopen on record', r.s === 200 && r.j.closed === null && r.j.reopens?.length === 1 && r.j.reopens[0].reason === 'Late customer', r);
  ok('the ₹10 shortage no longer stands', sql(`select count(*) from money_store_entries where organization_id='${S.org}' and status='posted' and kind='cash_difference'`) === '0');
  r = await sell(OWN, cola, 1, 40);
  ok('the late sale goes through', r.s === 200, r);
  reg = await rpc(OWN, 'smoney_register');
  ok('it is in the day end: ₹120 sales, ₹80 expected', reg.j.sales_minor === 12000 && reg.j.expected_minor === 8000, reg.j);
  r = await rpc(OWN, 'smoney_close_day', { counted_minor: 7500 });
  ok('Close day again, counted ₹75: short ₹5', r.s === 200 && r.j.closed?.difference_minor === -500, r);
  r = await rpc(OWN, 'smoney_close_day', { counted_minor: 7500 });
  ok('closing twice is refused', r.s === 409, r);
  r = await rpc(OWN, 'smoney_reopen_day', { reason: 'Second late customer' });
  r = await rpc(OWN, 'smoney_close_day', { counted_minor: 7500 });
  ok('reopened and closed a second time, no clash', r.s === 200 && r.j.reopens?.length === 2, r);

  // ---- 4. carry-forward and the opening count
  const tomorrow = sql(`select ((now() at time zone 'Asia/Kolkata')::date + 1)::text`);
  reg = await rpc(OWN, 'smoney_register', { day: tomorrow });
  ok('the next day opens with the counted ₹75', reg.j.opening_minor === 7500, reg.j);
  const Q = newOrg('q', 'Grocery store');
  const Q1 = await staff(Q.org, 'org_owner', 'q1');
  reg = await rpc(Q1, 'smoney_register');
  ok('a new day offers the opening count', reg.j.can_count_opening === true && reg.j.opening_minor === 0, reg.j);
  r = await rpc(Q1, 'smoney_opening_count', { counted_minor: 5000 });
  ok('₹50 found against ₹0: excess ₹50, and it is in the drawer', r.s === 200 && r.j.opening_count?.difference_minor === 5000 && r.j.expected_minor === 5000 && r.j.cash_in_minor === 0, r);
  r = await rpc(Q1, 'smoney_opening_count', { counted_minor: 5000 });
  ok('counting the opening twice is refused', r.s === 409, r);
  r = await rpc(Q1, 'smoney_close_day', { counted_minor: 3000 });
  ok('closing at ₹30 against ₹50: short ₹20', r.j.closed?.difference_minor === -2000, r);
  feed = await api(Q1, 'GET', '/home/feed?days=7&compare=false');
  ok('Reports: excess ₹50, shortage ₹20', feed.j.cash_difference?.extra === 50 && feed.j.cash_difference?.short === 20, feed.j.cash_difference);
  ok('an online order is not turned away on a closed day', (() => {
    const o = randomUUID();
    sql(`insert into orders(id,organization_id,location_id,channel,status,subtotal,total,order_no,display_no) values ('${o}','${Q.org}','${Q.loc}','online','in_billing',10,10,9001,'W-9001')`);
    sql(`insert into payments(organization_id,order_id,method,amount,created_by) values ('${Q.org}','${o}','online',10,'${Q1.id}')`);
    return sql(`select count(*) from payments where order_id='${o}'`) === '1';
  })());

  // ---- customers on bills are on file (0666)
  const P = newOrg('p', 'Retail');
  const P1 = await staff(P.org, 'org_owner', 'p1');
  const milk = item(P.org, 'Milk', 50);
  r = await api(P1, 'POST', '/pos-orders/checkout', { lines: [{ menu_item_id: milk, qty: 1 }], method: 'cash', tendered: 50, customer_name: 'Sachin C S', customer_phone: '9881396282' }, k());
  ok('a bill with a customer number is paid', r.s === 200, r);
  let cu = await rpc(P1, 'cust_list');
  ok('the customer is on file, with the name split', cu.j.total === 1 && cu.j.items?.[0]?.first_name === 'Sachin', cu.j);
  ok('the bill points at them', sql(`select count(*) from orders where organization_id='${P.org}' and pos_customer_id is not null`) === '1');
  r = await api(P1, 'POST', '/pos-orders/hold', { lines: [{ menu_item_id: milk, qty: 1 }], customer_name: 'S', customer_phone: '9881396282' }, k());
  cu = await rpc(P1, 'cust_list');
  ok('a second bill with the same number adds no second customer', r.s === 200 && cu.j.total === 1, cu.j);
  sql(`insert into orders(organization_id,location_id,channel,status,subtotal,total,order_no,display_no,customer_name,customer_phone) values ('${P.org}','${P.loc}','pickup','in_billing',10,10,9003,'P-9003','Bad','123')`);
  cu = await rpc(P1, 'cust_list');
  ok('a bad number makes no customer, and the bill is still saved', cu.j.total === 1 && sql(`select count(*) from orders where organization_id='${P.org}' and display_no='P-9003'`) === '1', cu.j);
  const RC = newOrg('rc', 'Restaurant');
  sql(`insert into orders(organization_id,location_id,channel,status,subtotal,total,order_no,display_no,customer_name,customer_phone) values ('${RC.org}','${RC.loc}','pickup','in_billing',10,10,9002,'R-9002','Guest','9881396283')`);
  ok('a restaurant bill makes no customer here', sql(`select count(*) from pos_customers where organization_id='${RC.org}'`) === '0');

  // ---- 5. stock adjustments
  const solo = newOrg('a', 'Retail');
  const SOLO = await staff(solo.org, 'org_owner', 'solo');
  const adjust = async (who, org) => {
    const it = sql(`insert into inventory_items(organization_id,sku,name,unit) values ('${org}','ADJ${randomUUID().slice(0, 6)}','Adj item','pc') returning id`);
    const made = await rpc(who, 'inv_document_save', { doc_type: 'adjustment', reason: 'Cycle-count shortage', idempotency_key: k(), lines: [{ inventory_item_id: it, qty: 3, adjust_type: 'increase' }] }, k());
    if (made.s !== 200) return { made };
    const sub = await rpc(who, 'inv_document_act', { id: made.j.id, action: 'submit', version: made.j.version }, k());
    const view = await rpc(who, 'inv_document_view', { id: made.j.id });
    const act = await rpc(who, 'inv_document_act', { id: made.j.id, action: 'approve', version: sub.j.version }, k());
    return { made, sub, view, act };
  };
  let a = await adjust(SOLO, solo.org);
  ok('one-login store: the owner may approve their own adjustment', a.act?.s === 200, a.act ?? a.made);
  ok('…and the screen is told so', JSON.stringify(a.view?.j ?? {}).includes('approve'), a.view);
  const duo = newOrg('b', 'Retail');
  const D1 = await staff(duo.org, 'org_owner', 'd1');
  await staff(duo.org, 'org_admin', 'd2');
  a = await adjust(D1, duo.org);
  ok('with a second approver, four eyes still applies', a.act?.s === 403, a.act ?? a.made);
  const rest = newOrg('c', 'Restaurant');
  const R1 = await staff(rest.org, 'org_owner', 'r1');
  a = await adjust(R1, rest.org);
  ok('a one-login restaurant keeps four eyes', a.act?.s === 403, a.act ?? a.made);

  // ---- 6. the service business
  const V = newOrg('v', 'Service');
  const V1 = await staff(V.org, 'org_owner', 'v1');
  r = await rpc(V1, 'smoney_record', { direction: 'in', kind: 'other_in', category: 'Other', method: 'cash', amount_minor: 10000, note: 'Float' }, k());
  ok('service: ₹100 in the drawer', r.s === 200, r);
  r = await rpc(V1, 'smoney_close_day', { counted_minor: 9000 });
  ok('service: short ₹10 is still cash paid out, as before', r.s === 200 && r.j.cash_out_minor === 1000 && r.j.expected_minor === 9000, r);
  r = await rpc(V1, 'smoney_record', { direction: 'in', kind: 'other_in', category: 'Other', method: 'cash', amount_minor: 500, note: 'After' }, k());
  ok('service: an entry after the close still goes through', r.s === 200, r);
} catch (e) { fail++; console.log('FAIL (threw)', e); }
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
