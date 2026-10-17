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
  // ---- team (section L): the same gateway, A's people and tasks against B's token
  const OA = await person('owner-a', orgA, 'org_owner');
  const staffA = sql(`insert into pos_staff(organization_id,location_id,staff_code,full_name,mobile,designation,bank_name,account_number,monthly_salary) values ('${orgA}','${locA}','ZZ-S1','ZZ Staff A','9000011111','Cashier','HDFC','998877665544',25000) returning id`).split('\n')[0];
  ok('team: no token is 401, service-only helpers are not on the allowlist', (await rpc(null, 'team_dashboard')).s === 401 && (await rpc(A, 'team_member_json')).s === 404 && (await rpc(A, 'team_task_event')).s === 404);
  const tDash = await rpc(A, 'team_dashboard');
  ok('team: A manager reads its dashboard (3 people: manager, owner, viewer)', tDash.s === 200 && Number(tDash.j.members) === 3 && tDash.j.can_invite === false, tDash);
  ok('team: A viewer has no team access', refused(await rpc(V, 'team_dashboard')) && refused(await rpc(V, 'team_user_list')));
  ok('team: A manager cannot invite (403)', (await rpc(A, 'team_invite', { full_name: 'Zed Zed', mobile: '9876500001', email: `zz-inv-${run}@example.com`, role_slug: 'biller', location_id: locA })).s === 403);
  const inv = await rpc(OA, 'team_invite', { full_name: 'ZZ Pooja', mobile: '9876500002', email: `zz-pooja-${run}@example.com`, role_slug: 'biller', location_id: locA });
  ok('team: A owner invites; answer has no token; delivery pending', inv.s === 200 && inv.j.status === 'invited' && inv.j.delivery === 'pending' && !JSON.stringify(inv.j).includes('token'), inv);
  const dup = await rpc(OA, 'team_invite', { full_name: 'ZZ Pooja', mobile: '98765 00002', email: `zz-pooja2-${run}@example.com`, role_slug: 'biller', location_id: locA });
  ok('team: same number again is 409 duplicate_mobile (the frame error)', dup.s === 409 && dup.j.code === 'duplicate_mobile' && /already has an invitation/.test(dup.j.detail ?? dup.j.error ?? dup.j.message ?? ''), dup);
  const rs = await rpc(OA, 'team_invite', { full_name: 'ZZ Pooja', mobile: '9876500002', email: `zz-pooja2-${run}@example.com`, role_slug: 'biller', location_id: locA, resend: true });
  ok('team: Resend invitation resends the same one', rs.s === 200 && rs.j.id === inv.j.id && rs.j.send_count === 2, rs);
  const ceil = await rpc(OA, 'team_invite', { full_name: 'ZZ Own', mobile: '9876500003', email: `zz-own-${run}@example.com`, role_slug: 'org_owner' });
  ok('team: an owner may invite an admin (the admin and owner ceiling is covered in the DB test)', ceil.s === 200);
  ok('team: bad shape is a 400 with a sentence', await (async () => { const r = await rpc(OA, 'team_user_view', { id: 'nope' }); return r.s === 400 && r.j.code === 'validation'; })());
  const tk = await rpc(OA, 'team_task_save', { title: 'ZZ Restock', assignee_staff_id: staffA }, `gw-team-${randomUUID()}`);
  ok('team: A owner creates a task for A staff', tk.s === 200 && tk.j.status === 'assigned' && tk.j.assignee_name === 'ZZ Staff A', tk);
  const tkey = `gw-team-${randomUUID()}`;
  const tk1 = await rpc(OA, 'team_task_save', { title: 'ZZ Replay' }, tkey), tk2 = await rpc(OA, 'team_task_save', { title: 'ZZ Replay' }, tkey);
  ok('team: same Idempotency-Key replays the same task', tk1.s === 200 && tk2.j.id === tk1.j.id && tk2.j.replayed === true, tk2);
  ok('team: stale version is 409 version_conflict', await (async () => { const r = await rpc(OA, 'team_task_act', { id: tk.j.id, action: 'start', version: 99 }); return r.s === 409 && r.j.code === 'version_conflict'; })());
  const aList = await rpc(OA, 'team_user_list'), uids = JSON.stringify(aList.j);
  const memberA = sql(`select id from org_users where organization_id='${orgA}' and role_id=(select id from roles where slug='manager') limit 1`);
  // B (another business, real owner) against A's people and tasks
  const bDash2 = await rpc(B, 'team_dashboard');
  ok('team: B dashboard counts only B (1 person, no invitations, no tasks)', bDash2.s === 200 && Number(bDash2.j.members) === 1 && Number(bDash2.j.invitations) === 0 && Number(bDash2.j.tasks_due) === 0, bDash2);
  const bList2 = await rpc(B, 'team_user_list');
  ok('team: B user list has none of A', bList2.s === 200 && bList2.j.items.length === 1 && !JSON.stringify(bList2.j).includes('ZZ Pooja') && !JSON.stringify(bList2.j).includes(memberA), bList2);
  ok('team: B cannot open an A person or invitation', (await rpc(B, 'team_user_view', { id: memberA })).s === 404 && (await rpc(B, 'team_user_view', { id: inv.j.id })).s === 404);
  ok('team: B cannot revoke, suspend or re-role an A person', (await rpc(B, 'team_invite_act', { id: inv.j.id, action: 'revoke' })).s === 404
    && (await rpc(B, 'team_user_act', { id: memberA, action: 'suspend' })).s === 404 && (await rpc(B, 'team_user_act', { id: memberA, action: 'set_role', role_slug: 'org_owner' })).s === 404);
  ok('team: B cannot invite into A place', refused(await rpc(B, 'team_invite', { full_name: 'Spy Spy', mobile: '9876500009', email: `zz-spy-${run}@example.com`, role_slug: 'biller', location_id: locA })));
  ok('team: B cannot see, change or act on an A task, nor give B work to A staff', (await rpc(B, 'team_task_view', { id: tk.j.id })).s === 404 && (await rpc(B, 'team_task_act', { id: tk.j.id, action: 'cancel', version: 1 })).s === 404
    && (await rpc(B, 'team_task_save', { id: tk.j.id, version: 1, title: 'Hijack' })).s === 404 && refused(await rpc(B, 'team_task_save', { title: 'Spy task', assignee_staff_id: staffA })));
  ok('team: B task list, options and activity hold nothing of A', (await rpc(B, 'team_task_list')).j.items.length === 0 && !JSON.stringify((await rpc(B, 'team_options')).j).includes(staffA)
    && !JSON.stringify((await rpc(B, 'team_activity', { range: '7d' })).j).includes('ZZ Pooja'));
  ok('team: A pay and bank data never leave the database', !uids.includes('998877665544') && !JSON.stringify(tk.j).includes('25000') && !JSON.stringify((await rpc(OA, 'team_options')).j).includes('998877665544'));
  ok('team: applicant with no business gets nothing', refused(await rpc(P1, 'team_dashboard')) && refused(await rpc(P1, 'team_user_view', { id: memberA })));
  ok('payment webhook hook answers 501 (not connected)', (await fetch(`${API}/webhooks/razorpay`, { method: 'POST' })).status === 501);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  try { sql(`delete from ol_partner_applications where business_name='ZZ GW Cafe ${run}'`); } catch (e) { console.log('note: application cleanup', e.message.slice(0, 120)); }
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST gw' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch {}
  try { sql(`delete from pos_task_events where organization_id in ('${orgA}','${orgB}')`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
