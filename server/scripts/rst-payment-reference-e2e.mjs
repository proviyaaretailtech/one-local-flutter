// E2E: a restaurant's card or UPI payment always keeps its reference number (database 0648), and the bill splits equally or by dish,
// over HTTP against the standalone POS server, as a real signed-in owner: a table bill by card is refused without the reference, then saved
// with it; the order page's pay (REST) the same; a delivery collected at the door by UPI the same; a bill split equally between 3 guests and
// one split by dish, each guest paid by card or UPI with the reference; a store (not a restaurant) still pays by UPI without one. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-payment-reference-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
//   FIXTURES=../test/fixtures/rst_split_modes_server.json also writes the real answers for the widget tests.
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
  const email = `zz-ref-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${o}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function call(who, url, body, key) {
  const r = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const rpc = (who, fn, body = {}, key) => call(who, `${API}/rpc/${fn}`, body, key);
const rest = (who, path, body, key) => call(who, `${API}/api/partner/pos-orders${path}`, body, key);
const k = () => `e2e-${randomUUID()}`;
const said = (r, re) => re.test(JSON.stringify(r.j));
const refs = o => sql(`select coalesce(string_agg(method || ':' || coalesce(reference, '-'), ',' order by created_at), '') from payments where order_id='${o}'`);
const fx = {};

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ REF ${run}','zz-ref-${run}','franchise','Restaurant'),('${shop}','Golden ZZ REF SHOP ${run}','zz-ref-shop-${run}','franchise','Grocery')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const OWN = await staff(org, 'org_owner', 'own'), SHOP = await staff(shop, 'org_owner', 'shop');
  ok('owners of a restaurant and a store signed in', !!OWN.token && !!SHOP.token);
  let n = 9700;
  const bill = (lines, channel = 'dine_in', status = 'awaiting_payment') => {
    const o = randomUUID(), t = randomUUID();
    if (channel === 'dine_in') sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${org}','${loc}','R${n}',4)`);
    sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values ('${o}',${n},'Z${n}','${org}','${loc}','${channel}','${status}',${channel === 'dine_in' ? `'${t}'` : 'null'},0,5,0,0,'ZZ-TEST ref')`);
    n++;
    for (const [name, qty, price] of lines) sql(`insert into order_items(order_id,name,qty,unit_price,status) values ('${o}','${name}',${qty},${price},'delivered')`);
    sql(`select tbl_order_reprice('${o}')`);
    return { o, t };
  };

  // ---- a table bill by card
  const b1 = bill([['Thali', 2, 500]]);
  let r = await rpc(OWN, 'rst_bill_pay', { order_id: b1.o, method: 'card' }, k());
  ok('card without the reference is refused, and says what to enter', r.s === 400 && said(r, /card reference number/i) && said(r, /last 4 digits/i), r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: b1.o, method: 'card', reference: ' 12 ' }, k());
  ok('…a 2-character reference is refused (4 to 60)', r.s === 400 && said(r, /4 to 60/), r);
  ok('…nothing was paid', refs(b1.o) === '');
  r = await rpc(OWN, 'rst_bill_pay', { order_id: b1.o, method: 'card', reference: ' 4821 ' }, k());
  ok('card with the last 4 digits: paid, the reference saved', r.s === 200 && refs(b1.o) === 'card:4821', { r, refs: refs(b1.o) });
  const b2 = bill([['Dosa', 1, 200]]);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: b2.o, method: 'upi', reference: '' }, k());
  ok('UPI without the reference is refused (UTR)', r.s === 400 && said(r, /UPI reference number/) && said(r, /UTR/), r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: b2.o, method: 'cash', tendered: 500 }, k());
  ok('cash needs no reference', r.s === 200 && refs(b2.o) === 'cash:-', r);

  // ---- the order page (REST hold, then pay)
  const mi = sql(`insert into menu_items(organization_id,name,price) values ('${org}','Paneer roll',150) returning id`).split('\n')[0];
  const h = await rest(OWN, '/hold', { lines: [{ menu_item_id: mi, qty: 2 }], notes: 'ZZ-TEST ref' }, k());
  ok('a takeaway held on the order page', h.s === 200 && !!h.j?.id, h);
  r = await rest(OWN, `/${h.j?.id}/pay`, { method: 'upi', version: h.j?.version }, k());
  ok('order page: UPI without the reference is refused', r.s === 400 && said(r, /UPI reference/), r);
  r = await rest(OWN, `/${h.j?.id}/pay`, { method: 'upi', reference: '431298765012', version: h.j?.version }, k());
  ok('…with the UTR it is paid and saved', r.s === 200 && refs(h.j?.id) === 'upi:431298765012', { r, refs: refs(h.j?.id) });

  // the cart's checkout in one go (a takeaway)
  r = await rest(OWN, '/checkout', { lines: [{ menu_item_id: mi, qty: 1 }], method: 'card', notes: 'ZZ-TEST ref' }, k());
  ok('cart checkout by card without the reference is refused', r.s === 400 && said(r, /card reference/), r);
  r = await rest(OWN, '/checkout', { lines: [{ menu_item_id: mi, qty: 1 }], method: 'card', reference: 'APPR55', notes: 'ZZ-TEST ref' }, k());
  ok('…with the approval code it is paid and saved', r.s === 200 && refs(r.j?.id) === 'card:APPR55', { r, refs: refs(r.j?.id) });

  // ---- a delivery collected at the door
  const d = bill([['Biryani', 1, 300]], 'delivery', 'sent_to_kitchen');
  r = await rpc(OWN, 'rst_channel_delivery', { order_id: d.o, step: 'delivered', payment_method: 'upi' });
  ok('delivery collected by UPI without the reference is refused', r.s === 400 && said(r, /UPI reference/), r);
  ok('…the order is not delivered', sql(`select count(*) from pos_order_delivery where order_id='${d.o}' and stage='delivered'`) === '0');
  r = await rpc(OWN, 'rst_channel_delivery', { order_id: d.o, step: 'delivered', payment_method: 'upi', reference: 'UTR998877' });
  ok('…with it: delivered, the reference saved', r.s === 200 && refs(d.o) === 'upi:UTR998877', { r, refs: refs(d.o) });

  // ---- split equally between 3 guests
  const e = bill([['Thali', 2, 500], ['Lassi', 2, 80]]); // 1160 + 5% = 1218
  const v1 = await rpc(OWN, 'rst_bill_view', { table_id: e.t });
  fx.view_equal = v1.j;
  r = await rpc(OWN, 'rst_bill_split', { order_id: e.o, mode: 'equal', guests: 3, parts: [] }, k());
  fx.split_equal = r.j;
  ok('split equally between 3: 406 each', r.s === 200 && r.j.parts.map(p => Number(p.amount)).join() === '406,406,406' && r.j.parts[0].label === 'Guest 1', r);
  const ep = r.j?.parts ?? [];
  r = await rpc(OWN, 'rst_bill_pay', { order_id: e.o, part_id: ep[0]?.id, method: 'card' }, k());
  ok('guest 1 by card without the reference is refused', r.s === 400 && said(r, /card reference/), r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: e.o, part_id: ep[0]?.id, method: 'card', reference: 'APPR77' }, k());
  ok('guest 1 by card with the approval code', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: e.o, part_id: ep[1]?.id, method: 'upi', reference: 'UTR1001' }, k());
  ok('guest 2 by UPI with the UTR', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: e.o, part_id: ep[2]?.id, method: 'cash', tendered: 500 }, k());
  ok('guest 3 in cash: the bill is paid', r.s === 200 && sql(`select status from orders where id='${e.o}'`) !== 'awaiting_payment', r);
  ok('…every card and UPI part kept its reference', refs(e.o) === 'card:APPR77,upi:UTR1001,cash:-', refs(e.o));

  // ---- split by dish
  const s = bill([['Thali', 1, 500], ['Dosa', 1, 200], ['Coffee', 2, 50]]); // 800 + 5% = 840
  const v2 = await rpc(OWN, 'rst_bill_view', { table_id: s.t });
  fx.view_dish = v2.j;
  const items = v2.j?.orders?.[0]?.items ?? [];
  const id = name => items.find(i => i.name === name)?.id;
  r = await rpc(OWN, 'rst_bill_split', { order_id: s.o, mode: 'item', parts: [{ label: 'Guest 1', item_ids: [id('Thali')] }, { label: 'Guest 2', item_ids: [id('Dosa')] }] }, k());
  ok('by dish: a dish given to nobody is refused', r.s === 400 && said(r, /exactly one guest/), r);
  r = await rpc(OWN, 'rst_bill_split', { order_id: s.o, mode: 'item', parts: [{ label: 'Guest 1', item_ids: [id('Thali')] }, { label: 'Guest 2', item_ids: [id('Dosa'), id('Coffee')] }] }, k());
  fx.split_dish = r.j;
  ok('by dish: Thali 525, Dosa + 2 coffees 315', r.s === 200 && r.j.mode === 'item' && r.j.parts.map(p => Number(p.amount)).join() === '525,315' && r.j.parts[1].item_ids.length === 2, r);
  const sp = r.j?.parts ?? [];
  r = await rpc(OWN, 'rst_bill_pay', { order_id: s.o, part_id: sp[0]?.id, method: 'upi', reference: 'UTR2002' }, k());
  ok('guest 1 by UPI with the UTR', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: s.o, part_id: sp[1]?.id, method: 'card', reference: '0042' }, k());
  ok('guest 2 by card: the bill is paid, references kept', r.s === 200 && refs(s.o) === 'upi:UTR2002,card:0042', { r, refs: refs(s.o) });

  // ---- a store is unchanged
  const smi = sql(`insert into menu_items(organization_id,name,price) values ('${shop}','Amul Butter 500g',320) returning id`).split('\n')[0];
  const sh = await rest(SHOP, '/hold', { lines: [{ menu_item_id: smi, qty: 1 }], notes: 'ZZ-TEST ref' }, k());
  r = await rest(SHOP, `/${sh.j?.id}/pay`, { method: 'upi', version: sh.j?.version }, k());
  ok('a store still pays by UPI without a reference', r.s === 200, r);

  if (process.env.FIXTURES) { writeFileSync(process.env.FIXTURES, JSON.stringify(fx, null, 2)); console.log('fixtures written'); }
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
