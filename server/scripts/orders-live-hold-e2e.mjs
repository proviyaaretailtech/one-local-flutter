// E2E: the Orders tab (Live orders, Hold orders, Resume POS; migrations 0530-0531, specs/orders-live-hold) over HTTP against the standalone POS
// server, as real signed-in staff of two different businesses. LOCAL ONLY. Proves: Save & Hold with a reason, the hold list, Resume POS rewrites
// the lines on the SAME order (idempotent under a burst of retries), paying it keeps the order id, org B can neither see, resume, pay nor count
// org A's holds, a viewer cannot resume, Zomato reads OFFLINE. Tags its orders 'ZZ-TEST' and purges them, its users and businesses at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/orders-live-hold-e2e.mjs   (POS_API overrides the address; keys from ./.env, never printed)
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const envFile = process.env.OL_ENV ?? '.env';
const env = Object.fromEntries(readFileSync(envFile, 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 400)); } };

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID();
const users = [];
async function staff(org, role, tag) {
  const email = `zz-pos-olh-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function api(token, method, path, body, key) {
  const headers = { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) };
  const r = await fetch(`${API}/api/partner/pos-orders${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;
async function rpc(token, fn, body, key) {
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) };
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(body ?? {}) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ OLH A ${run}','zz-olh-a-${run}','franchise'),('${orgB}','Golden ZZ OLH B ${run}','zz-olh-b-${run}','franchise')`);
  sql(`insert into menu_items(organization_id,name,price) values ('${orgA}','Garlic Bread',120),('${orgA}','Coke',60),('${orgA}','Paneer Butter Masala',260),('${orgB}','B only item',100)`);
  const A = await staff(orgA, 'manager', 'mgr-a'), B = await staff(orgB, 'org_owner', 'owner-b'), V = await staff(orgA, 'viewer', 'viewer-a');
  ok('three staff signed in', !!A && !!B && !!V);
  const items = Object.fromEntries((await api(A, 'GET', '/catalog')).j.items.map(i => [i.name, i.id]));
  const bread = items['Garlic Bread'], coke = items['Coke'], paneer = items['Paneer Butter Masala'];
  ok('catalog: three items of A', !!bread && !!coke && !!paneer);

  // Save & Hold with a reason (existing route, now pos_hold_place)
  const h1 = await api(A, 'POST', '/hold', { lines: [{ menu_item_id: bread, qty: 1 }, { menu_item_id: coke, qty: 1 }], reason: 'Customer waiting for group head', notes: 'ZZ-TEST e2e' }, k());
  ok('hold: unpaid held bill', h1.s === 200 && h1.j.stage === 'checkout', h1.j);
  ok('hold: one hold row with the reason', sql(`select reason from pos_order_holds where order_id='${h1.j.id}'`) === 'Customer waiting for group head');
  const listA = await rpc(A, 'pos_hold_list', {});
  ok('hold list: the bill, its reason, items, not delayed', listA.s === 200 && listA.j.count === 1 && listA.j.holds[0].order_id === h1.j.id
     && listA.j.holds[0].reason === 'Customer waiting for group head' && listA.j.holds[0].items === '1× Coke, 1× Garlic Bread' && listA.j.holds[0].delayed === false, listA.j);
  const version = listA.j.holds[0].version;
  const boardA0 = await rpc(A, 'pos_orders_board', {});
  ok('board: a held bill is not a live order', boardA0.s === 200 && boardA0.j.counts.new === 0, boardA0.j?.counts);
  ok('board: Zomato and Swiggy OFFLINE / not connected', boardA0.j.integrations.every(i => i.state === 'offline' && i.reason === 'not_connected'), boardA0.j.integrations);
  ok('board: bad channel 400 at the gateway', (await rpc(A, 'pos_orders_board', { channel: 'ondc' })).s === 400);

  // tenancy and roles
  const listB = await rpc(B, 'pos_hold_list', {});
  ok('org B: no holds of A', listB.s === 200 && listB.j.count === 0, listB.j);
  ok('org B: A\'s order is not on B\'s board', (await rpc(B, 'pos_orders_board', {})).j.counts.new === 0);
  const bUpd = await rpc(B, 'pos_hold_update', { order_id: h1.j.id, expected_updated_at: version, lines: [{ menu_item_id: coke, qty: 5 }] }, k());
  ok('org B cannot resume A\'s hold (404)', bUpd.s === 404, bUpd);
  ok('org B cannot pay A\'s hold (404)', (await api(B, 'POST', `/${h1.j.id}/pay`, { method: 'upi', version }, k())).s === 404);
  ok('org B cannot cancel A\'s hold (404)', (await api(B, 'POST', `/${h1.j.id}/cancel`, { reason: 'not mine', version })).s === 404);
  ok('org B cannot read A\'s hold (404)', (await api(B, 'GET', `/${h1.j.id}`)).s === 404);
  const vUpd = await rpc(V, 'pos_hold_update', { order_id: h1.j.id, expected_updated_at: version, lines: [{ menu_item_id: coke, qty: 5 }] }, k());
  ok('a viewer cannot resume (403)', vUpd.s === 403, vUpd);
  ok('A\'s bill untouched by B and the viewer', sql(`select sum(qty) from order_items where order_id='${h1.j.id}'`) === '2');

  // Resume POS: five taps with one key at the same moment change the bill once, on the same order
  const rk = k();
  const lines2 = [{ menu_item_id: bread, qty: 1 }, { menu_item_id: coke, qty: 2 }, { menu_item_id: paneer, qty: 1 }];
  const burst = await Promise.all([1, 2, 3, 4, 5].map(() => rpc(A, 'pos_hold_update', { order_id: h1.j.id, expected_updated_at: version, lines: lines2 }, rk)));
  ok('resume x5 same key: every answer is the same order', burst.every(r => r.s === 200 && r.j.order_id === h1.j.id), burst.map(r => [r.s, r.j?.code]));
  ok('resume x5: changed once (one event), four replays', sql(`select count(*) from order_events where order_id='${h1.j.id}' and kind='hold_updated'`) === '1'
     && burst.filter(r => r.j.replayed).length === 4, burst.map(r => r.j?.replayed));
  ok('resume: lines rewritten on the same order', sql(`select sum(qty) from order_items where order_id='${h1.j.id}'`) === '4');
  const quote = await api(A, 'POST', '/quote', { lines: lines2 });
  ok('resume: the bill total is the quote of the new lines', Number(sql(`select total from orders where id='${h1.j.id}'`)) === Number(quote.j.total), [quote.j?.total]);
  const stale = await rpc(A, 'pos_hold_update', { order_id: h1.j.id, expected_updated_at: version, lines: [{ menu_item_id: coke, qty: 1 }] }, k());
  ok('resume with the old version and a new key: 409 version_conflict', stale.s === 409 && stale.j.code === 'version_conflict', stale.j);
  const newVersion = burst[0].j.updated_at;

  // pay the resumed bill: the same order, still one order in the business
  const pk = k();
  const pays = await Promise.all([1, 2, 3].map(() => api(A, 'POST', `/${h1.j.id}/pay`, { method: 'upi', reference: 'UPI-ZZ', version: newVersion }, pk)));
  ok('pay x3 same key: the same order, paid once', pays.every(r => r.s === 200 || r.s === 409) && pays.some(r => r.s === 200 && r.j.id === h1.j.id)
     && sql(`select count(*) from payments where order_id='${h1.j.id}'`) === '1', pays.map(r => [r.s, r.j?.code]));
  ok('pay: one order in A, now paid, total = quote', sql(`select count(*) from orders where organization_id='${orgA}'`) === '1'
     && sql(`select status from orders where id='${h1.j.id}'`) === 'paid' && Number(sql(`select sum(amount) from payments where order_id='${h1.j.id}'`)) === Number(quote.j.total));
  ok('pay: the bill leaves the hold list', (await rpc(A, 'pos_hold_list', {})).j.count === 0);
  const boardA1 = await rpc(A, 'pos_orders_board', { channel: 'takeaway', status: 'new' });
  ok('board: the paid bill is New on Takeaway, with its items', boardA1.j.counts.new === 1 && boardA1.j.orders[0].order_id === h1.j.id
     && boardA1.j.orders[0].items === '2× Coke, 1× Garlic Bread, 1× Paneer Butter Masala', boardA1.j.orders);
  ok('a paid bill cannot be resumed (409)', (await rpc(A, 'pos_hold_update', { order_id: h1.j.id, expected_updated_at: newVersion }, k())).s === 409);

  // a second hold, cancelled with a reason
  const h2 = await api(A, 'POST', '/hold', { lines: [{ menu_item_id: paneer, qty: 2 }], reason: 'UPI pending', notes: 'ZZ-TEST e2e' }, k());
  const l2 = await rpc(A, 'pos_hold_list', {});
  ok('second hold listed', l2.j.count === 1 && l2.j.holds[0].reason === 'UPI pending', l2.j);
  ok('cancel needs a reason (400)', (await api(A, 'POST', `/${h2.j.id}/cancel`, { reason: 'x', version: l2.j.holds[0].version })).s === 400);
  const c2 = await api(A, 'POST', `/${h2.j.id}/cancel`, { reason: 'Customer left', version: l2.j.holds[0].version });
  ok('cancelled: leaves the hold list, no payment', c2.s === 200 && c2.j.stage === 'cancelled' && (await rpc(A, 'pos_hold_list', {})).j.count === 0, c2.j?.stage);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  sql(`update orders set notes='ZZ-TEST e2e' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch { /* table may not exist on an older schema */ }  // created with each business; blocks the purge
  // scoped to this run's two businesses (the shared purge script can trip on other suites' leftovers)
  console.log(execSync(`docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt`, {
    encoding: 'utf8', input: `set purge.orgs = '${orgA},${orgB}';\n` + readFileSync(new URL('./purge-orgs.sql', import.meta.url), 'utf8'),
  }).trim().split('\n').pop());
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
