// E2E: a takeaway or delivery order held on the floor can be found under Orders and sent to the kitchen (database 0643), over HTTP against
// the standalone POS server's generic gateway (POST /rpc/<function>), as real signed-in staff of a restaurant, a store and another business.
// LOCAL ONLY. Leaves its ZZ businesses on the local database.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-hold-send-e2e.mjs   (POS_API, OL_DB, OL_ENV as rst-cancel-refund-e2e)
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
const orgA = randomUUID(), orgS = randomUUID(), orgB = randomUUID();
async function staff(org, role, tag) {
  const email = `zz-hold-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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
const k = () => `e2e-${randomUUID()}`;
const board = async (who, status = 'new') => (await rpc(who, 'pos_orders_board', { status })).j;

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','Golden ZZ HOLD A ${run}','zz-hold-a-${run}','franchise','Restaurant'),
       ('${orgS}','Golden ZZ HOLD S ${run}','zz-hold-s-${run}','franchise','Retail'),('${orgB}','Golden ZZ HOLD B ${run}','zz-hold-b-${run}','franchise','Restaurant')`);
  const dosa = randomUUID(), tea = randomUUID();
  sql(`insert into menu_items(id,organization_id,name,price) values ('${dosa}','${orgA}','Masala Dosa',120),('${tea}','${orgA}','Masala Chai',30)`);
  const CAP = await staff(orgA, 'captain', 'cap'), MGR = await staff(orgA, 'manager', 'mgr'), VIEW = await staff(orgA, 'viewer', 'view'),
    KIT = await staff(orgA, 'kitchen', 'kit'), B = await staff(orgB, 'org_owner', 'own-b'), SO = await staff(orgS, 'org_owner', 'own-s');
  ok('six staff signed in', [CAP, MGR, VIEW, KIT, B, SO].every(x => x.token));
  const lines = [{ menu_item_id: dosa, qty: 2 }, { menu_item_id: tea, qty: 1 }];

  // ---- Hold a takeaway and a delivery on the floor
  let r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines, send: false, idempotency_key: k() });
  ok('captain holds a takeaway: saved, not sent', r.s === 200 && r.j.held === true && r.j.order.status === 'in_billing' && !r.j.kot, r);
  const ta = r.j.order_id, taNo = r.j.order.display_no;
  ok('…it has a hold row now', sql(`select count(*) from pos_order_holds where order_id='${ta}'`) === '1');
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'delivery', lines, send: false, customer_name: 'Ravi', customer_phone: '9876543210', address: '12 MG Road', idempotency_key: k() });
  ok('captain holds a delivery', r.s === 200 && r.j.held === true, r);
  const dl = r.j.order_id;

  // ---- they show under Orders → Live → New, marked held
  let bd = await board(MGR);
  const t1 = bd?.orders?.find(o => o.order_id === ta), d1 = bd?.orders?.find(o => o.order_id === dl);
  ok('Orders → New shows the held takeaway, marked held', t1?.held === true && t1.channel === 'takeaway' && t1.display_no === taNo, bd?.orders);
  ok('Orders → New shows the held delivery, marked held', d1?.held === true && d1.channel === 'delivery', d1);
  ok('…counted under New', bd?.counts?.new >= 2, bd?.counts);
  r = await rpc(CAP, 'pos_hold_list', {});
  ok('…and on the Hold list', r.s === 200 && r.j.holds.some(h => h.order_id === ta) && r.j.holds.some(h => h.order_id === dl), r.j);
  r = await rpc(MGR, 'rst_channel_orders', {});
  if (process.env.FIXTURES) writeFileSync(process.env.FIXTURES, JSON.stringify({ channel_orders: r.j }, null, 1));
  const cto = r.j?.orders?.find(o => o.id === ta), cdl = r.j?.orders?.find(o => o.id === dl);
  ok('restaurant Orders: a Takeaway card with the held takeaway, marked held', r.s === 200 && r.j.channels.some(c => c.key === 'takeaway' && c.label === 'Takeaway' && c.new >= 1) && cto?.source === 'takeaway' && cto.held === true && cto.stage === 'new', r.j?.channels);
  ok('restaurant Orders: the held delivery under On call delivery, marked held', cdl?.source === 'on_call' && cdl.held === true, cdl);

  // ---- send to the kitchen
  const key = k();
  r = await rpc(CAP, 'rst_hold_send', { order_id: ta }, key);
  ok('captain sends the held takeaway to the kitchen: a KOT with 2 dishes', r.s === 200 && r.j.kot?.kot_no && r.j.kot.dishes === 2 && r.j.status === 'sent_to_kitchen', r);
  ok('…the order is with the kitchen', sql(`select status from orders where id='${ta}'`) === 'sent_to_kitchen');
  ok('…the hold is marked resumed', sql(`select resumed_at is not null from pos_order_holds where order_id='${ta}'`) === 't');
  r = await rpc(CAP, 'rst_hold_send', { order_id: ta }, key);
  ok('…the same tap again replays, no second KOT', r.s === 200 && r.j.replayed === true && sql(`select count(*) from kot_tickets where order_id='${ta}'`) === '1', r);
  r = await rpc(CAP, 'rst_hold_send', { order_id: ta }, k());
  ok('…sending again is refused', r.s === 409, r);
  bd = await board(MGR, 'preparing');
  ok('…it moved to Orders → Preparing, no longer held', bd?.orders?.some(o => o.order_id === ta && !o.held), bd?.orders);
  ok('…and left the Hold list', !(await rpc(CAP, 'pos_hold_list', {})).j.holds.some(h => h.order_id === ta));
  r = await rpc(MGR, 'rst_channel_orders', {});
  ok('restaurant Orders: the takeaway is Preparing, no longer held', r.j?.orders?.some(o => o.id === ta && o.stage === 'preparing' && o.held === false), r.j?.orders);
  r = await rpc(MGR, 'kds_queue', {});
  ok('…the kitchen display has its ticket', JSON.stringify(r.j ?? {}).includes('Masala Dosa'), r.s);

  // ---- roles and another business
  ok('a viewer cannot send it', (await rpc(VIEW, 'rst_hold_send', { order_id: dl }, k())).s === 403);
  ok('another business gets 404', (await rpc(B, 'rst_hold_send', { order_id: dl }, k())).s === 404);
  ok('a bad id is 400', (await rpc(CAP, 'rst_hold_send', { order_id: 'nope' }, k())).s === 400);
  r = await rpc(KIT, 'rst_hold_send', { order_id: dl }, k());
  ok('the kitchen can send it too (order status rights)', r.s === 200 && r.j.kot?.kot_no, r);

  // ---- an order held before this fix (no hold row) still shows and can be sent
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines: [{ menu_item_id: tea, qty: 3 }], send: false, idempotency_key: k() });
  const old = r.j.order_id;
  sql(`delete from pos_order_holds where order_id='${old}'`);
  bd = await board(MGR);
  ok('an old held order with no hold row still shows under New, held', bd?.orders?.some(o => o.order_id === old && o.held), bd?.orders);
  ok('…and can be sent', (await rpc(MGR, 'rst_hold_send', { order_id: old }, k())).s === 200);

  // ---- a cancelled one cannot be sent
  r = await rpc(CAP, 'pos_counter_order', { service_type: 'pickup', lines: [{ menu_item_id: dosa, qty: 1 }], send: false, idempotency_key: k() });
  const gone = r.j.order_id;
  ok('…cancelled through the normal cancel', (await rpc(MGR, 'pos_set_order_status', { order_id: gone, to: 'cancelled', reason: 'Guest left' })).s === 200);
  ok('a cancelled held order cannot be sent', (await rpc(CAP, 'rst_hold_send', { order_id: gone }, k())).s === 409);

  // ---- a store's unpaid counter draft is still not a live order
  const sd = randomUUID(), sloc = sql(`select id from locations where organization_id='${orgS}' limit 1`);
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,subtotal,gst_pct,gst_amount,total,notes) values ('${sd}',9401,'S9401','${orgS}','${sloc}','pickup','in_billing',100,5,5,105,'ZZ-TEST')`);
  sql(`insert into order_items(order_id,name,qty,unit_price) values ('${sd}','Soap',1,100)`);
  bd = await board(SO);
  ok('a store\'s unpaid counter draft stays off the Orders board', bd && !bd.orders.some(o => o.order_id === sd), bd);
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
