// E2E + cross-tenant test of the storefront functions (section M) through POST /rpc/<name>. LOCAL ONLY. Business A has a manager (edits and publishes),
// a marketing manager (edits only) and a viewer; business B has an owner. B reads and changes nothing of A.
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8091 node scripts/storefront-e2e.mjs
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
  const email = `zz-sf-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, args = {}) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const refused = r => r.s >= 400 && r.s < 500;

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','ZZ SF A ${run}','zz-sf-a-${run}','franchise'),('${orgB}','ZZ SF B ${run}','zz-sf-b-${run}','franchise')`);
  sql(`insert into menu_items(organization_id,name,price) values ('${orgA}','A snack',21),('${orgB}','B snack',10)`);
  const itemA = sql(`select id from menu_items where organization_id='${orgA}'`), itemB = sql(`select id from menu_items where organization_id='${orgB}'`);
  const A = await person('mgr-a', orgA, 'manager'), M = await person('mkt-a', orgA, 'marketing_manager'), V = await person('viewer-a', orgA, 'viewer'), B = await person('owner-b', orgB, 'org_owner');
  ok('signed in', !!A && !!M && !!V && !!B);

  ok('storefront: no token is 401; helpers and tables are not on the allowlist', (await rpc(null, 'sf_options')).s === 401 && (await rpc(A, 'sf__editor')).s === 404 && (await rpc(A, 'sf_image_register')).s === 404
    && (await rpc(A, 'storefront_images')).s === 404 && (await rpc(A, 'vinii_publish_storefront')).s === 404);
  ok('storefront: viewer is refused everywhere (403)', (await rpc(V, 'sf_builder_get')).s === 403 && (await rpc(V, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'header' }] } })).s === 403);
  const o = await rpc(A, 'sf_options');
  ok('storefront: manager can edit and publish; marketing manager cannot publish', o.s === 200 && o.j.can_publish === true && (await rpc(M, 'sf_options')).j.can_publish === false, o);
  ok('storefront: bad shape is a 400 with code validation', await (async () => { const r = await rpc(A, 'sf_draft_save', { definition: 'x' }); return r.s === 400 && r.j.code === 'validation'; })());
  ok('storefront: bad colour is a 400 with a sentence', await (async () => { const r = await rpc(A, 'sf_draft_save', { expected_draft_version: 0, definition: { theme: { primary: 'green' }, sections: [{ type: 'header' }] } }); return r.s === 400 && /colour/i.test(r.j.detail); })());

  // pictures: the slot comes from the secure handler; a path outside the business folder is refused on attach
  const slot = await rpc(A, 'storefront_image_slot', { kind: 'banner', content_type: 'image/png', size: 1000 });
  ok('pictures: slot is under this business folder', slot.s === 200 ? slot.j.path.startsWith(`${orgA}/sf-banner/`) && !!slot.j.upload_url : slot.s === 502, slot);
  ok('pictures: viewer gets no slot, bad type and big size refused', (await rpc(V, 'storefront_image_slot', { kind: 'banner', content_type: 'image/png', size: 1000 })).s === 403
    && (await rpc(A, 'storefront_image_slot', { kind: 'banner', content_type: 'image/gif', size: 1000 })).s === 400 && (await rpc(A, 'storefront_image_slot', { kind: 'banner', content_type: 'image/png', size: 9e6 })).s === 400);
  ok('pictures: B cannot attach a path in A folder', refused(await rpc(B, 'storefront_image_attach', { kind: 'banner', content_type: 'image/png', size: 1000, path: `${orgA}/sf-banner/${randomUUID()}.png` })));
  const imgA = sql(`insert into storefront_images(organization_id,kind,path,mime,size_bytes) values ('${orgA}','banner','${orgA}/sf-banner/zz-${run}.png','image/png',1000) returning id`).split('\n')[0];

  // settings and page
  const prof = await rpc(A, 'sf_profile_save', { public_name: 'ZZ Noice Store', description: 'Best snacks. Lowest prices. Indian sweets.', business_category: 'Snacks', address_line: '24 Market Road, Bengaluru', store_slug: `zz-${run}` });
  ok('profile saved; store link is unique', prof.s === 200 && prof.j.profile.store_slug === `zz-${run}` && (await rpc(B, 'sf_profile_save', { public_name: 'B Store', store_slug: `zz-${run}` })).s === 409, prof);
  const days = [1, 2, 3, 4, 5, 6, 7].map(day => ({ day, open: true, opens: '09:00', closes: '21:00' }));
  ok('hours and delivery saved', (await rpc(A, 'sf_hours_save', { show: true, days })).s === 200 && (await rpc(A, 'sf_delivery_save', { pickup: true, home_delivery: true, method: 'own', radius_km: 5, est_min_minutes: 30, est_max_minutes: 45, delivery_fee_minor: 3000 })).s === 200);
  const d1 = await rpc(A, 'sf_draft_save', { expected_draft_version: 0, definition: { theme: {}, sections: [{ id: 'h', type: 'header' }, { id: 'ban', type: 'banner', config: { slides: [{ image_id: imgA }] } }, { id: 'pl', type: 'product_list', title: 'Weekend', config: { product_ids: [itemA] } }] } });
  ok('draft saved as version 1', d1.s === 200 && d1.j.draft_version === 1 && d1.j.has_unpublished_changes === true, d1);
  ok('draft: stale version is a 409 version_conflict', await (async () => { const r = await rpc(A, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'header' }] } }); return r.s === 409 && r.j.code === 'version_conflict'; })());
  const pv = await rpc(A, 'sf_preview', {});
  ok('preview resolves the products and turns picture paths into links (no storage path leaks)', pv.s === 200 && pv.j.sections[2].config.items?.[0]?.id === itemA && !JSON.stringify(pv.j).includes('"image_path"'), pv.j && JSON.stringify(pv.j.sections[2]).slice(0, 400));
  ok('publish: marketing manager is 403', (await rpc(M, 'sf_publish', { expected_version: 0 })).s === 403);
  const pub = await rpc(A, 'sf_publish', { expected_version: 0, expected_draft_version: 1 });
  ok('publish: version 1 with the store link path', pub.s === 200 && pub.j.version === 1 && pub.j.path === `/zz-${run}`, pub);
  ok('publish: exactly one version row and one audit row', sql(`select count(*) from vinii_storefront_versions where organization_id='${orgA}'`) === '1' && sql(`select count(*) from audit_logs where organization_id='${orgA}' and action='storefront.published'`) === '1');
  ok('publish again with nothing saved is a 409', (await rpc(A, 'sf_publish', { expected_version: 1 })).s === 409);

  // offers and ads
  const off = await rpc(A, 'sf_offer_save', { title: 'Weekend deal', message: 'Lowest prices', product_ids: [itemA] });
  ok('offer created and paused', off.s === 200 && (await rpc(A, 'sf_offer_act', { id: off.j.id, action: 'pause' })).j.phase === 'paused', off);
  const ad = await rpc(A, 'sf_ad_save', { title: 'Noice', image_id: imgA, daily_budget_minor: 10000, starts_on: '2026-10-10', ends_on: '2026-10-31' });
  ok('ad is requested as pending (never approved by the partner)', ad.s === 200 && ad.j.status === 'pending', ad);

  // B touches nothing of A
  ok('B: own builder is the starter page; none of A in products, offers, ads, pictures', await (async () => {
    const b = await rpc(B, 'sf_builder_get'); const p = await rpc(B, 'sf_products', {}); const of = await rpc(B, 'sf_offer_list'); const al = await rpc(B, 'sf_ad_list'); const il = await rpc(B, 'sf_image_library', {});
    return b.j.source === 'starter' && b.j.published_version === 0 && p.j.total === 1 && p.j.items[0].id === itemB && of.j.offers.length === 0 && al.j.ads.length === 0 && il.j.images.length === 0;
  })());
  ok('B: cannot reference A picture, product, offer or ad in a draft', refused(await rpc(B, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'custom_card', config: { image_id: imgA } }] } }))
    && refused(await rpc(B, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'product_list', config: { product_ids: [itemA] } }] } }))
    && refused(await rpc(B, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'deals', config: { offer_id: off.j.id } }] } }))
    && refused(await rpc(B, 'sf_draft_save', { expected_draft_version: 0, definition: { sections: [{ type: 'ads', config: { ad_id: ad.j.id } }] } })));
  ok('B: cannot change A product, offer or ad', (await rpc(B, 'sf_product_save', { id: itemA, visible: false })).s === 404 && (await rpc(B, 'sf_offer_act', { id: off.j.id, action: 'end' })).s === 404 && (await rpc(B, 'sf_ad_act', { id: ad.j.id, action: 'end' })).s === 404);
  ok('B: cannot publish A page', refused(await rpc(B, 'sf_publish', { expected_version: 1 })));
  ok('A: page, offer and ad untouched after all of that', sql(`select published_version from vinii_storefronts where organization_id='${orgA}'`) === '1' && sql(`select status from pos_offers where organization_id='${orgA}'`) === 'paused'
    && sql(`select status from pos_ad_requests where organization_id='${orgA}'`) === 'pending' && sql(`select visible from storefront_item_settings where organization_id='${orgA}'`) === '');
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  for (const t of ['pos_offer_rules', 'pos_offers', 'pos_ad_requests', 'storefront_item_settings', 'org_listing_profiles', 'org_fulfilment_settings', 'vinii_storefronts', 'storefront_images', 'menu_items', 'org_users']) {
    try { sql(`delete from ${t} where organization_id in ('${orgA}','${orgB}')`); } catch (e) { console.log('note: cleanup', t, e.message.slice(0, 100)); }
  }
  for (const id of users) { try { sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`) + ' (versions are append-only and stay with the test business)');
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
