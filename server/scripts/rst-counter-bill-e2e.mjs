// E2E: a restaurant's takeaway and delivery bills (no table) are taken at the restaurant Checkout (database 0649), over HTTP against the
// standalone POS server, as real signed-in staff: the bill opens by its order; a manual discount, a split and a card payment with its
// reference all work on it (they answered "Bill not found" before); a takeaway still on hold is sent to the kitchen first; a delivery bill
// the same; an app / aggregator order and a store's order are not restaurant counter bills; table bills are unchanged. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-counter-bill-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
//   FIXTURES=../test/fixtures/rst_counter_bill_server.json also writes the real answers for the widget tests.
import { readFileSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const DB = process.env.OL_DB ?? 'supabase_db_onelocal-local-db';
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).trim().replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q0 => { const q = q0.split('\n').join(' '); return execSync(`docker exec ${DB} psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim(); };
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 600)); } };

const run = Date.now().toString(36);
const org = randomUUID(), shop = randomUUID();
async function staff(o, role, tag) {
  const email = `zz-ctr-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${o}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function call(who, url, body, key, method = 'POST') {
  const r = await fetch(url, { method, headers: { Authorization: `Bearer ${who.token}`, ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const rpc = (who, fn, body = {}, key) => call(who, `${API}/rpc/${fn}`, body, key);
const rest = (who, path, body, key, method) => call(who, `${API}/api/partner/pos-orders${path}`, body, key, method);
const k = () => `e2e-${randomUUID()}`;
const said = (r, re) => re.test(JSON.stringify(r.j));
const pays = o => sql(`select coalesce(string_agg(method || ':' || trim(to_char(amount, 'FM999990.00')) || ':' || coalesce(reference, '-'), ',' order by created_at), '') from payments where order_id='${o}'`);
const fx = {};

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ CTR ${run}','zz-ctr-${run}','franchise','Restaurant'),('${shop}','Golden ZZ CTR SHOP ${run}','zz-ctr-shop-${run}','franchise','Grocery')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const dish = (o, name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${o}','${name}',${price})`); return id; };
  const thali = dish(org, 'Thali', 400), lassi = dish(org, 'Lassi', 100);
  const OWN = await staff(org, 'org_owner', 'own'), CAP = await staff(org, 'captain', 'cap'), SHOP = await staff(shop, 'org_owner', 'shop');
  ok('owner, captain and a store owner signed in', [OWN, CAP, SHOP].every(x => x.token));
  const counter = (type, send, lines = [{ menu_item_id: thali, qty: 1 }, { menu_item_id: lassi, qty: 1 }], extra = {}) =>
    rpc(CAP, 'pos_counter_order', { service_type: type, lines, send, idempotency_key: k(), ...extra });

  // ---- a takeaway sent to the kitchen: ₹500 + 5% = ₹525
  let r = await counter('pickup', true);
  const ta = r.j?.order_id;
  ok('captain sends a takeaway to the kitchen', r.s === 200 && sql(`select status from orders where id='${ta}'`) === 'sent_to_kitchen', r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: ta });
  fx.view_takeaway = r.j;
  ok('the restaurant Checkout opens it by its order (it said "Bill not found")', r.s === 200 && r.j.table === null && r.j.counter?.label === 'Takeaway'
    && r.j.orders.length === 1 && r.j.orders[0].bill_generated === true && r.j.orders[0].channel === 'pickup' && r.j.can.pay && r.j.can.split, r);
  ok('…with no table and no order: refused', (await rpc(OWN, 'rst_bill_view', {})).s === 400);
  r = await rest(OWN, `/${ta}`, null, null, 'GET');
  ok('the order page says it is a takeaway with no table (the app opens the restaurant Checkout)', r.s === 200 && r.j.channel === 'pickup' && r.j.table_id === null, r.j && { channel: r.j.channel, table_id: r.j.table_id });

  r = await rpc(OWN, 'rst_bill_discount', { order_id: ta, kind: 'percent', value: 10, reason: 'Regular guest' });
  ok('a manual discount of 10%: ₹525 → ₹473 (no admin PIN: no payment taken yet)', r.s === 200 && Number(sql(`select total from orders where id='${ta}'`)) === 473, { r, total: sql(`select total from orders where id='${ta}'`) });
  r = await rpc(OWN, 'rst_bill_split', { order_id: ta, mode: 'equal', guests: 2, parts: [] }, k());
  ok('split equally between 2 (it said "Bill not found")', r.s === 200 && r.j.parts.map(p => Number(p.amount)).join() === '236.5,236.5', r);
  const parts = r.j?.parts ?? [];
  r = await rpc(OWN, 'rst_bill_pay', { order_id: ta, part_id: parts[0]?.id, method: 'card', reference: '4821' }, k());
  ok('guest 1 by card with the last 4 digits', r.s === 200 && r.j.order_paid === false && Number(r.j.due) === 236.5, r);
  fx.pay_part = r.j;
  r = await rpc(OWN, 'rst_bill_discount', { order_id: ta, kind: 'percent', value: 20, reason: 'More' });
  ok('…once a payment is taken the discount needs the admin PIN (0645 lock)', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: ta, part_id: parts[1]?.id, method: 'upi' }, k());
  ok('guest 2 by UPI without the UTR is refused (0648)', r.s === 400 && said(r, /UPI reference/), r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: ta, part_id: parts[1]?.id, method: 'upi', reference: 'UTR5150' }, k());
  fx.pay_last = r.j;
  ok('guest 2 by UPI with the UTR: the takeaway is paid', r.s === 200 && r.j.order_paid === true && sql(`select status from orders where id='${ta}'`) === 'paid', r);
  ok('…both references kept', pays(ta) === 'card:236.50:4821,upi:236.50:UTR5150', pays(ta));
  r = await rpc(OWN, 'rst_receipt_view', { order_id: ta });
  fx.receipt = r.j;
  ok('its receipt opens (it said "Bill not found")', r.s === 200 && r.j.table_label === null, r);
  r = await rpc(OWN, 'rst_receipt_log', { order_id: ta, channel: 'print' });
  ok('…and its print is logged', r.s === 200 && r.j.logged === true, r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: ta });
  ok('a paid takeaway has no open bill: "This bill is already settled."', r.s === 200 && r.j.orders.length === 0 && r.j.unavailable.pay === 'This bill is already settled.', r);

  // ---- a takeaway on hold (not sent to the kitchen)
  r = await counter('pickup', false);
  const held = r.j?.order_id;
  r = await rpc(OWN, 'rst_bill_view', { order_id: held });
  fx.view_held = r.j;
  ok('a takeaway on hold: Send the order to the kitchen first', r.s === 200 && r.j.can.pay === false && r.j.unavailable.pay === 'Send the order to the kitchen first.', r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: held, method: 'cash', tendered: 600 }, k());
  ok('…paying it is refused and says so', r.s === 409 && said(r, /send the order to the kitchen first/i), r);

  // ---- a delivery bill, whole, by cash
  r = await counter('delivery', true, [{ menu_item_id: thali, qty: 2 }], { customer_name: 'Ravi', customer_phone: '9876543210', address: '12 Main road, Latur' });
  const dl = r.j?.order_id;
  ok('a phone delivery sent to the kitchen', r.s === 200 && !!dl, r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: dl });
  ok('…opens as a Delivery bill of ₹840', r.s === 200 && r.j.counter?.label === 'Delivery' && Number(r.j.orders[0].due) === 840, r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: dl, method: 'cash', tendered: 1000 }, k());
  ok('…paid in cash, ₹160 change', r.s === 200 && r.j.order_paid === true && Number(r.j.change) === 160, r);

  // ---- not restaurant counter bills
  const sw = randomUUID();
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,subtotal,gst_pct,gst_amount,total,notes) values ('${sw}',9801,'Z9801','${org}','${loc}','swiggy','sent_to_kitchen',0,5,0,0,'ZZ-TEST ctr')`);
  sql(`insert into order_items(order_id,name,qty,unit_price,status) values ('${sw}','Thali',1,400,'preparing')`);
  sql(`select tbl_order_reprice('${sw}')`);
  ok('a Swiggy order is not a counter bill (paid on Swiggy)', (await rpc(OWN, 'rst_bill_view', { order_id: sw })).s === 404 && (await rpc(OWN, 'rst_bill_pay', { order_id: sw, method: 'cash', tendered: 500 }, k())).s === 404);
  const smi = dish(shop, 'Amul Butter 500g', 320);
  r = await rest(SHOP, '/hold', { lines: [{ menu_item_id: smi, qty: 1 }], notes: 'ZZ-TEST ctr' }, k());
  ok("a store's held bill is not a restaurant bill", (await rpc(SHOP, 'rst_bill_view', { order_id: r.j?.id })).s === 404, r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: ta, table_id: randomUUID() });
  ok('a table and an order together: refused', r.s === 400, r);

  // ---- the cart (a takeaway held for payment) is a cart until paid: discount without the PIN
  r = await rest(OWN, '/hold', { lines: [{ menu_item_id: lassi, qty: 2 }], notes: 'ZZ-TEST ctr' }, k());
  const cart = r.j?.id;
  r = await rpc(OWN, 'rst_bill_view', { order_id: cart });
  ok('a cart held in a restaurant is not sent yet: Send the order to the kitchen first', r.s === 200 && r.j.can.pay === false, r);
  r = await rpc(OWN, 'rst_hold_send', { order_id: cart }, k());
  ok('…the app sends it to the kitchen (rst_hold_send) on Proceed to Checkout', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: cart });
  ok('…then it is ready to pay at the Checkout', r.s === 200 && r.j.can.pay === true && r.j.can.coupon === true, r);
  r = await rpc(OWN, 'rst_bill_discount', { order_id: cart, kind: 'amount', value: 20, reason: 'Loyal' });
  ok('…a ₹20 discount on it needs no admin PIN', r.s === 200, r);

  // ---- table bills unchanged
  const t = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${org}','${loc}','C1',4)`);
  r = await rpc(CAP, 'tbl_order_add', { table_id: t, lines: [{ menu_item_id: thali, qty: 1 }], send: true, idempotency_key: k() }, k());
  const to = sql(`select id from orders where table_id='${t}' order by created_at desc limit 1`);
  r = await rpc(OWN, 'rst_bill_view', { table_id: t });
  ok('a table bill opens by its table, not yet generated', r.s === 200 && r.j.table?.label === 'C1' && r.j.counter === null && r.j.can.pay === false && r.j.unavailable.pay === 'Generate the bill first.', r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: to, method: 'cash', tendered: 500 }, k());
  ok('…paying it before the bill is generated: "generate the bill first"', r.s === 409 && said(r, /generate the bill first/i), r);
  r = await rpc(OWN, 'pos_set_order_status', { order_id: to, to: 'awaiting_payment' });
  r = await rpc(OWN, 'rst_bill_discount', { order_id: to, kind: 'amount', value: 20, reason: 'Late' });
  ok('…a generated table bill still needs the admin PIN for a discount', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(OWN, 'rst_bill_view', { order_id: to });
  ok('…and is not opened by its order', r.s === 404, r);

  if (process.env.FIXTURES) { writeFileSync(process.env.FIXTURES, JSON.stringify(fx, null, 2)); console.log('fixtures written'); }
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
