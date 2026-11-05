// E2E (database 0652), over HTTP against the standalone POS server, as real signed-in staff of a restaurant:
//  * Apply to Channels: a dish is on Table QR and the OneLocal app until switched off; a captain cannot switch it; switched off for Table QR,
//    a guest cannot order it from the table; switched off for the app, the app cannot order it.
//  * kitchen and captain logins: Home (dashboard and insights) without sales, payments or refunds; the Activity log without payments,
//    discounts, refunds, cancellation reasons or customers. The cashier and the owner still see them. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-channels-staff-money-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
//   FIXTURES=../test/fixtures/rst_staff_money_server.json also writes the real answers for the widget tests.
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
const org = randomUUID();
async function staff(role, tag) {
  const email = `zz-csm-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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
const has = (j, key) => JSON.stringify(j).includes(`"${key}"`);
const fx = {};

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ CSM ${run}','zz-csm-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const dish = (name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${org}','${name}',${price})`); return id; };
  const thali = dish('Thali', 400), lassi = dish('Lassi', 100);
  const OWN = await staff('org_owner', 'own'), CAP = await staff('captain', 'cap'), KIT = await staff('kitchen', 'kit'), CASH = await staff('biller', 'cash');
  ok('owner, captain, kitchen and cashier signed in', [OWN, CAP, KIT, CASH].every(x => x.token));

  // ---- Apply to Channels
  let r = await rpc(OWN, 'rst_menu_item_view', { id: thali });
  fx.dish = r.j;
  ok('a dish is on Table QR and the OneLocal app to start with', r.s === 200 && r.j.channels?.qr === true && r.j.channels.one_local === true, r.j?.channels);
  r = await rpc(CAP, 'rst_menu_item_save', { id: thali, version: fx.dish?.version, channels: { qr: false } });
  ok('a captain cannot switch it', r.s === 403, r);
  r = await rpc(OWN, 'rst_menu_item_save', { id: thali, version: fx.dish?.version, channels: { swiggy: false } });
  ok('…only Table QR and the OneLocal app can be switched', r.s === 400, r);
  r = await rpc(OWN, 'rst_menu_item_save', { id: thali, version: fx.dish?.version, channels: { qr: false, one_local: true } });
  fx.dish_off_qr = r.j;
  ok('the owner switches Table QR off: saved', r.s === 200 && r.j.channels.qr === false && r.j.channels.one_local === true, r.j?.channels);
  ok('…a guest cannot order it from the table', sql(`select public.guest__orderable('${thali}', '${loc}', '{}'::jsonb)`) === 'f'
    && sql(`select public.guest__orderable('${lassi}', '${loc}', '{}'::jsonb)`) === 't');
  r = await rpc(OWN, 'rst_menu_item_save', { id: thali, version: r.j?.version, channels: { qr: true, one_local: false } });
  ok('switched off for the OneLocal app instead', r.s === 200 && r.j.channels.qr === true && r.j.channels.one_local === false, r.j?.channels);
  ok('…the app\'s order check sees it off (what ol_create_restaurant_order reads)',
    sql(`select count(*) from item_channel_status where menu_item_id='${thali}' and channel='one_local' and not is_available and off_until is null`) === '1'
    && sql(`select public.guest__orderable('${thali}', '${loc}', '{}'::jsonb)`) === 't');

  // ---- a day's money: a paid table bill with a manual discount, a refund, a cancelled dish
  const t = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${org}','${loc}','K1',4)`);
  r = await rpc(CAP, 'tbl_order_add', { table_id: t, lines: [{ menu_item_id: thali, qty: 2 }, { menu_item_id: lassi, qty: 1 }], send: true, idempotency_key: k() }, k());
  const o = sql(`select id from orders where table_id='${t}' order by created_at desc limit 1`);
  r = await rpc(OWN, 'rst_bill_discount', { order_id: o, kind: 'amount', value: 50, reason: 'Regular guest' });
  r = await rpc(OWN, 'pos_set_order_status', { order_id: o, to: 'awaiting_payment' });
  r = await rpc(CASH, 'rst_bill_pay', { order_id: o, method: 'cash', tendered: 1000 }, k());
  ok('a table bill paid in cash', r.s === 200 && r.j.order_paid === true, r);
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o, amount: 100, method: 'upi', reason: 'Cold lassi' }, k());
  ok('…₹100 refunded: "Cold lassi"', r.s === 200, r);

  // ---- Home: dashboard and insights
  const dash = who => rpc(who, 'rst_dashboard_scope', { location_id: 'all' });
  const ins = who => rpc(who, 'rst_home_insights', { location_id: 'all' });
  r = await dash(OWN);
  fx.dashboard_owner = r.j;
  ok('the owner\'s Home has today\'s sales and refunds', r.s === 200 && !r.j.money_hidden && Number(r.j.sales?.refunds) === 100 && Number(r.j.sales?.gross) > 0, r.j?.sales);
  for (const [who, name] of [[CAP, 'captain'], [KIT, 'kitchen']]) {
    r = await dash(who);
    if (name === 'captain') fx.dashboard_captain = r.j;
    ok(`a ${name} login's Home: no sales, refunds or 7-day sales, still the orders`, r.s === 200 && r.j.money_hidden === true && !has(r.j, 'sales') && !has(r.j, 'refunds')
      && !has(r.j, 'sales_today') && Number(r.j.orders?.today) >= 1 && Array.isArray(r.j.last7), r.j && { money_hidden: r.j.money_hidden, sales: r.j.sales, last7: r.j.last7?.[0] });
    r = await ins(who);
    if (name === 'captain') fx.insights_captain = r.j;
    ok(`…its insights: orders and dishes sold, no amounts or payments`, r.s === 200 && r.j.money_hidden === true && !has(r.j, 'sales') && !has(r.j, 'avg_bill')
      && !has(r.j, 'payments') && r.j.mix?.orders >= 1 && r.j.top?.[0]?.qty > 0, r.j && { mix: r.j.mix, top: r.j.top });
  }
  r = await ins(CASH);
  ok('a cashier still sees the day\'s sales and payments', r.s === 200 && !r.j.money_hidden && Number(r.j.mix?.sales) > 0 && r.j.payments?.length > 0, r.j?.mix);
  r = await ins(OWN);
  fx.insights_owner = r.j;

  // ---- the Activity log
  const log = who => rpc(who, 'rst_activity_log', { location_id: 'all' });
  r = await log(OWN);
  const ownKinds = new Set((r.j?.entries ?? []).map(e => e.kind));
  ok('the owner\'s Activity log has the payment, the discount and the refund with its reason', r.s === 200 && r.j.limited === false && ownKinds.has('paid')
    && ownKinds.has('manual_discount') && ownKinds.has('refunded') && JSON.stringify(r.j).includes('Regular guest'), [...ownKinds]);
  for (const [who, name] of [[CAP, 'captain'], [KIT, 'kitchen']]) {
    r = await log(who);
    if (name === 'captain') fx.activity_captain = r.j;
    const kinds = new Set((r.j?.entries ?? []).map(e => e.kind));
    ok(`a ${name} login's Activity log: the kitchen and floor only, no money and no reasons`, r.s === 200 && r.j.limited === true && kinds.has('placed') && kinds.has('kot_fired')
      && !['paid', 'manual_discount', 'refunded', 'part_paid', 'bill_voided', 'item_cancelled'].some(x => kinds.has(x))
      && !JSON.stringify(r.j).includes('Cold lassi') && !JSON.stringify(r.j).includes('Regular guest'), [...kinds]);
  }
  r = await log(CASH);
  ok('a cashier\'s Activity log is the full one', r.s === 200 && r.j.limited === false && new Set(r.j.entries.map(e => e.kind)).has('paid'), r.j?.limited);

  if (process.env.FIXTURES) { writeFileSync(process.env.FIXTURES, JSON.stringify(fx, null, 2)); console.log('fixtures written'); }
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
