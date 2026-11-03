// E2E: manage reservations (database 0642) over HTTP against the standalone POS server's generic gateway (POST /rpc/<function>), as real
// signed-in staff of two businesses: book, list a day, the reserved table's sheet, seat (at its table or another), too early, occupied and
// too-small tables, cancel and no-show with a reason, an order seating its booking by itself, roles and another business. LOCAL ONLY.
// Leaves its two ZZ businesses on the local database.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-reservations-e2e.mjs   (POS_API, OL_DB, OL_ENV as rst-cancel-refund-e2e)
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
const msg = r => JSON.stringify(r.j ?? '').toLowerCase();
// FIXTURES=<file>: keep some real answers for the app's widget tests (test/fixtures/rst_reservations_server.json)
const FX = {};
const keep = (n, j) => { FX[n] = j; return j; };

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID();
async function staff(org, role, tag) {
  const email = `zz-rsv-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function rpc(who, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(who ? { Authorization: `Bearer ${who.token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const inMin = m => new Date(Date.now() + m * 60e3).toISOString();
const book = (who, table, minutes, name, guests = 2) =>
  rpc(who, 'tbl_reserve', { table_id: table, guest_name: name, phone: '+91 98765 43210', guests, scheduled_at: inMin(minutes), notes: 'Window seat', idempotency_key: randomUUID() });

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','Golden ZZ RSV A ${run}','zz-rsv-a-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ RSV B ${run}','zz-rsv-b-${run}','franchise','Restaurant')`);
  const locA = sql(`select id from locations where organization_id='${orgA}' limit 1`);
  const T = {};
  for (const [label, seats] of [['R1', 4], ['R2', 4], ['R3', 4], ['R4', 6], ['R5', 4], ['R6', 4], ['R7', 2]]) {
    T[label] = randomUUID();
    sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${T[label]}','${orgA}','${locA}','${label}',${seats})`);
  }
  const OWN = await staff(orgA, 'org_owner', 'own'), CAP = await staff(orgA, 'captain', 'cap'), VIEW = await staff(orgA, 'viewer', 'view'), B = await staff(orgB, 'org_owner', 'own-b');
  ok('four staff signed in', [OWN, CAP, VIEW, B].every(x => x.token));

  // ---- book and list
  let r = await book(CAP, T.R1, 30, 'Asha Rao', 3);
  ok('captain books R1 in 30 minutes for 3', r.s === 200 && r.j.reservation.status === 'confirmed', r);
  const asha = r.j.reservation.id;
  r = await rpc(CAP, 'tbl_reservations_list', {});
  keep('upcoming', r.j);
  const a = r.j?.reservations?.find(x => x.id === asha);
  ok('today\'s list has it with table, local time, phone and notes', r.s === 200 && a && a.table_label === 'R1' && /^\d\d:\d\d$/.test(a.local_time) && a.phone && a.notes === 'Window seat', r.j);
  ok('…it can be seated and cancelled, not yet a no-show', a?.can.seat === true && a?.can.cancel === true && a?.can.no_show === false, a?.can);
  ok('…counts: 1 upcoming, 3 guests', r.j?.counts.upcoming === 1 && r.j?.counts.guests === 3, r.j?.counts);
  r = await rpc(CAP, 'tbl_view', { table_id: T.R1 });
  keep('view_reserved', r.j);
  ok('the reserved table\'s sheet lists the booking with what may be done', r.s === 200 && r.j.status === 'reserved' && r.j.reservations[0]?.id === asha && r.j.reservations[0]?.can?.seat === true, r.j);

  // ---- seat
  r = await rpc(CAP, 'tbl_reserve_seat', { id: asha });
  keep('seated', r.j);
  ok('captain seats Asha at R1', r.s === 200 && r.j.reservation.status === 'seated' && r.j.reservation.seated_at && r.j.table.label === 'R1' && r.j.moved === false, r);
  ok('seating twice is refused', (await rpc(CAP, 'tbl_reserve_seat', { id: asha })).s === 409);
  r = await rpc(CAP, 'tbl_reservations_list', { status: 'seated' });
  ok('the Seated filter shows her', r.j?.reservations?.length === 1 && r.j.counts.seated === 1, r.j);

  r = await book(CAP, T.R2, 300, 'Later Guest');
  const later = r.j?.reservation?.id;
  r = await rpc(CAP, 'tbl_reserve_seat', { id: later });
  ok('a booking five hours away cannot be seated yet', r.s === 400 && msg(r).includes('two hours'), r);

  // at another table: free and big enough; not one with an open bill; not one too small
  r = await book(CAP, T.R3, 45, 'Kiran', 5);
  ok('a party of 5 is refused at a 4-seat table when booking', r.s >= 400 && msg(r).includes('seats'), r);
  r = await book(CAP, T.R3, 45, 'Kiran', 4);
  const kiran = r.j?.reservation?.id;
  const open = randomUUID();
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values ('${open}',9301,'Z9301','${orgA}','${locA}','dine_in','sent_to_kitchen','${T.R5}',100,5,5,105,'ZZ-TEST rsv')`);
  r = await rpc(CAP, 'tbl_reserve_seat', { id: kiran, table_id: T.R5 });
  ok('not at a table that still has an open bill', r.s === 409 && msg(r).includes('open bill'), r);
  r = await rpc(CAP, 'tbl_reserve_seat', { id: kiran, table_id: T.R7 });
  ok('not at a table too small for them', r.s >= 400 && msg(r).includes('seats'), r);
  r = await rpc(CAP, 'tbl_reserve_seat', { id: kiran, table_id: T.R4 });
  ok('seated at R4 instead: the booking moves there', r.s === 200 && r.j.table.label === 'R4' && r.j.moved === true && sql(`select table_id from pos_reservations where row_id='${kiran}'`) === T.R4, r);

  // ---- cancel and no-show
  r = await rpc(CAP, 'tbl_reserve_cancel', { id: later, reason: 'Guest called to cancel' });
  ok('cancel with a reason', r.s === 200 && r.j.reservation.status === 'cancelled' && r.j.reservation.outcome_reason === 'Guest called to cancel', r);
  ok('…cancelling again is refused', (await rpc(CAP, 'tbl_reserve_cancel', { id: later })).s === 409);
  ok('…and it cannot be seated', (await rpc(CAP, 'tbl_reserve_seat', { id: later })).s === 409);
  r = await book(CAP, T.R6, 60, 'Meera');
  const meera = r.j?.reservation?.id;
  r = await rpc(CAP, 'tbl_reserve_cancel', { id: meera, outcome: 'no_show' });
  ok('a no-show before its time is refused', r.s === 400, r);
  sql(`update pos_reservations set scheduled_at = now() - interval '25 minutes' where row_id = '${meera}'`);
  r = await rpc(CAP, 'tbl_reservations_list', {});
  const m = r.j?.reservations?.find(x => x.id === meera);
  ok('25 minutes past and not here: late, and a no-show is offered', m?.late === true && m?.can.no_show === true && r.j.counts.late === 1, m);
  r = await rpc(CAP, 'tbl_reserve_cancel', { id: meera, outcome: 'no_show', reason: 'Did not answer the phone' });
  keep('no_show', r.j);
  ok('marked a no-show', r.s === 200 && r.j.reservation.status === 'no_show' && r.j.reservation.outcome_at, r);
  r = await rpc(CAP, 'tbl_reservations_list', { status: 'all' });
  keep('all', r.j);
  ok('All: 4 bookings (seated 2, cancelled 1, no-show 1)', r.j?.counts.all === 4 && r.j.counts.seated === 2 && r.j.counts.cancelled === 1 && r.j.counts.no_show === 1, r.j?.counts);
  r = await rpc(CAP, 'tbl_reservations_list', { status: 'cancelled' });
  ok('the Cancelled filter shows the reason', r.j?.reservations?.[0]?.outcome_reason === 'Guest called to cancel', r.j);

  // ---- an order started on the table still seats its booking by itself, now with the time
  r = await book(CAP, T.R2, 20, 'Walk-up booking');
  const auto = r.j?.reservation?.id;
  sql(`insert into orders(order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values (9302,'Z9302','${orgA}','${locA}','dine_in','new','${T.R2}',0,5,0,0,'ZZ-TEST rsv')`);
  ok('starting an order on R2 seats its booking, with the time', sql(`select status || ':' || (seated_at is not null) from pos_reservations where row_id='${auto}'`) === 'seated:true');

  // ---- another day, roles, another business
  const tomorrow = new Date(Date.now() + 5.5 * 3600e3 + 86400e3).toISOString().slice(0, 10);
  r = await rpc(CAP, 'tbl_reservations_list', { date: tomorrow, status: 'all' });
  ok('tomorrow\'s list is its own day', r.s === 200 && r.j.date === tomorrow, r.j);
  ok('a bad date is refused', (await rpc(CAP, 'tbl_reservations_list', { date: '3 Nov' })).s === 400);
  ok('a viewer cannot see the bookings', (await rpc(VIEW, 'tbl_reservations_list', {})).s === 403);
  ok('another business cannot seat them', [403, 404].includes((await rpc(B, 'tbl_reserve_seat', { id: kiran })).s));
  ok('another business does not see them', (await rpc(B, 'tbl_reservations_list', { status: 'all' })).j?.reservations?.length === 0);
  ok('nothing was deleted: all 5 bookings are still there', sql(`select count(*) from pos_reservations where organization_id='${orgA}' and deleted_at is null`) === '5');
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
if (process.env.FIXTURES) writeFileSync(process.env.FIXTURES, JSON.stringify(FX, null, 1));
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
