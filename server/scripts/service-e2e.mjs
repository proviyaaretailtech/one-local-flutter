// E2E + cross-tenant test of the Service POS (section I) through the generic endpoint POST /rpc/<name>. LOCAL ONLY.
// Business A (manager, biller, viewer) sets up a service, a provider, hours, a package, sells it, books, checks in, works and bills a visit.
// Business B (a real signed-in owner) then tries every service function against A's ids: it must get nothing or an error, and A's rows
// must be unchanged. Tags its orders 'ZZ-TEST' and purges them.
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8093 OL_ENV=<local .env> node scripts/service-e2e.mjs
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
const orgA = randomUUID(), orgB = randomUUID(), staffA = randomUUID(), staffB = randomUUID();
const users = [];
async function person(tag, org, role) {
  const email = `zz-svc-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, args = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(args) });
  const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const refused = r => r.s >= 400 && r.s < 500;
const k = () => `svc-e2e-${randomUUID()}`;
// a local date n days ahead, 10:00 India time
const at = (days, hh = '10:00') => { const d = new Date(Date.now() + days * 86400000); return `${d.toISOString().slice(0, 10)}T${hh}:00+05:30`; };

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','ZZ SVC A ${run}','zz-svc-a-${run}','franchise'),('${orgB}','ZZ SVC B ${run}','zz-svc-b-${run}','franchise')`);
  // a business gets its main location when it is created
  const locA = sql(`select id from locations where organization_id='${orgA}' order by created_at limit 1`), locB = sql(`select id from locations where organization_id='${orgB}' order by created_at limit 1`);
  sql(`update locations set timezone='Asia/Kolkata' where id in ('${locA}','${locB}')`);
  sql(`insert into org_bill_settings(organization_id,sgst_pct,cgst_pct,service_charge_pct) values ('${orgA}',9,9,0),('${orgB}',9,9,0)`);
  sql(`insert into svc_settings(organization_id,deposit_amount) values ('${orgA}',200)`);
  sql(`insert into pos_staff(id,organization_id,location_id,staff_code,full_name,designation) values ('${staffA}','${orgA}','${locA}','ZA','ZZ Neha','Stylist'),('${staffB}','${orgB}','${locB}','ZB','ZZ B','Stylist')`);
  const A = await person('mgr-a', orgA, 'manager'), BL = await person('biller-a', orgA, 'biller'), V = await person('viewer-a', orgA, 'viewer'), B = await person('owner-b', orgB, 'org_owner');
  ok('signed in', !!A && !!BL && !!V && !!B);

  // ---- A sets up and runs a visit
  const svc = await rpc(A, 'svc_service_save', { name: 'ZZ Haircut', price: 600, category: 'Grooming', duration_min: 45, buffer_min: 15, checklist: ['Wash', 'Cut'] }, k());
  ok('A adds a service', svc.s === 200 && svc.j.code === 'APT-01', svc);
  const svcId = svc.j.id;
  ok('biller cannot add a service (403)', (await rpc(BL, 'svc_service_save', { name: 'ZZ X', price: 1 }, k())).s === 403);
  ok('viewer cannot see the catalogue', refused(await rpc(V, 'svc_service_list', {})));
  const prov = await rpc(A, 'svc_provider_save', { staff_id: staffA, title: 'Senior stylist', skills: 'Cutting', service_ids: [svcId] }, k());
  ok('A makes Neha a provider', prov.s === 200 && prov.j.counts.all === 1, prov);
  const week = [1, 2, 3, 4, 5, 6, 7];
  const sch = await rpc(A, 'svc_schedule_save', { location_id: locA, hours: week.map(d => ({ weekday: d, open: '09:00', close: '20:00' })),
    providers: [{ staff_id: staffA, hours: week.map(d => ({ weekday: d, start: '09:00', end: '20:00' })) }] }, k());
  ok('A saves the schedule', sch.s === 200 && sch.j.hours.length === 7, sch);
  const pkg = await rpc(A, 'svc_plan_save', { kind: 'package', name: 'ZZ Pack', price: 1000, status: 'active', validity_days: 90, items: [{ service_id: svcId, qty: 2 }] }, k());
  ok('A creates a package', pkg.s === 200 && pkg.j.savings === 200, pkg);
  const sell = await rpc(A, 'svc_entitlement_sell', { plan_id: pkg.j.id, customer_name: 'ZZ Riya', customer_phone: '9000000001', method: 'upi' }, k());
  ok('A sells it (paid order, 2 credits)', sell.s === 200 && sell.j.credits[0].left === 2, sell);
  const bookKey = k();
  const book = await rpc(A, 'svc_book', { customer_name: 'ZZ Riya', customer_phone: '9000000001', service_id: svcId, staff_id: staffA, starts_at: at(3), entitlement_id: sell.j.id }, bookKey);
  ok('A books with the package (total 0, confirmed)', book.s === 200 && Number(book.j.bill.total) === 0 && book.j.status === 'confirmed', book);
  const again = await rpc(A, 'svc_book', { customer_name: 'ZZ Riya', customer_phone: '9000000001', service_id: svcId, staff_id: staffA, starts_at: at(3), entitlement_id: sell.j.id }, bookKey);
  ok('same key, same body replays', again.s === 200 && again.j.id === book.j.id && again.j.replayed === true, again);
  const mism = await rpc(A, 'svc_book', { customer_name: 'ZZ Other', service_id: svcId, staff_id: staffA, starts_at: at(4) }, bookKey);
  ok('I-F5 same key, different body: 422 idempotency_mismatch', mism.s === 422 && mism.j.code === 'idempotency_mismatch', mism);
  const cal = await rpc(A, 'svc_calendar', { date: at(3).slice(0, 10) });
  ok('I-F6 calendar item carries its version', cal.s === 200 && cal.j.appointments.some(x => x.id === book.j.id && x.version === 1), cal);
  const apptId = book.j.id;
  const stale = await rpc(A, 'svc_appointment_act', { id: apptId, action: 'reschedule', starts_at: at(3, '11:00'), expected_version: 9 }, k());
  ok('stale version: 409 version_conflict', stale.s === 409 && stale.j.code === 'version_conflict', stale);
  const move = await rpc(A, 'svc_appointment_act', { id: apptId, action: 'reschedule', starts_at: at(3, '11:00'), expected_version: 1 }, k());
  ok('A reschedules', move.s === 200 && move.j.version === 2, move);

  const dash = await rpc(A, 'svc_dashboard', {});
  ok('A dashboard: visits, money, providers', dash.s === 200 && Number(dash.j.money.today) === 1180 && dash.j.next_up.some(v => v.id === apptId) && dash.j.plans.packages_active === 1 && dash.j.providers.all === 1, dash);
  ok('viewer cannot open the service dashboard', refused(await rpc(V, 'svc_dashboard', {})));

  // ---- B against A
  const x = (fn, args, key) => rpc(B, fn, args, key);
  const bd = await x('svc_dashboard', {});
  ok('B: dashboard holds nothing of A', bd.s === 200 && bd.j.today.visits === 0 && Number(bd.j.money.month) === 0 && !JSON.stringify(bd.j).includes(apptId) && (await x('svc_dashboard', { location_id: locA })).s === 404, bd);
  ok('B: A appointment not found', (await x('svc_appointment_view', { id: apptId })).s === 404);
  ok('B: cannot move, cancel, update or bill A appointment', (await x('svc_appointment_act', { id: apptId, action: 'cancel', reason: 'zz test', expected_version: 2 }, k())).s === 404
    && (await x('svc_job_update', { id: apptId, expected_version: 2, provider_notes: 'x' }, k())).s === 404
    && (await x('svc_bill', { id: apptId, expected_version: 2, method: 'cash' }, k())).s === 404);
  ok('B: A service detail not found, cannot edit it', (await x('svc_service_detail', { id: svcId })).s === 404 && (await x('svc_service_save', { id: svcId, name: 'Hacked', price: 1 }, k())).s === 404);
  ok('B: catalogue, staff, packages, history hold nothing of A', await (async () => {
    const [l, st, pl, h, c] = await Promise.all([x('svc_service_list', {}), x('svc_staff_list', {}), x('svc_plan_list', {}), x('svc_history', {}), x('svc_catalogue', {})]);
    const all = JSON.stringify([l.j, st.j, pl.j, h.j, c.j]);
    return [l, st, pl, h, c].every(r => r.s === 200) && !all.includes(svcId) && !all.includes(staffA) && !all.includes(apptId) && !all.includes(pkg.j.id);
  })());
  ok('B: cannot quote, slot or book A service with A provider', refused(await x('svc_quote', { service_id: svcId })) && refused(await x('svc_slots', { date: at(3).slice(0, 10), service_id: svcId }))
    && refused(await x('svc_book', { customer_name: 'X', service_id: svcId, staff_id: staffA, starts_at: at(5) }, k())));
  ok('B: cannot read or change A schedule, or A location calendar', (await x('svc_schedule', { location_id: locA })).s === 404
    && (await x('svc_schedule_save', { location_id: locA, hours: [] }, k())).s === 404 && (await x('svc_calendar', { location_id: locA })).s === 404);
  ok('B: cannot make A staff its provider', (await x('svc_provider_save', { staff_id: staffA }, k())).s === 404);
  ok('B: cannot sell A package, see or redeem A customer package', refused(await x('svc_entitlement_sell', { plan_id: pkg.j.id, customer_name: 'X', customer_phone: '9000000001', method: 'cash', tendered: 5000 }, k()))
    && (await x('svc_entitlements_for', { customer_phone: '9000000001' })).j?.entitlements?.length === 0);
  ok('B: cannot edit A package', refused(await x('svc_plan_save', { id: pkg.j.id, kind: 'package', name: 'Hacked', price: 1 }, k())));
  ok('A rows untouched after all of that', sql(`select status||':'||version from svc_appointments where id='${apptId}'`) === 'confirmed:2'
    && sql(`select name from menu_items where id='${svcId}'`) === 'ZZ Haircut' && sql(`select count(*) from svc_entitlements where organization_id='${orgA}'`) === '1');
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST svc' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('test businesses kept (appointments are never deleted): ZZ SVC A/B ' + run);
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
