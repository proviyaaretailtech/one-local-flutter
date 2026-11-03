// E2E: dining areas in table management (database 0646) over HTTP against the standalone POS server, as real signed-in staff of two
// businesses: add / rename / kinds, duplicates, which tables are in an area, stats, order, switching an area off (its free tables leave the
// floor, ones with guests stay), deleting (only empty), joined tables moving together, the next bookings, roles. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-dining-areas-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
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
const org = randomUUID(), orgB = randomUUID();
async function staff(o, role, tag) {
  const email = `zz-area-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ AREA ${run}','zz-area-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ AREA B ${run}','zz-area-b-${run}','franchise','Restaurant')`);
  const loc = sql(`select id from locations where organization_id='${org}' limit 1`);
  const T = {};
  for (const [label, seats] of [['A1', 4], ['A2', 4], ['A3', 2]]) { T[label] = randomUUID(); sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${T[label]}','${org}','${loc}','${label}',${seats})`); }
  const MGR = await staff(org, 'manager', 'mgr'), CAP = await staff(org, 'captain', 'cap'), VIEW = await staff(org, 'viewer', 'view'), B = await staff(orgB, 'org_owner', 'own-b');
  ok('staff signed in', [MGR, CAP, VIEW, B].every(x => x.token));

  let r = await rpc(MGR, 'tbl_areas', {});
  ok('no areas yet: 3 tables, none linked', r.s === 200 && r.j.areas.length === 0 && r.j.stats.tables === 3 && r.j.stats.tables_unassigned === 3 && r.j.can.manage === true, r.j);
  r = await rpc(MGR, 'tbl_area_save', { name: 'Rooftop', area_type: 'rooftop' });
  const roof = r.j?.area?.id;
  ok('add Rooftop (rooftop)', r.s === 200 && r.j.area.name === 'Rooftop' && r.j.area.area_type === 'rooftop' && r.j.area.active === true, r);
  r = await rpc(MGR, 'tbl_area_save', { name: 'AC Hall', area_type: 'ac_hall' });
  const hall = r.j?.area?.id;
  ok('add AC Hall', r.s === 200, r);
  ok('the same name again (any case) is refused', (await rpc(MGR, 'tbl_area_save', { name: 'rooftop' })).s === 409);
  ok('an unknown kind is refused', (await rpc(MGR, 'tbl_area_save', { name: 'Cellar', area_type: 'cave' })).s === 400);
  ok('a viewer cannot add an area (table managers can: the same people as Manage tables)', (await rpc(VIEW, 'tbl_area_save', { name: 'Garden' })).s === 403);
  ok('a viewer cannot see the areas', (await rpc(VIEW, 'tbl_areas', {})).s === 403);
  r = await rpc(MGR, 'tbl_area_save', { id: hall, name: 'AC Hall 1', area_type: 'ac_hall' });
  ok('rename AC Hall to AC Hall 1', r.s === 200 && r.j.area.name === 'AC Hall 1', r);

  // ---- which tables are in an area
  r = await rpc(MGR, 'tbl_area_tables', { id: roof, table_ids: [T.A1, T.A2] });
  ok('A1 and A2 go to Rooftop', r.s === 200 && r.j.area.table_count === 2 && r.j.area.seats === 8, r);
  r = await rpc(CAP, 'tbl_areas', {});
  ok('stats: 2 areas, 2 tables linked, 1 in use, 1 needs tables, largest Rooftop (2)', r.s === 200 && r.j.stats.areas === 2 && r.j.stats.tables_linked === 2
    && r.j.stats.in_use === 1 && r.j.stats.needs_tables === 1 && r.j.stats.largest.name === 'Rooftop' && r.j.stats.largest.tables === 2, r.j.stats);

  // ---- order on the floor
  r = await rpc(MGR, 'tbl_area_reorder', { ids: [hall, roof] });
  ok('AC Hall 1 first, then Rooftop', r.s === 200 && r.j.areas[0].id === hall && r.j.areas[1].id === roof, r.j?.areas);
  ok('an order missing an area is refused', (await rpc(MGR, 'tbl_area_reorder', { ids: [roof] })).s === 409);
  r = await rpc(CAP, 'tbl_floor', {});
  ok('the floor lists the areas in that order and A1 under Rooftop', r.j.areas.map(a => a.id).join() === [hall, roof].join() && r.j.tables.find(t => t.id === T.A1)?.area_name === 'Rooftop', r.j);

  // ---- an area switched off
  sql(`insert into orders(order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values (9501,'Z9501','${org}','${loc}','dine_in','sent_to_kitchen','${T.A1}',100,5,5,105,'ZZ-TEST area')`);
  r = await rpc(MGR, 'tbl_area_set_active', { id: roof, active: false });
  ok('Rooftop switched off', r.s === 200 && r.j.area.active === false, r);
  r = await rpc(CAP, 'tbl_floor', {});
  ok('…its free table A2 leaves the floor; A1 with guests stays; A3 (no area) stays', !r.j.tables.some(t => t.id === T.A2) && r.j.tables.some(t => t.id === T.A1) && r.j.tables.some(t => t.id === T.A3), r.j.tables.map(t => t.label));
  ok('…and Rooftop is not offered as an area', !r.j.areas.some(a => a.id === roof));
  ok('…counts follow (A1 + A3)', r.j.counts.all === 2, r.j.counts);
  await rpc(MGR, 'tbl_area_set_active', { id: roof, active: true });
  ok('switched on again: A2 is back', (await rpc(CAP, 'tbl_floor', {})).j.tables.some(t => t.id === T.A2));

  // ---- delete
  r = await rpc(MGR, 'tbl_area_delete', { id: roof });
  ok('Rooftop with 2 tables cannot be deleted', r.s === 409 && /move them/i.test(JSON.stringify(r.j)), r);
  r = await rpc(MGR, 'tbl_area_save', { name: 'Garden', area_type: 'garden' });
  const garden = r.j.area.id;
  r = await rpc(MGR, 'tbl_area_delete', { id: garden });
  ok('an empty area is deleted', r.s === 200 && r.j.name === 'Garden', r);

  // ---- joined tables move together
  r = await rpc(MGR, 'tbl_merge', { table_ids: [T.A1, T.A2] });
  ok('A1 and A2 joined', r.s === 200, r);
  r = await rpc(MGR, 'tbl_area_tables', { id: hall, table_ids: [T.A2] });
  ok('moving only A2 of the joined pair is refused', r.s === 409 && /joined/i.test(JSON.stringify(r.j)), r);
  r = await rpc(MGR, 'tbl_area_tables', { id: hall, table_ids: [T.A1, T.A2] });
  ok('moving both together works', r.s === 200 && r.j.area.table_count === 2, r);

  // ---- the next bookings
  const tomorrow = new Date(Date.now() + 26 * 3600e3).toISOString();
  r = await rpc(CAP, 'tbl_reserve', { table_id: T.A3, guest_name: 'Asha', phone: '+91 98765 43210', guests: 2, scheduled_at: tomorrow, idempotency_key: randomUUID() });
  ok('a booking on A3 for tomorrow', r.s === 200, r);
  r = await rpc(CAP, 'tbl_areas', {});
  if (process.env.FIXTURES) writeFileSync(process.env.FIXTURES, JSON.stringify({ areas: r.j }, null, 1));
  ok('the next bookings list it with its table', r.j.upcoming.some(u => u.table_label === 'A3' && u.guest_name === 'Asha' && /^\d\d:\d\d$/.test(u.local_time)), r.j.upcoming);

  // ---- another business
  ok('another business cannot change these areas', [403, 404].includes((await rpc(B, 'tbl_area_save', { id: roof, name: 'Taken' })).s));
  ok('…nor sees them', (await rpc(B, 'tbl_areas', {})).j?.areas?.length === 0);
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
