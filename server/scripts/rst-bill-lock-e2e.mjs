// E2E: a generated bill is locked; changes need an admin PIN and a note (database 0645), over HTTP against the standalone POS server, as real
// signed-in staff: the owner sets a PIN; a cashier's discount before the bill needs none, after it needs the PIN; a coupon, a dish cancelled,
// a whole order cancelled after its KOT need it too; wrong tries lock out; the Leakage audit and the owner's dashboard show every change.
// LOCAL ONLY. Usage (from one-local-flutter/server, server running):  node scripts/rst-bill-lock-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
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
const org = randomUUID(), orgB = randomUUID();
async function staff(o, role, tag) {
  const email = `zz-lock-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${o}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function rpc(who, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
async function rest(who, path, body) {
  const r = await fetch(`${API}${path}`, { method: 'POST', headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;
const PIN = '482915';

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ LOCK ${run}','zz-lock-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ LOCK B ${run}','zz-lock-b-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const dish = (name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${org}','${name}',${price})`); return id; };
  const thali = dish('Thali', 400), lassi = dish('Lassi', 50);
  sql(`insert into sell_coupons(organization_id,code,kind,value) values ('${org}','FLAT50','flat',50)`);
  const table = n => { const id = randomUUID(); sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${id}','${org}','${loc}','L${n}',4)`); return id; };
  const OWN = await staff(org, 'org_owner', 'own'), MGR = await staff(org, 'manager', 'mgr'), CASH = await staff(org, 'biller', 'cash'), CAP = await staff(org, 'captain', 'cap'),
    BOWN = await staff(orgB, 'org_owner', 'own-b');
  ok('staff signed in', [OWN, MGR, CASH, CAP, BOWN].every(x => x.token));
  const add = (t, lines) => rpc(CAP, 'tbl_order_add', { table_id: t, lines, send: true, idempotency_key: k() }, k());
  const orderOf = t => sql(`select id from orders where table_id='${t}' and status not in ('paid','cancelled') order by created_at desc limit 1`);
  const generate = o => rpc(CASH, 'pos_set_order_status', { order_id: o, to: 'awaiting_payment' });
  const passFor = async who => (await rpc(who, 'rst_admin_pin_check', { pin: PIN })).j?.pass_id;

  // ---- the PIN
  let r = await rpc(CASH, 'rst_admin_pin_check', { pin: PIN });
  ok('before any PIN is set: says the owner sets one in Settings', r.s === 409 && /settings/i.test(JSON.stringify(r.j)), r);
  ok('a cashier cannot set an admin PIN', (await rpc(CASH, 'rst_admin_pin_set', { pin: PIN })).s === 403);
  ok('a manager cannot either', (await rpc(MGR, 'rst_admin_pin_set', { pin: PIN })).s === 403);
  ok('an easy PIN is refused', (await rpc(OWN, 'rst_admin_pin_set', { pin: '111111' })).s === 400);
  ok('not 6 digits is refused', (await rpc(OWN, 'rst_admin_pin_set', { pin: '48291' })).s === 400);
  r = await rpc(OWN, 'rst_admin_pin_set', { pin: PIN });
  ok('the owner sets a PIN', r.s === 200 && r.j.has_pin === true && r.j.admins_with_pin === 1, r);
  ok('…kept only as a hash', sql(`select pin_hash <> '${PIN}' and pin_hash like '$2%' from rst_admin_pins where organization_id='${org}'`) === 't');
  r = await rpc(CASH, 'rst_admin_pin_status', {});
  ok('a cashier sees an admin PIN exists, and may not set one', r.s === 200 && r.j.can_set === false && r.j.admins_with_pin === 1, r);

  // ---- a discount: free before the bill, locked after it
  const t1 = table(1);
  await add(t1, [{ menu_item_id: thali, qty: 2 }]);
  const o1 = orderOf(t1);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 5, reason: 'Regular guest' });
  ok('a cashier gives 5% before the bill is generated: no PIN', r.s === 200 && sql(`select discount from orders where id='${o1}'`) === '40.00', r);
  ok('the bill is generated', (await generate(o1)).s === 200);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 10, reason: 'More' });
  ok('a discount after the bill without a PIN: refused, asks for the admin PIN', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(MGR, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 10, reason: 'More' });
  ok('…a manager too', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(CASH, 'rst_admin_pin_check', { pin: '000000' });
  ok('a wrong PIN: not ok, tries left', r.s === 200 && r.j.ok === false && r.j.tries_left === 4, r);
  r = await rpc(BOWN, 'rst_admin_pin_set', { pin: '739104' });
  ok('another business\'s owner sets their own PIN', r.s === 200);
  ok('…which does not open this business\'s bills', (await rpc(CASH, 'rst_admin_pin_check', { pin: '739104' })).j?.ok === false);
  let pid = await passFor(CASH);
  ok('the right PIN gives a pass', !!pid);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 10, reason: 'More', admin_pass: pid });
  ok('a pass without a note is refused', r.s === 403 && /note/i.test(JSON.stringify(r.j)), r);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 10, reason: 'More', admin_pass: pid, admin_note: 'Owner allowed 10% for a regular' });
  ok('with the pass and a note: 10% given on the generated bill', r.s === 200 && sql(`select discount from orders where id='${o1}'`) === '80.00', r);
  ok('…logged with who did it and whose PIN approved it',
    sql(`select (meta->>'by')||'|'||(meta->>'approved_by')||'|'||(meta->>'note') from order_events where order_id='${o1}' and kind='admin_override'`) === `${CASH.id}|${OWN.id}|Owner allowed 10% for a regular`);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 12, reason: 'Again', admin_pass: pid, admin_note: 'Again' });
  ok('a pass works once', r.s === 403 && /already used/i.test(JSON.stringify(r.j)), r);
  const cpid = await passFor(CAP);
  r = await rpc(CASH, 'rst_bill_discount', { order_id: o1, kind: 'percent', value: 12, reason: 'Borrowed', admin_pass: cpid, admin_note: 'Borrowed pass' });
  ok('a pass is only for the person who typed the PIN', r.s === 403, r);

  // ---- a coupon after the bill
  const t2 = table(2);
  await add(t2, [{ menu_item_id: thali, qty: 1 }]);
  const o2 = orderOf(t2);
  await generate(o2);
  r = await rpc(CASH, 'rst_bill_coupon', { order_id: o2, code: 'FLAT50' });
  ok('a coupon after the bill: asks for the admin PIN', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(CASH, 'rst_bill_coupon', { order_id: o2, code: 'FLAT50', admin_pass: await passFor(CASH), admin_note: 'Guest had the coupon' });
  ok('…with it: applied', r.s === 200 && sql(`select discount from orders where id='${o2}'`) === '50.00', r);

  // ---- a dish cancelled on a generated bill: the PIN decides (no manager request)
  const t3 = table(3);
  await add(t3, [{ menu_item_id: thali, qty: 1 }, { menu_item_id: lassi, qty: 2 }]);
  const o3 = orderOf(t3);
  await generate(o3);
  const lassiLine = sql(`select id from order_items where order_id='${o3}' and name='Lassi'`);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: o3, items: [{ item_id: lassiLine, qty: 1 }], reason: 'Not served' }, k());
  ok('cancelling a dish on a generated bill: asks for the admin PIN', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: o3, items: [{ item_id: lassiLine, qty: 1 }], reason: 'Not served', admin_pass: await passFor(CAP), admin_note: 'One lassi never came' }, k());
  ok('…with it: cancelled at once, not a request', r.s === 200 && r.j.status === 'cancelled', r);

  // ---- cancelling a whole order after its KOT
  const t4 = table(4);
  await add(t4, [{ menu_item_id: thali, qty: 1 }]);
  const o4 = orderOf(t4);
  r = await rest(CASH, `/api/partner/pos-orders/${o4}/cancel`, { reason: 'Guest left' });
  ok('a cashier cancels an order the kitchen has: asks for the admin PIN', r.s === 403 && r.j?.code === 'admin_pin_required', r);
  ok('…the order is still open', sql(`select status from orders where id='${o4}'`) === 'sent_to_kitchen');
  r = await rest(CASH, `/api/partner/pos-orders/${o4}/cancel`, { reason: 'Guest left', admin_pass: await passFor(CASH), admin_note: 'Guest walked out before eating' });
  ok('…with the PIN and a note: cancelled', r.s === 200 && sql(`select status from orders where id='${o4}'`) === 'cancelled', r);
  ok('…logged with the cashier\'s name and the note', sql(`select meta->>'by' from order_events where order_id='${o4}' and kind='admin_override'`) === CASH.id
    && sql(`select meta->>'note' from order_events where order_id='${o4}' and kind='admin_override'`) === 'Guest walked out before eating');

  // an order the kitchen never got is cancelled without a PIN
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines: [{ menu_item_id: lassi, qty: 1 }], send: false, idempotency_key: k() });
  const held = r.j?.order_id;
  r = await rest(CASH, `/api/partner/pos-orders/${held}/cancel`, { reason: 'Guest changed mind' });
  ok('an order not yet with the kitchen is cancelled without a PIN', r.s === 200 && sql(`select status from orders where id='${held}'`) === 'cancelled', r);

  // the owner's void of a paid bill (0640) needs no PIN
  r = await rpc(CASH, 'rst_bill_pay', { order_id: o2, method: 'cash', tendered: 400 }, k());
  ok('bill 2 paid', r.s === 200, r);
  r = await rpc(OWN, 'rst_bill_void', { order_id: o2, reason: 'Wrong table billed', method: 'cash' }, k());
  ok('the owner voids a paid bill as before (no PIN)', r.s === 200 && r.j.status === 'voided', r);

  // ---- wrong tries lock out
  for (let i = 0; i < 4; i++) await rpc(CASH, 'rst_admin_pin_check', { pin: '000000' });
  r = await rpc(CASH, 'rst_admin_pin_check', { pin: PIN });
  ok('5 wrong PINs in 15 minutes: locked out, even with the right one', r.s === 429, r);

  // ---- the Leakage audit and the owner's dashboard
  r = await rpc(OWN, 'rst_report_audit', {});
  const ov = r.j?.overrides;
  ok('Leakage audit: 4 admin PIN changes (discount, coupon, dish, cancelled order)', r.s === 200 && ov?.count === 4, ov);
  const d1 = ov?.list?.find(x => x.order_id === o1);
  ok('…each with the note, who did it and whose PIN', d1?.note === 'Owner allowed 10% for a regular' && d1.by === 'ZZ cash' && d1.approved_by === 'ZZ own', d1);
  ok('…the discount after the bill is a change after the bill', r.j?.after_bill?.list?.some(x => x.order_id === o1 && x.kind === 'manual_discount'), r.j?.after_bill);
  ok('…the bill generated today shows at once as billed, not paid', r.j?.unpaid?.list?.some(x => x.order_id === o1 || x.id === o1 || JSON.stringify(x).includes(o1)), r.j?.unpaid);
  r = await rpc(OWN, 'rst_home_insights', {});
  ok('owner\'s dashboard: 4 admin PIN changes today, the latest listed', r.s === 200 && r.j.leakage?.admin_changes === 4 && r.j.leakage.latest.length === 3, r.j?.leakage);
  r = await rpc(CAP, 'rst_home_insights', {});
  ok('…not shown to a captain', r.s === 200 && r.j.leakage === null, r.j?.leakage);
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
