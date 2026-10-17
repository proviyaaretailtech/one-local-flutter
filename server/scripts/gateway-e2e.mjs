// E2E + cross-tenant test of the generic endpoint POST /rpc/<name>. LOCAL ONLY. Two businesses (A, B) with real signed-in staff, and two
// applicants with no business. Business A's data is read and changed with business B's token by every read and write function in the
// manifest that takes an id, and must give nothing or an error. Tags its orders 'ZZ-TEST' and purges them.
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8091 node scripts/gateway-e2e.mjs
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
  const email = `zz-gw-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  if (org) sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, args = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(args) });
  const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const refused = r => r.s >= 400 && r.s < 500;

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ GW A ${run}','zz-gw-a-${run}','franchise'),('${orgB}','Golden ZZ GW B ${run}','zz-gw-b-${run}','franchise')`);
  sql(`insert into org_bill_settings(organization_id,service_charge_pct) values ('${orgA}',10)`);
  sql(`insert into menu_items(organization_id,name,price) values ('${orgA}','A item one',100),('${orgA}','A item two',50),('${orgB}','B item',70)`);
  const A = await person('mgr-a', orgA, 'manager'), B = await person('owner-b', orgB, 'org_owner'), V = await person('viewer-a', orgA, 'viewer');
  const P1 = await person('applicant1'), P2 = await person('applicant2');
  ok('signed in', !!A && !!B && !!V && !!P1 && !!P2);

  // ---- the door
  ok('no token: 401', (await rpc(null, 'pos_order_history')).s === 401);
  ok('garbage token: 401', (await rpc('x'.repeat(40), 'pos_order_history')).s === 401);
  ok('unknown name: 404 (also without a token)', (await rpc(null, 'nope')).s === 404 && (await rpc(A, 'nope')).s === 404);
  for (const bad of ['orders', 'ol_partner_act', 'partner_app_get_raw', 'pos_place_order', 'exec_sql', 'partner_app_save_tax_x', 'gw_partner_app_get', 'pg_sleep', '..%2Fhealth'])
    ok(`not on the allowlist: ${bad} is 404`, (await rpc(A, bad)).s === 404, bad);
  ok('GET /rpc/x is 405', (await fetch(`${API}/rpc/pos_order_history`, { headers: { Authorization: `Bearer ${A}` } })).status === 405);
  ok('table path is not a route', (await fetch(`${API}/rest/v1/orders`, { headers: { Authorization: `Bearer ${A}` } })).status === 404);
  const me = await rpc(A, 'me');
  ok('me: staff of A', me.s === 200 && me.j.restaurant.id === orgA && me.j.person.role === 'manager', me);
  ok('me: applicant is not staff (403)', (await rpc(P1, 'me')).s === 403);

  // ---- counter bill as A
  const items = sql(`select id||'|'||price from menu_items where organization_id='${orgA}' order by price desc`).split('\n').map(l => l.split('|'));
  const bItem = sql(`select id from menu_items where organization_id='${orgB}'`);
  const lines = items.map(([id]) => ({ menu_item_id: id, qty: 1 }));
  const q = await rpc(A, 'pos_quote_order', { lines });
  ok('A quotes its own items (150 + 10% service + 5% GST)', q.s === 200 && Number(q.j.subtotal) === 150, q);
  const key = `gw-${randomUUID()}`;
  const co = await rpc(A, 'pos_checkout', { lines, method: 'cash', tendered: 500, hold: false, notes: 'ZZ-TEST gw' }, key);
  ok('A checks out through the gateway (Idempotency-Key header becomes the key)', co.s === 200 && co.j.order_id, co);
  const again = await rpc(A, 'pos_checkout', { lines, method: 'cash', tendered: 500, hold: false, notes: 'ZZ-TEST gw' }, key);
  ok('same key replays the same order', again.s === 200 && again.j.order_id === co.j.order_id && again.j.replayed === true, again);
  const oid = co.j.order_id;
  const view = await rpc(A, 'pos_order_view', { order_id: oid });
  ok('A views its order', view.s === 200 && view.j.order.id === oid, view.s);
  ok('A history lists it', (await rpc(A, 'pos_order_history', { filter: 'all' })).j?.some?.(o => o.id === oid));
  ok('error shape is {detail, code}: stale version', await (async () => { const r = await rpc(A, 'pos_set_order_status', { order_id: oid, to: 'cancelled', reason: 'zz', expected_updated_at: '2000-01-01T00:00:00Z' }); return refused(r) && typeof r.j.detail === 'string'; })());
  ok('a body that is not an object: 400', (await fetch(`${API}/rpc/pos_order_view`, { method: 'POST', headers: { Authorization: `Bearer ${A}`, 'Content-Type': 'application/json' }, body: '[1]' })).status === 400);

  // ---- cross-tenant: B (a real signed-in owner of another business) against A's ids
  const x = async (fn, args, key) => rpc(B, fn, args, key);
  const r1 = await x('pos_order_view', { order_id: oid });
  ok('B cannot view A order', r1.s === 404, r1);
  const r2 = await x('pos_order_history', { filter: 'all' });
  ok('B history does not contain A orders', r2.s === 200 && Array.isArray(r2.j) && !r2.j.some(o => o.id === oid), r2);
  const r3 = await x('pos_quote_order', { lines: [{ menu_item_id: items[0][0], qty: 1 }] });
  ok('B cannot quote A menu items', refused(r3), r3);
  const r4 = await x('pos_checkout', { lines: [{ menu_item_id: items[0][0], qty: 1 }], method: 'cash', tendered: 500, hold: false }, `gw-${randomUUID()}`);
  ok('B cannot sell A menu items', refused(r4), r4);
  const r5 = await x('pos_checkout_pay', { order_id: oid, method: 'cash', tendered: 500, expected_updated_at: view.j.order.updated_at }, `gw-${randomUUID()}`);
  ok('B cannot take payment on A order', r5.s === 404, r5);
  const r6 = await x('pos_set_order_status', { order_id: oid, to: 'cancelled', reason: 'zz-test', expected_updated_at: view.j.order.updated_at });
  ok('B cannot cancel A order', r6.s === 404, r6);
  const r7 = await x('pos_fulfilment_act', { order_id: oid, action: 'accept', expected_version: 1 }, `gw-${randomUUID()}`);
  ok('B cannot move A order through fulfilment', refused(r7), r7);
  const r8 = await x('pos_refund', { order_id: oid, amount: 10, kind: 'goodwill', reason: 'zz-test', method: 'cash' }, `gw-${randomUUID()}`);
  ok('B cannot refund A order', refused(r8), r8);
  const r9 = await x('online_order_act', { order_id: oid, action: 'accept' });
  ok('B cannot act on A order as online order', refused(r9), r9);
  ok('A order unchanged after all of that', sql(`select status from orders where id='${oid}'`) === 'paid' && sql(`select count(*) from pos_refunds where order_id='${oid}'`) === '0');
  const r10 = await rpc(B, 'pos_checkout', { lines: [{ menu_item_id: bItem, qty: 1 }], method: 'cash', tendered: 200, hold: false, notes: 'ZZ-TEST gw' }, `gw-${randomUUID()}`);
  ok('B sells its own item (control)', r10.s === 200, r10);
  ok('A cannot view B order', (await rpc(A, 'pos_order_view', { order_id: r10.j.order_id })).s === 404);
  // a viewer in A can read but not sell
  const rv = await rpc(V, 'pos_checkout', { lines, method: 'cash', tendered: 500, hold: false }, `gw-${randomUUID()}`);
  ok('viewer role in A cannot sell', rv.s === 403, rv);
  // a person with no business
  ok('applicant has no orders (refused)', refused(await rpc(P1, 'pos_order_history', { filter: 'all' })));
  ok('applicant cannot view A order', refused(await rpc(P1, 'pos_order_view', { order_id: oid })));

  // ---- onboarding: each person only their own application; ids in the body are ignored
  const tax = await rpc(P1, 'static_taxonomy');
  ok('taxonomy served by the gateway', tax.s === 200 && tax.j.states.length > 30 && tax.j.document_kinds.length === 3, tax.s);
  const g0 = await rpc(P1, 'partner_app_get');
  ok('applicant 1: no application yet', g0.s === 200 && g0.j.exists === false, g0);
  const prof = { partner_type: 'restaurant', business_name: `ZZ GW Cafe ${run}`, owner_name: 'Asha Rao', phone: '98765 43210', selling_mode: 'physical', category: 'Indian' };
  const bad = await rpc(P1, 'partner_app_save_profile', { ...prof, phone: '123' });
  ok('profile: friendly validation message, 400', bad.s === 400 && bad.j.code === 'validation' && /10-digit/.test(bad.j.detail), bad);
  const sp = await rpc(P1, 'partner_app_save_profile', { ...prof, p_user_id: sql(`select id from auth.users where email like 'zz-gw-applicant2-${run}%'`) });
  ok('profile saved (an injected user id is ignored)', sp.s === 200 && sp.j.exists === true, sp);
  ok('applicant 2 does not see applicant 1 application', (await rpc(P2, 'partner_app_get')).j.exists === false);
  ok('application belongs to applicant 1', sql(`select count(*) from ol_partner_applications where business_name='ZZ GW Cafe ${run}' and applicant_user_id=(select id from auth.users where email like 'zz-gw-applicant1-${run}%')`) === '1');
  const t = await rpc(P1, 'partner_app_save_tax', { pan: 'ABCDE1234F', gst_registered: false });
  ok('secure: PAN saved through the key-holding handler, masked in the answer', t.s === 200 && !JSON.stringify(t.j).includes('ABCDE1234F'), t.s);
  ok('secure: PAN is not stored in clear', sql(`select count(*) from ol_partner_applications a where a.business_name='ZZ GW Cafe ${run}' and a.pan_enc is not null and a.pan_masked is not null and a::text not like '%ABCDE1234F%'`) === '1');
  const slot = await rpc(P1, 'partner_app_document_slot', { kind: 'pan_copy', content_type: 'application/pdf', size: 1000, file_name: 'pan.pdf' });
  ok('secure: signed upload slot inside own application folder', slot.s === 200 && slot.j.upload_url && slot.j.path.includes('/pan_copy/'), slot.s);
  ok('secure: another person gets no slot (no application)', refused(await rpc(P2, 'partner_app_document_slot', { kind: 'pan_copy', content_type: 'application/pdf', size: 1000, file_name: 'pan.pdf' })));
  const att = await rpc(P2, 'partner_app_document_attach', { kind: 'pan_copy', content_type: 'application/pdf', size: 1000, file_name: 'x.pdf', path: slot.j.path });
  ok('secure: cannot attach a path from someone else application', refused(att), att);
  ok('setup: applicant with no approved business is refused', refused(await rpc(P1, 'partner_setup_get')));
  ok('setup: staff of a business that never applied is refused', refused(await rpc(A, 'partner_setup_get')));
  ok('batch: two calls, one refused', await (async () => {
    const r = await fetch(`${API}/rpc`, { method: 'POST', headers: { Authorization: `Bearer ${A}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ calls: [{ fn: 'pos_order_view', args: { order_id: oid } }, { fn: 'pos_order_view', args: { order_id: r10.j.order_id } }, { fn: 'orders', args: {} }] }) });
    const j = await r.json(); return r.status === 200 && j.results[0].ok && !j.results[1].ok && j.results[1].status === 404 && j.results[2].status === 404;
  })());
  // ---- store inventory (section H): the same gateway, A's stock against B's token
  const locA = sql(`select id from locations where organization_id='${orgA}' order by created_at limit 1`);
  const locB = sql(`select id from locations where organization_id='${orgB}' order by created_at limit 1`);
  const itemA = sql(`insert into inventory_items(organization_id,sku,name,unit) values ('${orgA}','ZZ-GW-${run}','ZZ GW Cola','unit') returning id`).split('\n')[0];
  sql(`insert into stock_movements(organization_id,location_id,inventory_item_id,kind,quantity,ref_type,ref_id) values ('${orgA}','${locA}','${itemA}','receipt',10,'manual','zz-gw-${run}')`);
  const mvA = sql(`select max(id) from stock_movements where organization_id='${orgA}'`);
  ok('inventory: no token is 401, service-only helpers are not on the allowlist', (await rpc(null, 'inv_dashboard')).s === 401 && (await rpc(A, 'inv_post_movement')).s === 404 && (await rpc(A, 'inv_item_stats')).s === 404);
  const iDash = await rpc(A, 'inv_dashboard');
  ok('inventory: A manager reads its dashboard', iDash.s === 200 && Number(iDash.j.counts.total) >= 1 && iDash.j.location.id === locA, iDash);
  const iList = await rpc(A, 'inv_stock_list', { filter: 'all', page_size: 50 });
  ok('inventory: A stock list shows its item with 10 on hand', iList.s === 200 && iList.j.items.some(i => i.id === itemA && Number(i.available) === 10), iList);
  const iDet = await rpc(A, 'inv_stock_detail', { item_id: itemA });
  ok('inventory: A reads the item detail', iDet.s === 200 && iDet.j.item?.id === itemA, iDet);
  ok('inventory: bad shape is a 400 with a sentence', await (async () => { const r = await rpc(A, 'inv_stock_detail', { item_id: 'nope' }); return r.s === 400 && r.j.code === 'validation'; })());
  const dkey = `gw-inv-${randomUUID()}`;
  const draft = { doc_type: 'receipt', supplier_name: 'ZZ Supplier', lines: [{ inventory_item_id: itemA, expected_qty: 5, qty: 5 }] };
  const d1 = await rpc(A, 'inv_document_save', draft, dkey);
  ok('inventory: A saves a receipt draft (Idempotency-Key becomes the key)', d1.s === 200 && d1.j.status === 'draft' && d1.j.doc_no?.startsWith('RCV-'), d1);
  const d2 = await rpc(A, 'inv_document_save', draft, dkey);
  ok('inventory: same key replays the same draft', d2.s === 200 && d2.j.id === d1.j.id && d2.j.replayed === true, d2);
  const docId = d1.j.id;
  ok('inventory: a stale version is a 409 version_conflict', await (async () => { const r = await rpc(A, 'inv_document_act', { id: docId, action: 'submit', version: 99 }, `gw-inv-${randomUUID()}`); return r.s === 409 && r.j.code === 'version_conflict'; })());
  // B (another business, real owner) against A's stock
  const bDash = await rpc(B, 'inv_dashboard');
  ok('inventory: B dashboard shows none of A', bDash.s === 200 && bDash.j.location.id === locB && Number(bDash.j.counts.total) === 0 && !JSON.stringify(bDash.j).includes(itemA), bDash);
  const bList = await rpc(B, 'inv_stock_list', { filter: 'all', page_size: 50 });
  ok('inventory: B stock list has none of A items', bList.s === 200 && !JSON.stringify(bList.j).includes(itemA) && Number(bList.j.total) === 0, bList);
  ok('inventory: B cannot read A item detail', (await rpc(B, 'inv_stock_detail', { item_id: itemA })).s === 404);
  ok('inventory: B cannot read A movement', (await rpc(B, 'inv_movement_detail', { id: Number(mvA) })).s === 404);
  ok('inventory: B cannot open A location (dashboard, list, options, movements, documents)', refused(await rpc(B, 'inv_dashboard', { location_id: locA })) && refused(await rpc(B, 'inv_stock_list', { location_id: locA }))
    && refused(await rpc(B, 'inv_options', { location_id: locA })) && refused(await rpc(B, 'inv_movement_list', { location_id: locA })) && refused(await rpc(B, 'inv_document_list', { location_id: locA, doc_type: 'receipt' })));
  ok('inventory: B own document list has none of A', !JSON.stringify((await rpc(B, 'inv_document_list', { doc_type: 'receipt' })).j).includes(docId));
  ok('inventory: B cannot view, change or act on A document', (await rpc(B, 'inv_document_view', { id: docId })).s === 404
    && refused(await rpc(B, 'inv_document_save', { id: docId, version: d1.j.version, note: 'zz' }))
    && (await rpc(B, 'inv_document_act', { id: docId, action: 'cancel', version: d1.j.version }, `gw-inv-${randomUUID()}`)).s === 404
    && (await rpc(B, 'inv_audit_to_adjustment', { id: docId }, `gw-inv-${randomUUID()}`)).s === 404);
  ok('inventory: B cannot put A item on its own document, nor forecast it', refused(await rpc(B, 'inv_document_save', { doc_type: 'receipt', lines: [{ inventory_item_id: itemA, qty: 1 }] }, `gw-inv-${randomUUID()}`))
    && refused(await rpc(B, 'inv_forecast', { item_id: itemA, days: 7 })));
  ok('inventory: A document untouched after all of that', sql(`select status||':'||version from inventory_documents where id='${docId}'`) === 'draft:' + d1.j.version && sql(`select count(*) from stock_movements where organization_id='${orgA}'`) === '1');
  ok('inventory: A viewer can read stock but not create documents', (await rpc(V, 'inv_dashboard')).s === 200 && (await rpc(V, 'inv_document_save', draft, `gw-inv-${randomUUID()}`)).s === 403);
  ok('inventory: applicant with no business gets nothing', refused(await rpc(P1, 'inv_dashboard')) && refused(await rpc(P1, 'inv_stock_detail', { item_id: itemA })));
  // ---- kitchen stations and display (section H, 0480-0481): A's kitchen against B's token
  ok('kitchen: no token is 401', (await rpc(null, 'kds_queue')).s === 401 && (await rpc(null, 'kitchen_config')).s === 401);
  const kcfg = await rpc(A, 'kitchen_config');
  ok('kitchen: A manager sees Main Kitchen and may configure', kcfg.s === 200 && kcfg.j.stations.some(s => s.key === 'main') && kcfg.j.can.configure === true, kcfg);
  const ksave = await rpc(A, 'kitchen_station_save', { name: `Tandoor ${run}` }, `gw-kit-${randomUUID()}`);
  ok('kitchen: A creates a station', ksave.s === 200 && ksave.j.name === `Tandoor ${run}`, ksave);
  const stA = ksave.j.id;
  const kupd = await rpc(A, 'kitchen_station_save', { id: stA, version: ksave.j.version, active: false }, `gw-kit-${randomUUID()}`);
  ok('kitchen: a partial update changes only what is sent and bumps the version; a stale version is a 409', kupd.s === 200 && kupd.j.name === `Tandoor ${run}` && kupd.j.active === false && kupd.j.version === ksave.j.version + 1
    && (await rpc(A, 'kitchen_station_save', { id: stA, version: ksave.j.version, name: 'Late' }, `gw-kit-${randomUUID()}`)).s === 409, kupd);
  ok('kitchen: bad shape is a 400 with a sentence', await (async () => { const r = await rpc(A, 'kitchen_station_save', { name: '   ' }); return r.s === 400 && r.j.code === 'validation'; })());
  ok('kitchen: viewer cannot see or change the setup', refused(await rpc(V, 'kitchen_config')) && refused(await rpc(V, 'kitchen_station_save', { name: 'Nope' })));
  const kotNo = sql(`select next_org_seq('${orgA}','kot')`);
  const tkA = sql(`insert into kot_tickets(organization_id,order_id,kot_no,station,status) values ('${orgA}','${oid}',${kotNo},'main','new') returning id`).split('\n')[0];
  sql(`update order_items set kot_ticket_id='${tkA}' where order_id='${oid}'`);
  const kq = await rpc(A, 'kds_queue');
  ok('kitchen: A sees its ticket in the queue', kq.s === 200 && kq.j.tickets.some(t => t.id === tkA) && kq.j.live >= 1, kq.j && kq.j.live);
  const bcfg = await rpc(B, 'kitchen_config'), bq = await rpc(B, 'kds_queue');
  ok('kitchen: B config has none of A', bcfg.s === 200 && !JSON.stringify(bcfg.j).includes(stA) && !JSON.stringify(bcfg.j).includes(orgA), bcfg.j);
  ok('kitchen: B queue is empty', bq.s === 200 && bq.j.live === 0 && bq.j.tickets.length === 0 && !JSON.stringify(bq.j).includes(tkA));
  ok('kitchen: B cannot view or change A station', (await rpc(B, 'kitchen_station_view', { id: stA })).s === 404 && (await rpc(B, 'kitchen_station_save', { id: stA, name: 'Hacked' }, `gw-kit-${randomUUID()}`)).s === 404);
  ok('kitchen: B cannot link its station to A station, nor filter by it', refused(await rpc(B, 'kitchen_station_save', { name: 'Bx', kds_group_id: stA }, `gw-kit-${randomUUID()}`))
    && (await rpc(B, 'kds_queue', { station: 'main', location_id: locA })).j?.tickets?.length === 0);
  ok('kitchen: B cannot act on A ticket (start, item, ready, print)', (await Promise.all(['start', 'ready', 'print'].map(a => rpc(B, 'kds_ticket_act', { ticket_id: tkA, action: a }, `gw-kit-${randomUUID()}`)))).every(r => r.s === 404)
    && (await rpc(B, 'kds_ticket_act', { ticket_id: tkA, action: 'item_done', item_id: sql(`select id from order_items where order_id='${oid}' limit 1`) }, `gw-kit-${randomUUID()}`)).s === 404);
  ok('kitchen: A ticket untouched by B', sql(`select status from kot_tickets where id='${tkA}'`) === 'new');
  const kst = await rpc(A, 'kds_ticket_act', { ticket_id: tkA, action: 'start' }, `gw-kit-${randomUUID()}`);
  ok('kitchen: A starts its ticket', kst.s === 200 && kst.j.status === 'preparing', kst);
  ok('kitchen: a stale screen is a 409 version_conflict', await (async () => { const r = await rpc(A, 'kds_ticket_act', { ticket_id: tkA, action: 'print', expected_version: 'stale' }, `gw-kit-${randomUUID()}`); return r.s === 409 && r.j.code === 'version_conflict'; })());
  ok('kitchen: applicant with no business gets nothing', refused(await rpc(P1, 'kds_queue')) && refused(await rpc(P1, 'kitchen_config')));
  // ---- tables and floor (section H, 0404): A's tables, reservations and merges against B's token
  const tbl = l => sql(`insert into dining_tables(organization_id,location_id,label,seats,sort_order) values ('${orgA}','${locA}','${l}',4,1) returning id`).split('\n')[0];
  const tA1 = tbl('ZT1'), tA2 = tbl('ZT2'), tA3 = tbl('ZT3');
  const tB1 = sql(`insert into dining_tables(organization_id,location_id,label,seats) values ('${orgB}','${locB}','ZB1',4) returning id`).split('\n')[0];
  const soon = new Date(Date.now() + 86400000).toISOString();
  ok('tables: no token is 401; helpers are not on the allowlist', (await rpc(null, 'tbl_floor')).s === 401 && (await rpc(A, 'tbl_states')).s === 404 && (await rpc(A, 'tbl_guard')).s === 404);
  const fA = await rpc(A, 'tbl_floor');
  ok('tables: A sees its own three tables, all available', fA.s === 200 && fA.j.tables.filter(t => t.label.startsWith('ZT') && t.status === 'available').length === 3, fA);
  ok('tables: bad shape is a 400 with a sentence', await (async () => { const r = await rpc(A, 'tbl_view', { table_id: 'nope' }); return r.s === 400 && r.j.code === 'validation'; })());
  const rk = `gw-tbl-${randomUUID()}`, res = { table_id: tA1, guest_name: 'ZZ Guest', phone: '5550100', guests: 4, scheduled_at: soon };
  const tr1 = await rpc(A, 'tbl_reserve', res, rk), tr2 = await rpc(A, 'tbl_reserve', res, rk);
  ok('tables: reserve works and a retry with the same key is the same reservation', tr1.s === 200 && tr2.s === 200 && tr2.j.replayed === true && tr1.j.reservation.id === tr2.j.reservation.id, [tr1, tr2]);
  ok('tables: capacity is a 422 with a sentence', await (async () => { const r = await rpc(A, 'tbl_reserve', { ...res, table_id: tA2, guests: 9 }, `gw-tbl-${randomUUID()}`); return r.s === 422 && r.j.code === 'capacity'; })());
  const d3 = new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10);
  ok('tables: a booking in the store wall clock works; an instant without its zone is a 400', (await rpc(A, 'tbl_reserve', { table_id: tA2, guest_name: 'ZZ Local', phone: '5550101', guests: 2, local_date: d3, local_time: '19:30' }, `gw-tbl-${randomUUID()}`)).s === 200
    && (await rpc(A, 'tbl_reserve', { table_id: tA2, guest_name: 'ZZ NoZone', phone: '5550101', guests: 2, scheduled_at: `${d3}T12:00:00` }, `gw-tbl-${randomUUID()}`)).s === 400);
  ok('tables: transfer from an empty table is a 409', (await rpc(A, 'tbl_transfer', { from_table_id: tA1, to_table_id: tA2 })).s === 409);
  const mg = await rpc(A, 'tbl_merge', { table_ids: [tA2, tA3] });
  ok('tables: A merges two tables', mg.s === 200 && mg.j.combined_seats === 8, mg);
  const bFloor = await rpc(B, 'tbl_floor');
  ok('tables: B floor has only its own table', bFloor.s === 200 && bFloor.j.tables.length === 1 && bFloor.j.tables[0].label === 'ZB1' && !JSON.stringify(bFloor.j).includes(tA1), bFloor);
  ok('tables: B cannot view, read the order of, or read the history of A tables', (await rpc(B, 'tbl_view', { table_id: tA1 })).s === 404 && (await rpc(B, 'tbl_order_view', { table_id: tA1 })).s === 404 && (await rpc(B, 'tbl_history', { table_id: tA1 })).s === 404);
  ok('tables: B cannot reserve, transfer, merge, cancel or split anything of A', (await rpc(B, 'tbl_reserve', { ...res, guest_name: 'ZZ Intruder' }, `gw-tbl-${randomUUID()}`)).s === 404
    && (await rpc(B, 'tbl_transfer', { from_table_id: tA1, to_table_id: tB1 })).s === 404 && (await rpc(B, 'tbl_transfer', { from_table_id: tB1, to_table_id: tA1 })).s === 404
    && (await rpc(B, 'tbl_merge', { table_ids: [tA2, tA3] })).s === 404 && (await rpc(B, 'tbl_reserve_cancel', { id: tr1.j.reservation.id })).s === 404
    && (await rpc(B, 'tbl_split', { merge_id: mg.j.merge_id })).s === 404);
  ok('tables: B cannot open the A store, and A rows are untouched', refused(await rpc(B, 'tbl_floor', { location_id: locA }))
    && sql(`select count(*) from pos_reservations where organization_id='${orgA}' and guest_name='ZZ Intruder'`) === '0'
    && sql(`select count(*) from table_merge_members where merge_id='${mg.j.merge_id}' and released_at is null`) === '2'
    && sql(`select status from pos_reservations where row_id='${tr1.j.reservation.id}'`) === 'confirmed');
  ok('tables: A viewer (no order rights) is refused; applicant with no business gets nothing', (await rpc(V, 'tbl_floor')).s === 403 && refused(await rpc(P1, 'tbl_floor')) && refused(await rpc(P1, 'tbl_view', { table_id: tA1 })));
  ok('tables: A splits its merge', (await rpc(A, 'tbl_split', { merge_id: mg.j.merge_id })).s === 200);
  // ---- back office, section J (0420): low stock and purchase suggestions, A's against B's token and against a manager bound to one store
  sql(`update inventory_items set reorder_level = 20 where id = '${itemA}'`);
  const locA2 = sql(`insert into locations(organization_id,name,code) values ('${orgA}','ZZ GW Second ${run}','ZZ2-${run}') returning id`).split('\n')[0];
  const L = await person('mgr-l2-a', orgA, 'manager');
  const lUser = users[users.length - 1];
  sql(`update org_users set location_id = '${locA2}' where user_id = '${lUser}' and organization_id = '${orgA}'`);
  ok('backoffice: no token is 401, helpers are not on the allowlist', (await rpc(null, 'backoffice_low_stock')).s === 401
    && (await rpc(A, 'backoffice_low_stock_rows')).s === 404 && (await rpc(A, 'backoffice_org_wide')).s === 404 && (await rpc(A, 'purchase_suggestions_create_po')).s === 404);
  const boA = await rpc(A, 'backoffice_low_stock', { location_id: locA });
  ok('backoffice: A sees its item low at its store (10 <= 20; buy 20 - 10 - what the open draft receipt above brings)', boA.s === 200
    && boA.j.items.some(i => i.id === itemA && i.level === 'low' && Number(i.inbound_qty) > 0 && Number(i.suggested_qty) === 20 - 10 - Number(i.inbound_qty)), boA);
  ok('backoffice: bad shape is a 400', (await rpc(A, 'backoffice_low_stock', { filter: 'zomato' })).s === 400);
  const refA = await rpc(A, 'purchase_suggestions_refresh', { location_id: locA }, `gw-bo-${randomUUID()}`);
  ok('backoffice: A records suggestions', refA.s === 200 && refA.j.recorded >= 1, refA);
  const listA = await rpc(A, 'purchase_suggestions_list', { location_id: locA });
  const sA = listA.j?.suggestions?.find(x => x.item_id === itemA)?.id;
  ok('backoffice: A lists its suggestion', listA.s === 200 && !!sA, listA);
  ok('backoffice: B cannot read or refresh at A store', refused(await rpc(B, 'backoffice_low_stock', { location_id: locA })) && refused(await rpc(B, 'purchase_suggestions_list', { location_id: locA }))
    && refused(await rpc(B, 'purchase_suggestions_refresh', { location_id: locA }, `gw-bo-${randomUUID()}`)));
  ok('backoffice: B own views hold nothing of A', !JSON.stringify((await rpc(B, 'backoffice_low_stock')).j).includes(itemA) && !JSON.stringify((await rpc(B, 'purchase_suggestions_list')).j).includes(sA ?? 'none'));
  ok('backoffice: B cannot close A suggestion', (await rpc(B, 'purchase_suggestions_close', { ids: [sA], outcome: 'dismissed' }, `gw-bo-${randomUUID()}`)).s === 404);
  ok('backoffice J-2: manager bound to one store gets 403 store_scope for the whole business (read, list, refresh)', await (async () => { const r = await rpc(L, 'backoffice_low_stock'); return r.s === 403 && r.j.code === 'store_scope'; })()
    && (await rpc(L, 'purchase_suggestions_list')).s === 403 && (await rpc(L, 'purchase_suggestions_refresh', {}, `gw-bo-${randomUUID()}`)).s === 403);
  ok('backoffice J-2: bound manager cannot open or close the other store', (await rpc(L, 'backoffice_low_stock', { location_id: locA })).s === 404
    && (await rpc(L, 'purchase_suggestions_close', { ids: [sA], outcome: 'dismissed' }, `gw-bo-${randomUUID()}`)).s === 404);
  ok('backoffice J-2: bound manager reads own store', (await rpc(L, 'backoffice_low_stock', { location_id: locA2 })).s === 200);
  const ck = `gw-bo-${randomUUID()}`;
  const cl = await rpc(A, 'purchase_suggestions_close', { ids: [sA], outcome: 'ordered', purchase_order_ref: 'ZZ-PO-1' }, ck);
  ok('backoffice: A marks its suggestion ordered with its own reference', cl.s === 200 && cl.j.closed === 1, cl);
  ok('backoffice: the same close again is answered, nothing changes', (await rpc(A, 'purchase_suggestions_close', { ids: [sA], outcome: 'ordered', purchase_order_ref: 'ZZ-PO-1' }, ck)).j?.closed === 0);
  ok('backoffice: A suggestion untouched by B and the bound manager', sql(`select status||':'||purchase_order_ref||':'||(closed_by = (select user_id from org_users where organization_id='${orgA}' and role_id=(select id from roles where slug='manager') and location_id is null limit 1)) from purchase_suggestions where id='${sA}'`) === 'ordered:ZZ-PO-1:true');

  // ---- catalogue and GRN (section G, 0390/0391/0409): A's items and GRNs, touched with B's token by every G function
  const cck = `gw-cat-${randomUUID()}`, sku = `ZZG${run}`.toUpperCase().slice(0, 20);
  const c1 = await rpc(A, 'cat_item_save', { mode: 'quick', name: 'ZZ Cola', sku, price_minor: 4000, mrp_minor: 4500, barcode: `ZZB${run}` }, cck);
  ok('catalogue: A quick-adds an item (Idempotency-Key header)', c1.s === 200 && c1.j.sku === sku && c1.j.price_minor === 4000, c1);
  ok('catalogue: replay with the same key returns the same item', (await rpc(A, 'cat_item_save', { mode: 'quick', name: 'ZZ Cola', sku, price_minor: 4000 }, cck)).j?.id === c1.j.id);
  ok('catalogue: price above MRP is a 400 with a sentence', await (async () => { const r = await rpc(A, 'cat_item_save', { id: c1.j.id, version: c1.j.version, mode: 'quick', price_minor: 9900 }); return r.s === 400 && /MRP/.test(r.j.error ?? r.j.message ?? JSON.stringify(r.j)); })());
  ok('catalogue: search is cat_item_list with status active', await (async () => { const r = await rpc(A, 'cat_item_list', { q: sku, status: 'active' }); return r.s === 200 && r.j.items.some(i => i.id === c1.j.id); })());
  ok('catalogue: A views and looks up its item', (await rpc(A, 'cat_item_view', { id: c1.j.id })).s === 200 && (await rpc(A, 'cat_item_lookup', { code: `ZZB${run}` })).j?.id === c1.j.id);
  ok('catalogue: bad shape is a 400', (await rpc(A, 'cat_item_view', { id: 'nope' })).s === 400 && (await rpc(A, 'cat_item_save', { id: c1.j.id, name: 'no version' })).s === 400);
  ok('catalogue: helpers are not on the allowlist', (await rpc(A, 'cat_stock_map')).s === 404 && (await rpc(A, 'grn_rows')).s === 404 && (await rpc(A, 'grn_post_gate')).s === 404);
  ok('catalogue: B list has none of A', await (async () => { const r = await rpc(B, 'cat_item_list', {}); return r.s === 200 && !JSON.stringify(r.j).includes(c1.j.id); })());
  ok('catalogue: B cannot view, look up or change A item', (await rpc(B, 'cat_item_view', { id: c1.j.id })).s === 404 && (await rpc(B, 'cat_item_lookup', { code: `ZZB${run}` })).s === 404
    && (await rpc(B, 'cat_item_save', { id: c1.j.id, version: c1.j.version, mode: 'quick', name: 'Hacked' })).s === 404);
  ok('catalogue: viewer of A cannot add items', (await rpc(V, 'cat_item_save', { mode: 'quick', name: 'V', sku: `V${sku}`.slice(0, 20), price_minor: 1 }, `gw-cat-${randomUUID()}`)).s === 403);
  const gr = await rpc(A, 'inv_document_save', { doc_type: 'receipt', supplier_name: 'ZZ Supplier', lines: [{ inventory_item_id: c1.j.inventory_item_id, qty: 5 }] }, `gw-grn-${randomUUID()}`);
  const grs = await rpc(A, 'inv_document_act', { id: gr.j.id, action: 'submit', version: gr.j.version }, `gw-grn-${randomUUID()}`);
  ok('GRN: posting a receipt with no approved GRN is a 409 (the gate)', await (async () => { const r = await rpc(A, 'inv_document_act', { id: gr.j.id, action: 'post', version: grs.j.version }, `gw-grn-${randomUUID()}`); return r.s === 409 && /GRN/.test(JSON.stringify(r.j)); })());
  const g1 = await rpc(A, 'grn_open', { receipt_document_id: gr.j.id });
  ok('GRN: A opens the GRN of its receipt', g1.s === 200 && g1.j.status === 'matching', g1);
  const gi = await rpc(A, 'grn_invoice_save', { receipt_document_id: gr.j.id, supplier_name: 'ZZ Supplier', invoice_no: `ZZ-${run}`, invoice_date: '2026-10-10',
    lines: [{ inventory_item_id: c1.j.inventory_item_id, product_name: 'ZZ Cola', qty: 3, unit_price_minor: 3000 }, { inventory_item_id: c1.j.inventory_item_id, product_name: 'ZZ Cola', qty: 2, unit_price_minor: 2000 }] });
  ok('GRN: two lines of one item total 13000 and show a price difference', gi.s === 200 && gi.j.totals.invoice_amount_minor === 13000 && gi.j.invoice_total_minor === 13000 && gi.j.rows[0].state === 'price_diff', gi);
  const R = { receipt_document_id: gr.j.id };
  ok('GRN: B queue has none of A', await (async () => { const r = await rpc(B, 'grn_list', {}); return r.s === 200 && !JSON.stringify(r.j).includes(gr.j.id); })());
  ok('GRN: B cannot open, view or read the matching of A receipt', (await rpc(B, 'grn_open', R)).s === 404 && (await rpc(B, 'grn_view', R)).s === 404 && (await rpc(B, 'grn_matching_view', R)).s === 404);
  ok('GRN: B cannot enter an invoice, prices, a resolution, a request or a decision on A receipt',
    (await rpc(B, 'grn_invoice_save', { ...R, supplier_name: 'X', invoice_no: 'X1', invoice_date: '2026-10-10', lines: [{ product_name: 'x', qty: 1, unit_price_minor: 1 }] })).s === 404
    && (await rpc(B, 'grn_costs_save', { ...R, costs: [{ line_id: randomUUID(), unit_cost_minor: 1 }] })).s === 404
    && (await rpc(B, 'grn_resolve', { ...R, version: gi.j.version, resolution: 'accept_as_received', note: 'zz' })).s === 404
    && (await rpc(B, 'grn_request_approval', { ...R, version: gi.j.version })).s === 404
    && (await rpc(B, 'grn_decide', { ...R, version: gi.j.version, decision: 'approve' })).s === 404);
  ok('GRN: A review untouched after all of that', sql(`select status||':'||version from grn_reviews where receipt_document_id='${gr.j.id}'`) === 'matching:' + gi.j.version);
  const grc = await rpc(A, 'inv_document_act', { id: gr.j.id, action: 'cancel', version: grs.j.version }, `gw-grn-${randomUUID()}`);
  ok('GRN: cancelling the receipt closes its GRN', grc.s === 200 && (await rpc(A, 'grn_view', R)).j?.status === 'cancelled', grc);
  ok('GRN: the older one-call receipt (inventory_record over PostgREST, not on the allowlist) is refused too', await (async () => {
    const r = await fetch(`${U}/rest/v1/rpc/inventory_record`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${A}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p: { organization_id: orgA, kind: 'receipt', quantity: 50, inventory_item_id: c1.j.inventory_item_id } }) });
    return r.status >= 400 && /GRN_NOT_APPROVED/.test(await r.text()); })());
  ok('GRN: no stock moved for the test receipt', sql(`select count(*) from stock_movements where inventory_item_id='${c1.j.inventory_item_id}'`) === '0');
  ok('payment webhook hook answers 501 (not connected)', (await fetch(`${API}/webhooks/razorpay`, { method: 'POST' })).status === 501);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  try { sql(`delete from ol_partner_applications where business_name='ZZ GW Cafe ${run}'`); } catch (e) { console.log('note: application cleanup', e.message.slice(0, 120)); }
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST gw' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from table_merge_members where organization_id in ('${orgA}','${orgB}')`); sql(`delete from pos_reservations where organization_id in ('${orgA}','${orgB}')`); sql(`delete from dining_tables where organization_id in ('${orgA}','${orgB}')`); } catch {}
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
