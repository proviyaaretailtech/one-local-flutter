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
  // ---- section F (the till): B against A's bill, returns, receipts, coupons; and A's own control calls
  const fCoupon = await rpc(A, 'pos_coupon_save', { code: 'GWTEST5', kind: 'flat', value: 5 });
  ok('F: A (manager) creates a coupon', fCoupon.s === 200, fCoupon);
  ok('F: B does not see A coupons', (await x('pos_coupon_list', {})).j?.coupons?.length === 0);
  ok('F: B cannot use A coupon', refused(await x('pos_quote_order', { lines: [{ menu_item_id: bItem, qty: 1 }], coupon_code: 'GWTEST5' })));
  ok('F: B catalogue has none of A items', (await x('pos_sell_catalog', {})).j?.items?.every(i => i.name === 'B item'));
  ok('F: B receipts have none of A bills', !(await x('pos_receipt_list', {})).j?.some(r => r.id === oid));
  ok('F: B cannot split-pay, log an attempt on, or start online checkout for A bill',
    (await x('pos_split_pay', { order_id: oid, payments: [{ method: 'cash', amount: 1 }, { method: 'upi', amount: 1 }] }, `gw-${randomUUID()}`)).s === 404
    && (await x('pos_payment_attempt_record', { order_id: oid, method: 'card' })).s === 404 && (await x('pos_online_checkout', { order_id: oid })).s === 404);
  const fItem = sql(`select id from order_items where order_id='${oid}' limit 1`);
  const fRet = await rpc(A, 'pos_return_create', { order_id: oid, reason: 'gw test', lines: [{ order_item_id: fItem, qty: 1 }] }, `gw-${randomUUID()}`);
  ok('F: A records a return on its own bill', fRet.s === 200 && fRet.j.status === 'requested', fRet);
  ok('F: B cannot return against A bill, see, approve or refund A return',
    (await x('pos_return_create', { order_id: oid, reason: 'gw test', lines: [{ order_item_id: fItem, qty: 1 }] }, `gw-${randomUUID()}`)).s === 404
    && (await x('pos_return_list', {})).j?.length === 0
    && (await x('pos_return_decide', { return_id: fRet.j.return_id, decision: 'approve' })).s === 404
    && (await x('pos_return_issue_refund', { return_id: fRet.j.return_id, method: 'cash' }, `gw-${randomUUID()}`)).s === 404);
  ok('F: a viewer in A cannot record a return, take payment or save a coupon',
    (await rpc(V, 'pos_return_create', { order_id: oid, reason: 'gw test', lines: [{ order_item_id: fItem, qty: 1 }] }, `gw-${randomUUID()}`)).s === 403
    && (await rpc(V, 'pos_split_pay', { order_id: oid, payments: [{ method: 'cash', amount: 1 }, { method: 'upi', amount: 1 }] }, `gw-${randomUUID()}`)).s === 403
    && (await rpc(V, 'pos_coupon_save', { code: 'NOPE5', kind: 'flat', value: 5 })).s === 403);
  ok('F: an applicant with no business is refused', refused(await rpc(P1, 'pos_sell_catalog', {})) && refused(await rpc(P1, 'pos_receipt_list', {})) && refused(await rpc(P1, 'pos_return_list', {})));
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
  for (const t of ['sell_return_lines', 'sell_returns', 'sell_payment_attempts']) { try { sql(`alter table ${t} disable trigger user`); sql(`delete from ${t} where organization_id in ('${orgA}','${orgB}')`); sql(`alter table ${t} enable trigger user`); } catch { /* table absent */ } }
  try { sql(`delete from sell_coupons where organization_id in ('${orgA}','${orgB}')`); } catch { /* table absent */ }
  try { sql(`delete from ol_partner_applications where business_name='ZZ GW Cafe ${run}'`); } catch (e) { console.log('note: application cleanup', e.message.slice(0, 120)); }
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST gw' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
