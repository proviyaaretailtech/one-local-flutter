// E2E: the restaurant's cash drawer never goes below zero (database 0647), over HTTP against the standalone POS server, as a real signed-in
// owner: ₹500 cash in, ₹400 paid out in cash, then removing the cash in is refused (it used to leave −₹500 … here −₹400); a cash in that
// is still in the drawer can be removed; a cash refund bigger than the drawer is refused, by UPI it goes through. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-cash-never-negative-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
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
  const email = `zz-cash-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ CASH ${run}','zz-cash-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const cash = () => +sql(`select rmoney_cash_now('${org}', array['${loc}'::uuid])`);
  const OWN = await staff('org_owner', 'own');
  ok('owner signed in', !!OWN.token);

  // ---- the founder's case: ₹500 in, ₹400 out, then remove the ₹500
  let r = await rpc(OWN, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 50000, note: 'Float' }, k());
  const cin = r.j?.id;
  ok('₹500 cash in', r.s === 200 && cash() === 50000, r);
  r = await rpc(OWN, 'rmoney_record', { direction: 'out', kind: 'expense', category: 'Vegetables', method: 'cash', amount_minor: 40000, note: 'Market' }, k());
  ok('₹400 paid out in cash: ₹100 left', r.s === 200 && cash() === 10000, r);
  r = await rpc(OWN, 'rmoney_void', { id: cin, reason: 'Entered by mistake' });
  ok('removing the ₹500 cash in is refused (it would leave −₹400)', r.s === 422 && /cash drawer/i.test(JSON.stringify(r.j)), r);
  ok('…the drawer still holds ₹100, never below zero', cash() === 10000);
  ok('…the entry is still posted', sql(`select status from rmoney_entries where id='${cin}'`) === 'posted');

  // a cash in still in the drawer can be removed
  r = await rpc(OWN, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 30000, note: 'Second float' }, k());
  const cin2 = r.j?.id;
  r = await rpc(OWN, 'rmoney_void', { id: cin2, reason: 'Counted twice' });
  ok('a ₹300 cash in still in the drawer can be removed', r.s === 200 && r.j.status === 'voided' && cash() === 10000, r);

  // a UPI in is not cash: removing it never touches the drawer
  r = await rpc(OWN, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'upi', amount_minor: 90000, note: 'UPI in' }, k());
  r = await rpc(OWN, 'rmoney_void', { id: r.j?.id, reason: 'Wrong account' });
  ok('removing a UPI money in is not limited by the drawer', r.s === 200, r);

  // ---- a cash refund bigger than the drawer
  const o = randomUUID(), t = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${org}','${loc}','C1',4)`);
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values ('${o}',9601,'Z9601','${org}','${loc}','dine_in','awaiting_payment','${t}',0,5,0,0,'ZZ-TEST cash')`);
  sql(`insert into order_items(order_id,name,qty,unit_price,status) values ('${o}','Thali',2,500,'delivered')`);
  sql(`select tbl_order_reprice('${o}')`);
  r = await rpc(OWN, 'rst_bill_pay', { order_id: o, method: 'upi', reference: 'UPI-1' }, k());
  ok('a ₹1,050 bill paid by UPI (the drawer still ₹100)', r.s === 200 && cash() === 10000, r);
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o, amount: 500, method: 'cash', reason: 'Cold food' }, k());
  ok('a ₹500 refund in cash is refused: only ₹100 in the drawer', r.s === 422 && /cash drawer/i.test(JSON.stringify(r.j)), r);
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o, amount: 500, method: 'upi', reason: 'Cold food' }, k());
  ok('…by UPI it goes through', r.s === 200 && r.j.status === 'refunded', r);
  r = await rpc(OWN, 'rst_bill_refund', { order_id: o, amount: 100, method: 'cash', reason: 'Goodwill' }, k());
  ok('a ₹100 cash refund (all the drawer holds) goes through, drawer at ₹0', r.s === 200 && cash() === 0, r);
  r = await rpc(OWN, 'rst_bill_void', { order_id: o, reason: 'Wrong table', method: 'cash' }, k());
  ok('voiding the bill with the rest (₹450) back in cash is refused: the drawer is empty', r.s === 422 && cash() === 0, r);
  r = await rpc(OWN, 'rst_bill_void', { order_id: o, reason: 'Wrong table', method: 'upi' }, k());
  ok('…by UPI it is voided', r.s === 200 && r.j.status === 'voided' && cash() === 0, r);
  ok('the drawer never went below zero', cash() >= 0);
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
