// E2E: the restaurant "Bill and pay" journey (database 0550) over HTTP against the standalone POS server's generic gateway (POST /rpc/<function>),
// as real signed-in staff of two different businesses: the bill of a table, split equally, each guest paid separately (never twice), the table
// freed, the receipt; a discount code and a kitchen note on another bill; roles; and business B reaching nothing of business A. LOCAL ONLY.
// Tags its orders 'ZZ-TEST' and purges them, its users and its businesses at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/rst-bill-e2e.mjs   (POS_API overrides the address; keys read from ./.env, never printed)
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 400)); } };

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID();
const users = [];
async function staff(org, role, tag) {
  const email = `zz-rst-bill-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','Golden ZZ RST A ${run}','zz-rst-a-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ RST B ${run}','zz-rst-b-${run}','franchise','Restaurant')`);
  const locA = sql(`select id from locations where organization_id='${orgA}' limit 1`);
  const t1 = randomUUID(), t2 = randomUUID(), o1 = randomUUID(), o2 = randomUUID(), i1 = randomUUID(), i2 = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t1}','${orgA}','${locA}','T12',4),('${t2}','${orgA}','${locA}','T14',2)`);
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values
    ('${o1}',991,'Z991','${orgA}','${locA}','dine_in','awaiting_payment','${t1}',1240,5,62,1302,'ZZ-TEST rst bill'),
    ('${o2}',992,'Z992','${orgA}','${locA}','dine_in','awaiting_payment','${t2}',1000,5,50,1050,'ZZ-TEST rst coupon')`);
  sql(`insert into order_items(id,order_id,name,qty,unit_price) values ('${i1}','${o1}','Paneer Butter Masala',2,320),('${i2}','${o1}','Chicken Tikka',1,600),('${randomUUID()}','${o2}','Thali',4,250)`);
  sql(`insert into sell_coupons(organization_id,code,kind,value) values ('${orgA}','DINEQR30','flat',30)`);
  const A = await staff(orgA, 'manager', 'mgr-a'), C = await staff(orgA, 'captain', 'cap-a'), V = await staff(orgA, 'viewer', 'viewer-a'), B = await staff(orgB, 'org_owner', 'owner-b');
  ok('four staff signed in', !!A && !!C && !!V && !!B);
  ok('no token: 401', (await rpc(null, 'rst_bill_view', { table_id: t1 })).s === 401);
  ok('a helper is not on the gateway: 404', (await rpc(A, 'rst_bill_lock', { order_id: o1 })).s === 404);

  // ---- the bill of T12
  const v = await rpc(A, 'rst_bill_view', { table_id: t1 });
  ok('bill view: one bill of 1302, two items, may pay and split', v.s === 200 && v.j.orders.length === 1 && Number(v.j.orders[0].total) === 1302 && v.j.orders[0].items.length === 2
    && v.j.can.pay && v.j.can.split, v);
  ok('bill view: business B gets 404 for A\'s table', (await rpc(B, 'rst_bill_view', { table_id: t1 })).s === 404);
  ok('bill view: a viewer is refused (403)', (await rpc(V, 'rst_bill_view', { table_id: t1 })).s === 403);
  ok('bill view: a bad id is 400', (await rpc(A, 'rst_bill_view', { table_id: 'nope' })).s === 400);

  // ---- split equally between two guests
  const sk = k();
  const s1 = await rpc(A, 'rst_bill_split', { order_id: o1, mode: 'equal', guests: 2, parts: [{ label: 'Guest 1', method: 'upi' }, { label: 'Guest 2', method: 'cash' }] }, sk);
  ok('split: 651 + 651', s1.s === 200 && s1.j.parts.map(p => Number(p.amount)).join() === '651,651' && s1.j.parts[0].method === 'upi', s1);
  ok('split: same key, same plan', (await rpc(A, 'rst_bill_split', { order_id: o1, mode: 'equal', guests: 2 }, sk)).j?.replayed === true);
  ok('split: business B 404', (await rpc(B, 'rst_bill_split', { order_id: o1, mode: 'equal', guests: 2 }, k())).s === 404);
  ok('split: wrong sum by amount is 400', (await rpc(A, 'rst_bill_split', { order_id: o1, mode: 'amount', parts: [{ amount: 1 }, { amount: 2 }] }, k())).s === 400);
  ok('whole-bill payment on a split bill is 409', (await rpc(A, 'rst_bill_pay', { order_id: o1, method: 'cash' }, k())).s === 409);

  // ---- guest 1 pays by UPI, guest 2 in cash
  const [p1, p2] = s1.j.parts;
  ok('a captain cannot take money (403)', (await rpc(C, 'rst_bill_pay', { order_id: o1, part_id: p1.id, method: 'upi' }, k())).s === 403);
  ok('business B cannot pay A\'s part (404)', (await rpc(B, 'rst_bill_pay', { order_id: o1, part_id: p1.id, method: 'upi' }, k())).s === 404);
  const pk = k();
  const r1 = await rpc(A, 'rst_bill_pay', { order_id: o1, part_id: p1.id, method: 'upi', reference: 'UTR991' }, pk);
  ok('guest 1: 651 by UPI, 651 still due, table not settled', r1.s === 200 && Number(r1.j.amount) === 651 && Number(r1.j.due) === 651 && !r1.j.order_paid && !r1.j.table_settled, r1);
  const r1b = await rpc(A, 'rst_bill_pay', { order_id: o1, part_id: p1.id, method: 'upi' }, pk);
  ok('guest 1 retried with the same key: same answer, replayed', r1b.s === 200 && r1b.j.replayed === true && Number(r1b.j.amount) === 651, r1b);
  ok('guest 1 again with a new key: 409, never paid twice', (await rpc(A, 'rst_bill_pay', { order_id: o1, part_id: p1.id, method: 'card' }, k())).s === 409);
  ok('one payment row so far', sql(`select count(*) from payments where order_id='${o1}'`) === '1');
  ok('cash short of the part is 422', (await rpc(A, 'rst_bill_pay', { order_id: o1, part_id: p2.id, method: 'cash', tendered: 100 }, k())).s === 422);
  const r2 = await rpc(A, 'rst_bill_pay', { order_id: o1, part_id: p2.id, method: 'cash', tendered: 700 }, k());
  ok('guest 2: 651 cash, 49 change, bill paid, table settled, method split', r2.s === 200 && Number(r2.j.change) === 49 && r2.j.order_paid && r2.j.table_settled && r2.j.payment_method === 'split', r2);
  ok('payments add up to 1302 on one order', sql(`select sum(amount) from payments where order_id='${o1}'`) === '1302.00');
  ok('the table shows Cleaning', sql(`select status from tbl_states('${orgA}','${locA}','${t1}')`) === 'cleaning');

  // ---- receipt
  const rv = await rpc(A, 'rst_receipt_view', { order_id: o1 });
  ok('receipt view: paid, two payments, table T12', rv.s === 200 && rv.j.payments.length === 2 && rv.j.table_label === 'T12' && rv.j.status === 'paid', rv);
  ok('receipt view: business B 404', (await rpc(B, 'rst_receipt_view', { order_id: o1 })).s === 404);
  const rl = await rpc(A, 'rst_receipt_log', { order_id: o1, channel: 'whatsapp', to: '9876543210' });
  ok('receipt sent by WhatsApp is logged masked', rl.s === 200 && rl.j.to === '******3210', rl);
  ok('receipt log: business B 404', (await rpc(B, 'rst_receipt_log', { order_id: o1, channel: 'print' })).s === 404);

  // ---- discount code and kitchen note on T14
  ok('coupon: unknown code 422', (await rpc(A, 'rst_bill_coupon', { order_id: o2, code: 'NOPE99' })).s === 422);
  const c1 = await rpc(A, 'rst_bill_coupon', { order_id: o2, code: 'dineqr30' });
  ok('coupon: flat 30 off 1000, GST on 970, total 1019', c1.s === 200 && Number(c1.j.discount) === 30 && Number(c1.j.total) === 1019, c1);
  ok('coupon: business B 404', (await rpc(B, 'rst_bill_coupon', { order_id: o2, code: 'DINEQR30' })).s === 404);
  const n1 = await rpc(A, 'rst_bill_note', { order_id: o2, note: 'No onions' });
  ok('kitchen note saved', n1.s === 200 && n1.j.notes === 'No onions', n1);
  ok('kitchen note: business B 404', (await rpc(B, 'rst_bill_note', { order_id: o2, note: 'x' })).s === 404);
  const w = await rpc(A, 'rst_bill_pay', { order_id: o2, method: 'card' }, k());
  ok('T14 paid in one go by card: 1019', w.s === 200 && Number(w.j.amount) === 1019 && w.j.order_paid && w.j.table_settled, w);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  sql(`update orders set notes='ZZ-TEST rst' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch { /* older schema */ }
  // the split plans and coupon uses point at the orders: removed first (append-only guards lifted for this dev cleanup only)
  for (const t of ['rst_bill_parts', 'rst_bill_splits', 'sell_coupon_redemptions']) sql(`alter table ${t} disable trigger user`);
  sql(`delete from rst_bill_parts where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from rst_bill_splits where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_coupon_redemptions where organization_id in ('${orgA}','${orgB}')`);
  for (const t of ['rst_bill_parts', 'rst_bill_splits', 'sell_coupon_redemptions']) sql(`alter table ${t} enable trigger user`);
  sql(`delete from sell_coupons where organization_id in ('${orgA}','${orgB}')`);
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim().split('\n').pop()); }
  catch (e) { console.log('purge skipped (another suite\'s test rows block it; the next purge run removes these too): ' + String(e.stderr ?? e.message).split('\n')[0]); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
