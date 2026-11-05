// E2E (database 0653), over HTTP against the standalone POS server, as a real signed-in owner of a restaurant:
//  1. a bill refunded and then voided is not subtracted twice in Sales (a refund on a bill still in Sales is);
//  2. with menu prices that include tax, item-wise and category-wise sales add up to gross sales;
//  3. with two outlets, the cash drawer, a cash entry and Day end are for the outlet chosen (and ask for one when none is);
//  4. a discount code comes off when the bill falls below its minimum order;
//  5. two cash-outs (and two cash refunds) at the same moment cannot both pass the drawer check. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-five-fixes-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
//   FIXTURES=../test/fixtures/rst_outlets_register_server.json also writes the real answers for the widget tests.
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
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 700)); } };

const run = Date.now().toString(36);
async function staff(org, role, tag) {
  const email = `zz-five-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function rpc(who, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;
const said = (r, re) => re.test(JSON.stringify(r.j));
const newOrg = (tag, extra = '') => {
  const org = randomUUID();
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ FIVE ${tag} ${run}','zz-five-${tag}-${run}','franchise','Restaurant')`);
  if (extra) sql(extra.replaceAll('$ORG', org));
  return { org, loc: sql(`select id from locations where organization_id='${org}' order by created_at limit 1`) };
};
const dish = (org, name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${org}','${name}',${price})`); return id; };
const fx = {};

try {
  // ---- 1 and 2: a business whose menu prices include 5% GST
  const A = newOrg('a', `insert into org_bill_settings(organization_id,prices_include_tax) values ('$ORG',true)`);
  const OWN = await staff(A.org, 'org_owner', 'own'), CAP = await staff(A.org, 'captain', 'cap');
  ok('an owner and a captain signed in', OWN.token && CAP.token);
  const thali = dish(A.org, 'Thali', 420), lassi = dish(A.org, 'Lassi', 105), naan = dish(A.org, 'Naan', 35);
  sql(`insert into menu_categories(id,organization_id,name) values (gen_random_uuid(),'${A.org}','Mains')`);
  sql(`update menu_items set category_id=(select id from menu_categories where organization_id='${A.org}' limit 1) where id in ('${thali}','${naan}')`);
  const table = label => { const id = randomUUID(); sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${id}','${A.org}','${A.loc}','${label}',4)`); return id; };
  const bill = async (label, lines) => {
    const t = table(label);
    await rpc(CAP, 'tbl_order_add', { table_id: t, lines, send: true, idempotency_key: k() }, k());
    const o = sql(`select id from orders where table_id='${t}' order by created_at desc limit 1`);
    await rpc(OWN, 'pos_set_order_status', { order_id: o, to: 'awaiting_payment' });
    return o;
  };
  // money in the drawer for the cash refunds below
  await rpc(OWN, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 200000, note: 'Float' }, k());
  const o1 = await bill('A1', [{ menu_item_id: thali, qty: 1 }, { menu_item_id: lassi, qty: 1 }, { menu_item_id: naan, qty: 3 }]); // 630 incl. tax
  let r = await rpc(OWN, 'rst_bill_pay', { order_id: o1, method: 'cash', tendered: 700 }, k());
  ok('bill 1 (₹630, prices include tax) paid', r.s === 200 && r.j.order_paid, r);
  const o2 = await bill('A2', [{ menu_item_id: thali, qty: 1 }]); // 420
  r = await rpc(OWN, 'rst_bill_pay', { order_id: o2, method: 'cash', tendered: 500 }, k());
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o2, amount: 100, method: 'cash', reason: 'Cold food' }, k());
  ok('bill 2 (₹420) paid, ₹100 refunded', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_void', { order_id: o2, reason: 'Wrong table', method: 'cash' }, k());
  ok('…then voided (the rest back in cash): it leaves Sales', r.s === 200 && sql(`select status from orders where id='${o2}'`) === 'cancelled', r);
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o1, amount: 30, method: 'cash', reason: 'Late' }, k());
  ok('bill 1 refunded ₹30 (it stays in Sales)', r.s === 200, r);

  r = await rpc(OWN, 'rst_report_sales', { period: 'today' });
  const tt = r.j?.totals;
  ok('1. Sales: bill 2 is out and its refunds are not taken off again; bill 1\'s ₹30 is', r.s === 200 && tt.bills === 1 && tt.refunds_minor === 3000
    && tt.net_after_refunds_minor === tt.net_minor - 3000, tt);
  r = await rpc(OWN, 'rst_dashboard_scope', { location_id: 'all' });
  ok('1. Home\'s Sales today: ₹630 − ₹30 = ₹600 (it was ₹630 − ₹100 − ₹320 − ₹30)', r.s === 200 && Number(r.j.sales.today) === 600 && Number(r.j.sales.refunds) === 30, r.j?.sales);

  const gross = tt.gross_minor;
  r = await rpc(OWN, 'rst_report_items', { period: 'today' });
  const itemsTotal = (r.j?.items ?? []).reduce((a, x) => a + Number(x.revenue_minor), 0);
  ok(`2. Item-wise sales add up to gross sales (${gross} paise, before tax) with prices that include tax`, r.s === 200 && r.j.total_minor === gross && itemsTotal === gross,
    { total: r.j?.total_minor, sum: itemsTotal, gross });
  ok('…each dish its share: Thali ₹400, Lassi ₹100, 3 Naan ₹100 (₹630 incl. 5% = ₹600)', (r.j?.items ?? []).filter(x => x.qty > 0).map(x => `${x.name}:${x.revenue_minor}`).sort().join() === 'Lassi:10000,Naan:10000,Thali:40000', r.j?.items);
  r = await rpc(OWN, 'rst_report_categories', { period: 'today' });
  ok('2. Category-wise sales add up to gross sales too', r.s === 200 && r.j.total_minor === gross
    && r.j.categories.reduce((a, c) => a + Number(c.revenue_minor), 0) === gross, r.j?.categories?.map(c => `${c.name}:${c.revenue_minor}`));

  // ---- 4: a discount code below its minimum order comes off
  sql(`insert into sell_coupons(organization_id,code,kind,value,min_order) values ('${A.org}','BIG10','percent',10,500)`);
  const t4 = table('A4');
  await rpc(CAP, 'tbl_order_add', { table_id: t4, lines: [{ menu_item_id: thali, qty: 1 }, { menu_item_id: lassi, qty: 1 }], send: true, idempotency_key: k() }, k());
  const o4 = sql(`select id from orders where table_id='${t4}' limit 1`);
  r = await rpc(OWN, 'rst_bill_coupon', { order_id: o4, code: 'BIG10' });
  ok('a ₹525 bill takes BIG10 (10%, minimum ₹500)', r.s === 200 && sql(`select coupon_code from orders where id='${o4}'`) === 'BIG10', r);
  sql(`update order_items set status='cancelled' where order_id='${o4}' and menu_item_id='${lassi}'`);
  sql(`select tbl_order_reprice('${o4}')`);
  ok('4. a dish comes off (₹420, below ₹500): the code comes off with its discount, and the bill says so',
    sql(`select coalesce(coupon_code,'-')||'|'||discount||'|'||coalesce(discount_pct::text,'-') from orders where id='${o4}'`) === '-|0.00|-'
    && sql(`select message from order_events where order_id='${o4}' and kind='coupon_removed'`).includes('below its minimum of 500.00'));
  const t5 = table('A5');
  await rpc(CAP, 'tbl_order_add', { table_id: t5, lines: [{ menu_item_id: thali, qty: 2 }], send: true, idempotency_key: k() }, k());
  const o5 = sql(`select id from orders where table_id='${t5}' limit 1`);
  await rpc(OWN, 'rst_bill_coupon', { order_id: o5, code: 'BIG10' });
  await rpc(CAP, 'tbl_order_add', { table_id: t5, lines: [{ menu_item_id: lassi, qty: 1 }], send: true, idempotency_key: k() }, k());
  ok('4. above the minimum the % still follows the dishes (₹945 → ₹94.50 off)', sql(`select coupon_code||'|'||discount from orders where id='${o5}'`) === 'BIG10|94.50');

  // ---- 5: two cash-outs at the same moment
  const C = newOrg('c');
  const OWNC = await staff(C.org, 'org_owner', 'ownc');
  await rpc(OWNC, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 50000, note: 'Float' }, k());
  const outs = await Promise.all([1, 2, 3].map(() => rpc(OWNC, 'rmoney_record', { direction: 'out', kind: 'expense', category: 'Vegetables', method: 'cash', amount_minor: 40000, note: 'Market' }, k())));
  const cashC = Number(sql(`select rmoney_cash_now('${C.org}', array['${C.loc}'::uuid])`));
  ok('5. three ₹400 cash-outs at once against ₹500: one goes through, the others are refused; the drawer never below zero',
    outs.filter(x => x.s === 200).length === 1 && outs.filter(x => x.s === 422).length === 2 && cashC === 10000, { statuses: outs.map(x => x.s), cash: cashC });
  const D = newOrg('d');
  const OWND = await staff(D.org, 'org_owner', 'ownd');
  const dThali = dish(D.org, 'Thali', 400);
  await rpc(OWND, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 50000, note: 'Float' }, k());
  const td = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${td}','${D.org}','${D.loc}','D1',4)`);
  const od = randomUUID();
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values ('${od}',9951,'Z9951','${D.org}','${D.loc}','dine_in','awaiting_payment','${td}',0,5,0,0,'ZZ-TEST five')`);
  sql(`insert into order_items(order_id,menu_item_id,name,qty,unit_price,status) values ('${od}','${dThali}','Thali',2,400,'delivered')`);
  sql(`select tbl_order_reprice('${od}')`);
  await rpc(OWND, 'rst_bill_pay', { order_id: od, method: 'upi', reference: 'UTR5551' }, k());
  const refs = await Promise.all([1, 2].map(() => rpc(OWND, 'rst_bill_refund', { order_id: od, amount: 400, method: 'cash', reason: 'Cold' }, k())));
  const cashD = Number(sql(`select rmoney_cash_now('${D.org}', array['${D.loc}'::uuid])`));
  ok('5. two ₹400 cash refunds at once against ₹500: one goes through, the drawer never below zero',
    refs.filter(x => x.s === 200).length === 1 && cashD === 10000, { statuses: refs.map(x => x.s), cash: cashD });

  // ---- 3: two outlets
  const B = newOrg('b');
  const loc2 = randomUUID();
  sql(`insert into locations(id,organization_id,name,code) values ('${loc2}','${B.org}','Golden ZZ FIVE b ${run} - Koregaon Park','KP${run.slice(-4)}')`);
  const OWNB = await staff(B.org, 'org_owner', 'ownb');
  r = await rpc(OWNB, 'rmoney_register', {});
  fx.register_outlets = r.j;
  ok('3. two outlets, none chosen: the drawer lists each outlet\'s day to choose from', r.s === 200 && r.j.choose_outlet === true && r.j.outlets?.length === 2
    && r.j.outlets.every(o => o.ended === false) && r.j.can_close === false, r.j);
  r = await rpc(OWNB, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 30000, note: 'Float' }, k());
  ok('…a cash entry with no outlet chosen asks for one (it went to the first outlet)', r.s === 400 && said(r, /choose the outlet/i), r);
  r = await rpc(OWNB, 'rmoney_close_day', { counted_minor: 0 });
  ok('…so does Day end', r.s === 400 && said(r, /choose the outlet/i), r);
  r = await rpc(OWNB, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 30000, note: 'Float', location_id: loc2 }, k());
  ok('₹300 cash in at the second outlet', r.s === 200 && sql(`select location_id from rmoney_entries where id='${r.j?.id}'`) === loc2, r);
  r = await rpc(OWNB, 'rmoney_register', { location_id: loc2 });
  fx.register_one = r.j;
  ok('…its drawer should hold ₹300; the first outlet\'s nothing', r.s === 200 && r.j.expected_minor === 30000
    && (await rpc(OWNB, 'rmoney_register', { location_id: B.loc })).j?.expected_minor === 0, r.j);
  r = await rpc(OWNB, 'rmoney_close_day', { counted_minor: 30000, location_id: loc2 });
  ok('3. Day end at the second outlet is booked to the second outlet', r.s === 200 && r.j.closed?.difference_minor === 0
    && sql(`select string_agg(location_id::text, ',') from rmoney_day_closes where organization_id='${B.org}'`) === loc2, r.j?.closed);
  r = await rpc(OWNB, 'rmoney_register', {});
  ok('…the list shows the second outlet ended, the first still open', r.j?.outlets?.find(o => o.id === loc2)?.ended === true && r.j.outlets.find(o => o.id === B.loc)?.ended === false, r.j?.outlets);
  r = await rpc(OWNB, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 10000, note: 'More', location_id: B.loc }, k());
  ok('…cash can still be recorded at the first outlet (its day is open)', r.s === 200, r);
  r = await rpc(OWNB, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 10000, note: 'More', location_id: loc2 }, k());
  ok('…not at the second (its day ended)', r.s === 400 && said(r, /Day end is done/), r);
  r = await rpc(OWNB, 'rmoney_reopen_day', { reason: 'Recount', location_id: loc2 });
  ok('…the owner reopens the second outlet\'s day', r.s === 200 && r.j.closed === null, r);
  r = await rpc(OWN, 'rmoney_register', {});
  ok('a business with one outlet needs no choice', r.s === 200 && r.j.choose_outlet === undefined && typeof r.j.expected_minor === 'number', r.j && { choose: r.j.choose_outlet });

  if (process.env.FIXTURES) { writeFileSync(process.env.FIXTURES, JSON.stringify(fx, null, 2)); console.log('fixtures written'); }
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
