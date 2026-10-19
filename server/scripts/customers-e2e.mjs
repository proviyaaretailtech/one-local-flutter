// E2E + cross-tenant test of Customers (S5.5), the One Local Wallet and Manage account through POST /rpc/<name>. LOCAL ONLY.
// Business A (owner, biller, viewer) adds a customer at the counter, attaches it to a real counter bill, reads its wallet and account.
// Business B (a real signed-in owner) then tries every new function against A's ids: it must get nothing or an error, and A's rows must
// be unchanged. Tags its orders 'ZZ-TEST' and purges them.
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8097 OL_ENV=<local .env> node scripts/customers-e2e.mjs
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
async function person(tag, org, role) {
  const email = `zz-cwa-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, args = {}) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const refused = r => r.s >= 400 && r.s < 500;
const phone = `9${String(Date.now()).slice(-9)}`;

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','ZZ CWA A ${run}','zz-cwa-a-${run}','franchise'),('${orgB}','ZZ CWA B ${run}','zz-cwa-b-${run}','franchise')`);
  const locA = sql(`select id from locations where organization_id='${orgA}' order by created_at limit 1`);
  const A = await person('owner-a', orgA, 'org_owner'), BL = await person('biller-a', orgA, 'biller'), V = await person('viewer-a', orgA, 'viewer'), B = await person('owner-b', orgB, 'org_owner');
  ok('signed in', !!A && !!BL && !!V && !!B);
  // a counter bill of A, paid (written as the database would after pos_checkout)
  const orderA = randomUUID();
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,subtotal,total,paid_at,notes) values ('${orderA}',(select coalesce(max(order_no),0)+1 from orders),'ZZ-CWA-${run}','${orgA}','${locA}','pickup','paid',250,250,now(),'ZZ-TEST cwa')`);

  // ---- customers (S5.5)
  const add = await rpc(BL, 'cust_save', { first_name: 'ZZ Asha', phone: `+91 ${phone}` });
  ok('biller adds a new customer at the counter', add.s === 200 && add.j.created === true, add);
  const cid = add.j?.customer_id;
  ok('the biller sees the phone masked', add.j?.customer?.phone === '••••••' + phone.slice(-4), add.j?.customer);
  ok('same phone again answers with the existing customer', (await rpc(BL, 'cust_save', { first_name: 'Dup', phone })).j?.customer_id === cid);
  ok('bad phone: 400', (await rpc(BL, 'cust_save', { first_name: 'X', phone: '0000000000' })).s === 400);
  ok('biller cannot edit a customer: 403', (await rpc(BL, 'cust_save', { id: cid, first_name: 'Y', phone })).s === 403);
  ok('viewer has no customer tools: 403', (await rpc(V, 'cust_list', {})).s === 403);
  const att = await rpc(BL, 'cust_attach_order', { order_id: orderA, customer_id: cid });
  ok('S5.5 attach the customer to the bill', att.s === 200 && att.j.customer_id === cid, att);
  ok('the bill carries the customer', sql(`select pos_customer_id||':'||customer_name from orders where id='${orderA}'`) === `${cid}:ZZ Asha`);
  ok('gateway refuses customer AND walk-in: 400', (await rpc(BL, 'cust_attach_order', { order_id: orderA, customer_id: cid, walk_in: true })).s === 400);
  const view = await rpc(A, 'cust_view', { id: cid });
  ok('owner sees full phone, one visit, spend 250', view.s === 200 && view.j.phone === phone && view.j.visits === 1 && Number(view.j.spent) === 250, view);
  ok('list and lookup find it', (await rpc(BL, 'cust_list', { q: phone.slice(-4) })).j?.items?.length === 1 && (await rpc(BL, 'cust_lookup', { phone })).j?.found === true);

  // ---- wallet and account
  const w = await rpc(A, 'wallet_overview', {});
  ok('owner opens the wallet (empty business: all zero)', w.s === 200 && Number(w.j.on_the_way.amount) === 0 && w.j.movements.total === 0, w);
  ok('a biller cannot open the wallet: 403', (await rpc(BL, 'wallet_overview', {})).s === 403);
  const acc = await rpc(BL, 'acct_get', {});
  ok('account: own email, password sign-in on, this device listed', acc.s === 200 && acc.j.email.startsWith('zz-cwa-biller-a') && acc.j.sign_in_methods.some(m => m.method === 'password' && m.enabled) && acc.j.devices.length >= 1, acc);
  ok('rename self', (await rpc(BL, 'acct_save_name', { name: 'ZZ Biller Renamed' })).j?.memberships_updated === 1);

  // ---- business B against A's ids
  const x = (fn, args) => rpc(B, fn, args);
  ok('B: lists none of A customers, lookup finds nothing', (await x('cust_list', {})).j?.items?.length === 0 && (await x('cust_lookup', { phone })).j?.found === false);
  ok('B: cannot view A customer', (await x('cust_view', { id: cid })).s === 404);
  ok('B: cannot edit A customer', refused(await x('cust_save', { id: cid, first_name: 'Hacked', phone })));
  ok('B: cannot attach to or clear A bill', (await x('cust_attach_order', { order_id: orderA, walk_in: true })).s === 404);
  const bw = await x('wallet_overview', {});
  ok('B: own wallet only, nothing of A', bw.s === 200 && !JSON.stringify(bw.j).includes(orgA));
  const ba = await x('acct_get', {});
  ok('B: account shows only B', ba.s === 200 && ba.j.email.startsWith('zz-cwa-owner-b') && !JSON.stringify(ba.j).includes('biller-a'));
  ok('A rows untouched after all of that', sql(`select first_name from pos_customers where id='${cid}'`) === 'ZZ Asha'
    && sql(`select pos_customer_id from orders where id='${orderA}'`) === cid
    && sql(`select full_name from org_users where organization_id='${orgA}' and email like 'zz-cwa-biller-a%'`) === 'ZZ Biller Renamed');
  ok('anonymous: 401', (await fetch(`${API}/rpc/cust_list`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).status === 401);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST cwa' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('test businesses kept (customers and orders are records): ZZ CWA A/B ' + run);
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
