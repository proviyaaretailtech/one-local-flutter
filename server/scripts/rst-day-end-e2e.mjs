// E2E: the restaurant's Day end (database 0650), over HTTP against the standalone POS server, as real signed-in staff: the cash drawer lists
// the bills still open (a table, a takeaway, a held takeaway; not a Swiggy order); Day end stops and says so; ending the day anyway needs a
// note and puts each open bill in Revenue leakage (the Leakage audit and the dashboard card); a manager cannot reopen an ended day, the
// owner can (with a reason): the count's cash difference is voided and cash can be recorded again; the day can then end again. A day with
// no open bills ends at once. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-day-end-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
//   FIXTURES=../test/fixtures/rst_day_end_server.json also writes the real answers for the widget tests.
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
const org = randomUUID(), org2 = randomUUID();
async function staff(o, role, tag) {
  const email = `zz-dayend-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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
const k = () => `e2e-${randomUUID()}`;
const said = (r, re) => re.test(JSON.stringify(r.j));
const fx = {};

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ DAYEND ${run}','zz-dayend-${run}','franchise','Restaurant'),('${org2}','Golden ZZ DAYEND2 ${run}','zz-dayend2-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const dish = (name, price) => { const id = randomUUID(); sql(`insert into menu_items(id,organization_id,name,price) values ('${id}','${org}','${name}',${price})`); return id; };
  const thali = dish('Thali', 400), lassi = dish('Lassi', 100);
  const OWN = await staff(org, 'org_owner', 'own'), MGR = await staff(org, 'manager', 'mgr'), CAP = await staff(org, 'captain', 'cap'), OWN2 = await staff(org2, 'org_owner', 'own2');
  ok('owner, manager, captain and a second owner signed in', [OWN, MGR, CAP, OWN2].every(x => x.token));

  // ---- a day with no open bills ends at once
  let r = await rpc(OWN2, 'rmoney_register', {});
  ok('a day with nothing open: no open bills', r.s === 200 && r.j.open_bills?.count === 0 && r.j.can_reopen === false, r);
  r = await rpc(OWN2, 'rmoney_close_day', { counted_minor: 0 });
  ok('…Day end at once, no note needed', r.s === 200 && r.j.closed?.counted_minor === 0 && r.j.closed.open_bills === 0, r);

  // ---- open bills: a table (sent), a takeaway (sent), a takeaway on hold; a Swiggy order is not one of them
  const t = randomUUID();
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${org}','${loc}','T7',4)`);
  r = await rpc(CAP, 'tbl_order_add', { table_id: t, lines: [{ menu_item_id: thali, qty: 1 }], send: true, idempotency_key: k() }, k());
  ok('a table order of ₹420 (T7)', r.s === 200, r);
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines: [{ menu_item_id: lassi, qty: 1 }], send: true, idempotency_key: k() });
  ok('a takeaway of ₹105 sent to the kitchen', r.s === 200, r);
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines: [{ menu_item_id: lassi, qty: 2 }], send: false, idempotency_key: k() });
  ok('a takeaway of ₹210 on hold', r.s === 200, r);
  const sw = randomUUID();
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,subtotal,gst_pct,gst_amount,total,notes) values ('${sw}',9901,'Z9901','${org}','${loc}','swiggy','sent_to_kitchen',100,5,5,105,'ZZ-TEST dayend')`);
  sql(`insert into order_items(order_id,name,qty,unit_price,status) values ('${sw}','Lassi',1,100,'preparing')`);

  r = await rpc(MGR, 'rmoney_register', {});
  fx.register_open = r.j;
  const ob = r.j?.open_bills;
  ok('the cash drawer lists 3 open bills, ₹735 due, one of them a table', r.s === 200 && ob?.count === 3 && ob.tables === 1 && ob.due_minor === 73500
    && ob.list.map(b => b.place).sort().join() === 'Table T7,Takeaway,Takeaway', ob);
  ok('…a Swiggy order is not one of them (paid on Swiggy)', !ob?.list.some(b => b.order_id === sw));
  ok('…a manager may end the day but not reopen it', r.j?.can_close === true && r.j?.can_reopen === false, r.j && { can_close: r.j.can_close, can_reopen: r.j.can_reopen });

  r = await rpc(MGR, 'rmoney_close_day', { counted_minor: -5 });
  ok('a count below zero is refused, and says so', r.s === 400 && said(r, /counted/i), r);
  r = await rpc(MGR, 'rmoney_close_day', { counted_minor: 50000 });
  ok('Day end with bills open: refused, and says how many and what is due', r.s === 409 && r.j?.code === 'open_bills' && said(r, /3 bills are still open \(₹735\.00\)/), r);
  ok('…the day is not ended', sql(`select count(*) from rmoney_day_closes where organization_id='${org}'`) === '0');
  r = await rpc(MGR, 'rmoney_close_day', { counted_minor: 50000, confirm_open_bills: true });
  ok('…ending it anyway without a note: refused', r.s === 422 && said(r, /write why/i), r);
  r = await rpc(MGR, 'rmoney_close_day', { counted_minor: 50000, confirm_open_bills: true, note: 'Table T7 still eating; takeaways not collected' });
  fx.register_closed = r.j;
  ok('…with a note: the day ends, ₹500 extra, 3 bills left open', r.s === 200 && r.j.closed?.difference_minor === 50000 && r.j.closed.open_bills === 3
    && r.j.closed.open_due_minor === 73500 && r.j.closed.note === 'Table T7 still eating; takeaways not collected', r);
  ok('…each open bill is recorded on the bill for Revenue leakage', sql(`select count(*) from order_events where organization_id='${org}' and kind='day_end_unsettled'`) === '3');
  ok('…the extra cash is recorded', sql(`select status||':'||amount_minor from rmoney_entries where organization_id='${org}' and kind='cash_difference'`) === 'posted:50000');
  r = await rpc(MGR, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 10000, note: 'Float' }, k());
  ok('cash cannot be recorded on an ended day', r.s >= 400, r);

  // ---- Revenue leakage
  r = await rpc(OWN, 'rst_report_audit', { period: 'today' });
  fx.audit = r.j;
  ok('the Leakage audit lists the 3 bills left unsettled (₹735), with the note and who ended the day', r.s === 200 && r.j.day_end?.unsettled?.count === 3
    && r.j.day_end.unsettled.due_minor === 73500 && r.j.day_end.unsettled.list[0].note === 'Table T7 still eating; takeaways not collected'
    && r.j.day_end.unsettled.list.some(x => x.place === 'Table T7') && r.j.day_end.unsettled.list[0].by === 'ZZ mgr', r.j?.day_end);
  r = await rpc(OWN, 'rst_home_insights', {});
  ok('the dashboard Revenue leakage card counts them', r.s === 200 && r.j.leakage?.unsettled === 3 && r.j.leakage.unsettled_due_minor === 73500, r.j?.leakage);

  // ---- reopen
  r = await rpc(MGR, 'rmoney_reopen_day', { reason: 'Counted wrong' });
  ok('a manager cannot reopen an ended day', r.s === 403, r);
  r = await rpc(OWN, 'rmoney_register', {});
  ok('the owner may reopen it', r.j?.can_reopen === true, r.j?.can_reopen);
  r = await rpc(OWN, 'rmoney_reopen_day', { reason: 'no' });
  ok('…a reason is needed', r.s === 400, r);
  r = await rpc(OWN, 'rmoney_reopen_day', { reason: 'Counted the float twice' });
  fx.register_reopened = r.j;
  ok('…reopened: not ended any more, the reopen is listed with the reason', r.s === 200 && r.j.closed === null && r.j.reopens?.length === 1
    && r.j.reopens[0].reason === 'Counted the float twice' && r.j.reopens[0].by === 'ZZ own' && r.j.can_close === true, r);
  ok('…the ₹500 extra no longer stands', sql(`select status from rmoney_entries where organization_id='${org}' and kind='cash_difference'`) === 'voided');
  r = await rpc(MGR, 'rmoney_record', { direction: 'in', kind: 'owner_money', method: 'cash', amount_minor: 10000, note: 'Float' }, k());
  ok('…cash can be recorded again', r.s === 200, r);
  r = await rpc(OWN, 'rmoney_reopen_day', { reason: 'Again' });
  ok('…a day that is not ended cannot be reopened', r.s === 400 && said(r, /has not ended/), r);

  // ---- end it again: ₹100 float in, counted ₹100 → matches; the open bills go to leakage again
  r = await rpc(MGR, 'rmoney_close_day', { counted_minor: 10000, confirm_open_bills: true, note: 'Still open at the second count' });
  ok('the day ends again: the cash matches', r.s === 200 && r.j.closed?.difference_minor === 0, r);
  r = await rpc(OWN, 'rst_report_audit', { period: 'today' });
  ok('the Leakage audit shows the reopen and both day ends', r.j?.day_end?.reopened?.count === 1 && r.j.day_end.reopened.list[0].reason === 'Counted the float twice'
    && r.j.day_end.unsettled.count === 6, r.j?.day_end && { reopened: r.j.day_end.reopened.count, unsettled: r.j.day_end.unsettled.count });
  r = await rpc(OWN, 'rst_home_insights', {});
  fx.insights = r.j;
  ok('the dashboard card counts the reopen', r.j?.leakage?.reopened === 1, r.j?.leakage);

  if (process.env.FIXTURES) { writeFileSync(process.env.FIXTURES, JSON.stringify(fx, null, 2)); console.log('fixtures written'); }
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
