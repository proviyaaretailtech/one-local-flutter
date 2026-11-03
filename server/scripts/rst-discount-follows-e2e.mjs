// E2E: a percentage discount follows the bill (database 0644) over HTTP against the standalone POS server's generic gateway, as real
// signed-in staff: 10% of ₹820 is ₹82; dishes added make it 10% of the new bill; a cancelled dish brings it down; an amount (₹ off) stays;
// a % coupon follows the bill up to its cap; taking the discount off leaves nothing; the Discounts report shows the real share. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-discount-follows-e2e.mjs   (POS_API, OL_DB, OL_ENV as rst-cancel-refund-e2e)
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
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 600)); } };

const run = Date.now().toString(36);
const org = randomUUID();
async function staff(role, tag) {
  const email = `zz-disc-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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
const money = o => sql(`select discount||'|'||coalesce(discount_pct::text,'-')||'|'||subtotal||'|'||total from orders where id='${o}'`).split('|');

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ DISC ${run}','zz-disc-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const dish = (name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${org}','${name}',${price})`); return id; };
  const thali = dish('Thali', 410), lassi = dish('Lassi', 40), naan = dish('Naan', 20);
  const table = n => { const id = randomUUID(); sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${id}','${org}','${loc}','D${n}',4)`); return id; };
  const MGR = await staff('manager', 'mgr'), CAP = await staff('captain', 'cap'), OWN = await staff('org_owner', 'own');
  ok('staff signed in', [MGR, CAP, OWN].every(x => x.token));
  const add = (t, lines) => rpc(CAP, 'tbl_order_add', { table_id: t, lines, send: true, idempotency_key: k() }, k());
  const orderOf = t => sql(`select id from orders where table_id='${t}' and status not in ('paid','cancelled') order by created_at desc limit 1`);

  // ---- the founder's case: 10% of ₹820, then ₹40 more
  const t1 = table(1);
  let r = await add(t1, [{ menu_item_id: thali, qty: 2 }]);
  ok('a table order of 2 × Thali = ₹820', r.s === 200, r);
  const o1 = orderOf(t1);
  r = await rpc(MGR, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 10, reason: 'Regular guest' });
  let m = money(o1);
  ok('10% off ₹820 is ₹82, kept as 10%', r.s === 200 && +m[0] === 82 && +m[1] === 10, m);
  r = await add(t1, [{ menu_item_id: lassi, qty: 1 }]);
  m = money(o1);
  ok('a ₹40 Lassi added: the discount is ₹86, 10% of ₹860 (was stuck at ₹82)', r.s === 200 && +m[0] === 86 && +m[1] === 10, m);
  ok('…the bill: 860 − 86 = 774 + 5% GST 38.70 = 812.70, rounds to 813', +m[3] === 813, m);
  r = await add(t1, [{ menu_item_id: naan, qty: 3 }]);
  m = money(o1);
  ok('3 Naan more (₹60): ₹92, 10% of ₹920', +m[0] === 92, m);

  // a dish cancelled brings it down
  const naanLine = sql(`select id from order_items where order_id='${o1}' and name='Naan' limit 1`);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: o1, items: [{ item_id: naanLine, qty: 3 }], reason: 'Not needed' }, k());
  m = money(o1);
  ok('the Naan cancelled: back to ₹86, 10% of ₹860', r.s === 200 && +m[0] === 86 && +m[1] === 10, { r, m });

  // paid, then the Discounts report (paid bills only) says the real share
  const pay = async o => {
    await rpc(CAP, 'pos_set_order_status', { order_id: o, to: 'awaiting_payment' });
    return rpc(MGR, 'rst_bill_pay', { order_id: o, method: 'cash', tendered: 5000 }, k());
  };
  const before = sql(`select total from orders where id='${o1}'`);
  r = await pay(o1);
  ok('the 10% bill is paid and keeps its total', r.s === 200 && sql(`select total from orders where id='${o1}'`) === before, r);
  r = await rpc(OWN, 'rst_report_discounts', {});
  const line = r.j?.bills?.find(b => b.order_id === o1);
  ok('Discounts report: ₹86 and 10% of the dishes (what was asked: 10%)', r.s === 200 && line?.discount_minor === 8600 && +line.pct === 10 && +line.given_pct === 10, line);

  // ---- an amount (₹ off) stays an amount
  const t2 = table(2);
  await add(t2, [{ menu_item_id: thali, qty: 2 }]);
  const o2 = orderOf(t2);
  await rpc(MGR, 'rst_bill_discount', { order_id: o2, kind: 'amount', value: 82, reason: 'Regular guest' });
  await add(t2, [{ menu_item_id: lassi, qty: 1 }]);
  m = money(o2);
  ok('₹82 off stays ₹82 when dishes are added (no percentage kept)', +m[0] === 82 && m[1] === '-', m);
  r = await pay(o2);
  r = await rpc(OWN, 'rst_report_discounts', {});
  const l2 = r.j?.bills?.find(b => b.order_id === o2);
  ok('…and the report shows its real share: 9.5% of ₹860', +l2?.pct === 9.5, l2);

  // ---- changing a % to an amount, and taking it off
  const t4 = table(4);
  await add(t4, [{ menu_item_id: thali, qty: 2 }]);
  const o4 = orderOf(t4);
  await rpc(MGR, 'rst_bill_discount', { order_id: o4, kind: 'percent', value: 10, reason: 'Regular guest' });
  await rpc(MGR, 'rst_bill_discount', { order_id: o4, kind: 'amount', value: 50, reason: 'Changed to flat' });
  await add(t4, [{ menu_item_id: lassi, qty: 1 }]);
  m = money(o4);
  ok('a % changed to ₹50: stays ₹50 when more is added', +m[0] === 50 && m[1] === '-', m);
  await rpc(MGR, 'rst_bill_discount', { order_id: o4, kind: 'percent', value: 10, reason: 'Back to ten' });
  await rpc(MGR, 'rst_bill_discount', { order_id: o4, kind: 'amount', value: 0 });
  await add(t4, [{ menu_item_id: lassi, qty: 1 }]);
  m = money(o4);
  ok('taken off: nothing comes back when dishes are added', +m[0] === 0 && m[1] === '-', m);

  // ---- a % coupon follows the bill up to its cap
  sql(`insert into sell_coupons(organization_id,code,kind,value,max_discount) values ('${org}','TENOFF','percent',10,100)`);
  const t3 = table(3);
  await add(t3, [{ menu_item_id: thali, qty: 2 }]);
  const o3 = orderOf(t3);
  r = await rpc(MGR, 'rst_bill_coupon', { order_id: o3, code: 'TENOFF' });
  m = money(o3);
  ok('coupon TENOFF (10%, at most ₹100) on ₹820: ₹82', r.s === 200 && +m[0] === 82 && +m[1] === 10, { r: r.j?.message ?? r.s, m });
  await add(t3, [{ menu_item_id: lassi, qty: 1 }]);
  ok('…a Lassi added: ₹86', +money(o3)[0] === 86);
  await add(t3, [{ menu_item_id: thali, qty: 1 }]);
  ok('…a Thali added (₹1,270 of dishes): capped at ₹100', +money(o3)[0] === 100, money(o3));

  // ---- a paid bill is never priced again
  const paidTotal = sql(`select total from orders where id='${o1}'`);
  try { sql(`select tbl_order_reprice('${o1}')`); } catch { /* the database may refuse it outright */ }
  ok('priced again after it was paid, the bill keeps its total', sql(`select total from orders where id='${o1}'`) === paidTotal);
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
