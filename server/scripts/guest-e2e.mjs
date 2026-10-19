// E2E: table QR codes and the guest menu over HTTP against the standalone POS server (staff: POST /rpc/<name>; guest: POST /guest/<name>),
// with real signed-in staff of two businesses and an anonymous guest. LOCAL ONLY. Cross-tenant, guest abuse (bad codes, other tables, other
// businesses' dishes, replayed keys, waiting-order limit, per-address limit), replaced code, accept into a real order, Hand to guest.
// Tags its orders 'ZZ-TEST' and removes its users, guest rows and businesses at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/guest-e2e.mjs   (POS_API overrides the address; keys read from ./.env, never printed)
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
const tA1 = randomUUID(), tA2 = randomUUID(), tB1 = randomUUID(), dish = randomUUID(), hidden = randomUUID(), dishB = randomUUID();
const users = [];
async function staff(org, role, tag) {
  const email = `zz-guest-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function call(url, body, headers = {}) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body ?? {}) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const rpc = (token, fn, body, key) => call(`${API}/rpc/${fn}`, body, { Authorization: `Bearer ${token}`, ...(key ? { 'Idempotency-Key': key } : {}) });
const guest = (name, body) => call(`${API}/guest/${name}`, body);

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','ZZ Guest A ${run}','zz-guest-a-${run}','franchise','Restaurant'),('${orgB}','ZZ Guest B ${run}','zz-guest-b-${run}','franchise','Restaurant')`);
  const locA = sql(`select id from locations where organization_id='${orgA}' order by created_at limit 1`), locB = sql(`select id from locations where organization_id='${orgB}' order by created_at limit 1`);
  sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${tA1}','${orgA}','${locA}','G1',4),('${tA2}','${orgA}','${locA}','G2',2),('${tB1}','${orgB}','${locB}','B1',4)`);
  sql(`insert into menu_items(id,organization_id,name,price) values ('${dish}','${orgA}','ZZ Idli',80),('${hidden}','${orgA}','ZZ Hidden',90),('${dishB}','${orgB}','ZZ B Dish',100)`);
  for (const [org, def] of [[orgA, { brand: { display_name: 'ZZ Idli House' }, items: { [hidden]: { hidden: true } } }], [orgB, { brand: { display_name: 'ZZ B' } }]]) {
    sql(`select set_config('app.storefront_publish','1',false); insert into vinii_storefronts(organization_id,published_version) values ('${org}',1); insert into vinii_storefront_versions(organization_id,version,definition) values ('${org}',1,'${JSON.stringify(def)}'::jsonb)`);
  }
  const A = await staff(orgA, 'manager', 'mgr-a'), W = await staff(orgA, 'captain', 'cap-a'), V = await staff(orgA, 'viewer', 'view-a'), B = await staff(orgB, 'org_owner', 'owner-b'), K = await staff(orgA, 'kitchen', 'kit-a');
  ok('five staff signed in', !!A && !!W && !!V && !!B && !!K);

  // ---- codes
  const list0 = await rpc(A, 'tbl_qr_list', { location_id: locA });
  ok('qr list: two tables of A, manager may issue', list0.s === 200 && list0.j.tables.length === 2 && list0.j.can.issue === true, list0);
  const iss = await rpc(A, 'tbl_qr_issue', { location_id: locA, table_id: tA1 });
  const code = iss.j?.code;
  ok('issue: G1 gets a code', iss.s === 200 && /^[0-9a-f]{64}$/.test(code ?? ''), iss);
  ok("viewer: cannot issue (403), B: cannot issue on A's table (404)",
    (await rpc(V, 'tbl_qr_issue', { table_id: tA2 })).s === 403 && (await rpc(B, 'tbl_qr_issue', { table_id: tA1 })).s === 404);
  ok('kitchen: list shows codes are there but not the codes themselves, may not issue', await rpc(K, 'tbl_qr_list', {}).then(r => r.s === 200 && r.j.tables.every(t => t.code === null) && r.j.tables.some(t => t.has_code) && r.j.can.issue === false));
  ok('replace without the table name: 422 confirm', await rpc(A, 'tbl_qr_issue', { table_id: tA1, replace: true }).then(r => r.s === 422 && r.j.code === 'confirm'));
  const issB = await rpc(B, 'tbl_qr_issue', { table_id: tB1 });

  // ---- guest door
  ok('guest: a made-up code is 404', (await guest('open', { code: 'f'.repeat(64) })).s === 404);
  ok('guest: a table id instead of a code is refused (400)', (await guest('open', { code, table_id: tB1 })).s === 400);
  const open = await guest('open', { code });
  const ses = open.j?.session;
  ok("guest open: A's G1, the published brand, only the visible dish", open.s === 200 && open.j.table.label === 'G1' && open.j.menu.brand.name === 'ZZ Idli House'
    && open.j.menu.items.length === 1 && open.j.menu.items[0].id === dish, open);
  ok('the public key cannot call the guest door around the gateway', await fetch(`${U}/rest/v1/rpc/guest_qr_open`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p: { code } }) }).then(r => r.status >= 400));
  ok('a signed-in staff token cannot call it either', await fetch(`${U}/rest/v1/rpc/guest_order_status`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${A}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p: { session: ses } }) }).then(r => r.status >= 400));
  ok("guest: B's dish or a hidden dish cannot be ordered at A's table",
    (await guest('send', { session: ses, idempotency_key: `e2e-${randomUUID()}`, lines: [{ menu_item_id: dishB, qty: 1 }] })).s === 409
    && (await guest('send', { session: ses, idempotency_key: `e2e-${randomUUID()}`, lines: [{ menu_item_id: hidden, qty: 1 }] })).s === 409);
  ok('guest: a price or a table in the body is refused', (await guest('send', { session: ses, idempotency_key: `e2e-${randomUUID()}`, lines: [{ menu_item_id: dish, qty: 1, unit_price: 1 }] })).s === 400
    && (await guest('send', { session: ses, idempotency_key: `e2e-${randomUUID()}`, table_id: tA2, lines: [{ menu_item_id: dish, qty: 1 }] })).s === 400);
  const key1 = `e2e-${randomUUID()}`;
  const sent = await guest('send', { session: ses, idempotency_key: key1, guest_name: 'Ravi', lines: [{ menu_item_id: dish, qty: 3 }] });
  ok('guest send: waiting, estimate 3 x 80', sent.s === 200 && sent.j.status === 'waiting' && Number(sent.j.estimated_total) === 240, sent);
  const again = await guest('send', { session: ses, idempotency_key: key1, guest_name: 'Ravi', lines: [{ menu_item_id: dish, qty: 3 }] });
  ok('guest send again (same tap): same request', again.s === 200 && again.j.id === sent.j.id && again.j.replayed === true);
  ok('guest: a made-up session says session_expired', await guest('status', { session: '0'.repeat(64) }).then(r => r.s === 409 && r.j.code === 'session_expired'));

  // ---- staff decide
  ok('B sees no guest orders of A and cannot accept one', await rpc(B, 'guest_requests_list', {}).then(r => r.s === 200 && r.j.waiting === 0)
    && (await rpc(B, 'guest_request_decide', { id: sent.j.id, action: 'accept' })).s === 404);
  ok('viewer cannot accept', (await rpc(V, 'guest_request_decide', { location_id: locA, id: sent.j.id, action: 'accept' })).s === 403);
  const wl = await rpc(W, 'guest_requests_list', { location_id: locA });
  ok('waiter sees one waiting guest order at G1', wl.s === 200 && wl.j.waiting === 1 && wl.j.requests[0].table.label === 'G1' && wl.j.requests[0].guest_name === 'Ravi', wl);
  const acc = await rpc(W, 'guest_request_decide', { location_id: locA, id: sent.j.id, action: 'accept' });
  ok('waiter accepts: an order is placed', acc.s === 200 && acc.j.status === 'accepted' && !!acc.j.order_id, acc);
  const row = sql(`select channel||'|'||placed_by||'|'||status||'|'||(table_id='${tA1}')||'|'||(select count(*) from kot_tickets k where k.order_id=o.id) from orders o where id='${acc.j.order_id}'`);
  ok('the order: dine-in, placed by guest, in the kitchen with a KOT, at G1', row === 'dine_in|guest|sent_to_kitchen|true|1', row);
  const tv = await rpc(W, 'tbl_order_view', { location_id: locA, table_id: tA1 });
  ok('the table order screen shows it like any other order', tv.s === 200 && tv.j.orders.length === 1 && tv.j.items.some(i => i.name === 'ZZ Idli'), tv);
  const st = await guest('status', { session: ses });
  ok('guest status: accepted with the order number and "Being prepared"', st.s === 200 && st.j.requests[0].status === 'accepted' && st.j.requests[0].order.status_label === 'Being prepared' && /^P-/.test(st.j.requests[0].order.display_no), st);
  ok('guest status never names the staff member', !JSON.stringify(st.j).includes('decided_by') && !JSON.stringify(st.j).includes(users[1]));

  // ---- abuse: three waiting per table
  const sends = [];
  for (let i = 0; i < 4; i++) sends.push((await guest('send', { session: ses, idempotency_key: `e2e-${randomUUID()}`, lines: [{ menu_item_id: dish, qty: 1 }] })).s);
  ok('limit: the fourth waiting order at one table is 429', sends.join(',') === '200,200,200,429', sends);
  const dec = await rpc(A, 'guest_request_decide', { location_id: locA, id: (await rpc(A, 'guest_requests_list', { location_id: locA })).j.requests[0].id, action: 'decline', reason: 'Sent twice' });
  ok('decline with a reason', dec.s === 200 && dec.j.status === 'declined');

  // ---- replace the code
  const rep = await rpc(A, 'tbl_qr_issue', { location_id: locA, table_id: tA1, replace: true, confirm_label: 'g1' });
  ok('replace by name: a new code, the open session ended', rep.s === 200 && rep.j.code !== code && rep.j.guest_sessions_ended >= 1, rep);
  ok('old session: session_expired; old code: 404; new code opens', await guest('menu', { session: ses }).then(r => r.s === 409 && r.j.code === 'session_expired')
    && (await guest('open', { code })).s === 404 && (await guest('open', { code: rep.j.code })).s === 200);
  ok('switch off: the code opens nothing', (await rpc(A, 'tbl_qr_set_enabled', { location_id: locA, table_id: tA1, enabled: false })).s === 200 && (await guest('open', { code: rep.j.code })).s === 404);
  ok("B's code: no published-menu problem, B's own table only", await guest('open', { code: issB.j.code }).then(r => r.s === 200 && r.j.table.label === 'B1' && r.j.menu.items.every(i => i.id === dishB)));

  // ---- Hand to guest
  const hm = await rpc(W, 'guest_staff_menu', { location_id: locA, table_id: tA2 });
  ok('hand to guest: the same published menu for G2', hm.s === 200 && hm.j.menu.items.length === 1 && hm.j.table.label === 'G2', hm);
  const hk = `e2e-${randomUUID()}`;
  const hp = await rpc(W, 'guest_staff_place', { location_id: locA, table_id: tA2, lines: [{ menu_item_id: dish, qty: 2 }] }, hk);
  ok('hand to guest: placed by guest, in the kitchen', hp.s === 200 && hp.j.order.placed_by === 'guest' && hp.j.order.status === 'sent_to_kitchen', hp);
  ok('hand to guest: the same tap again gives the same order', await rpc(W, 'guest_staff_place', { location_id: locA, table_id: tA2, lines: [{ menu_item_id: dish, qty: 2 }] }, hk).then(r => r.j?.order?.id === hp.j.order.id));
  ok("hand to guest: B cannot use A's table", (await rpc(B, 'guest_staff_menu', { table_id: tA2 })).s === 404);

  // ---- per-address limit at the gateway (bad codes: nothing reaches the database)
  const burst = [];
  for (let i = 0; i < 32; i++) burst.push((await guest('open', { code: 'zz' })).s);
  ok('per-address limit: 30 opens a minute, then 429', burst.includes(429) && burst.slice(0, burst.indexOf(429)).every(s => s === 400) && burst.slice(burst.indexOf(429)).every(s => s === 429), burst.join(','));
} finally {
  sql(`delete from guest_order_requests where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from guest_qr_sessions where organization_id in ('${orgA}','${orgB}')`);
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  sql(`update orders set notes='ZZ-TEST e2e' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch { /* table may not exist on an older schema */ }
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge script failed (known, unrelated svc rows):', String(e.message).slice(0, 120)); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
