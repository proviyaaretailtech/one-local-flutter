// Captures real storefront answers (the NOICE story of the Figma frames) into ../test/fixtures/storefront_server.json, so the Flutter screens are
// tested against what the server really sends. LOCAL ONLY; leaves its test business behind (published versions are append-only).
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8091 node scripts/storefront-fixtures.mjs
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

import { writeFileSync } from 'node:fs';
const fx = {};
try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','ZZ NOICE ${run}','zz-noice-${run}','franchise'),('${orgB}','ZZ SF B ${run}','zz-sf-b-${run}','franchise')`);
  sql(`insert into menu_categories(id,organization_id,name) values ('${randomUUID()}','${orgA}','Best Deals'),('${randomUUID()}','${orgA}','Indian sweets')`);
  const prods = [['NOICE Rajasthani Aloo Bhujia', 21, 42], ['NOICE Masala Chana Dal', 35, 42], ['NOICE Cashews Salted', 120, 120], ['NOICE Oats', 99, 99], ['NOICE Cookies', 45, 45]];
  const ids = [];
  for (const [n, p, m] of prods) { const id = sql(`insert into menu_items(organization_id,name,price,sku,description) values ('${orgA}','${n}',${p},'${n.slice(6, 9).toUpperCase()}-${ids.length}','Crispy snack') returning id`).split('\n')[0]; ids.push(id); sql(`insert into catalogue_item_details(menu_item_id,organization_id,mrp_minor) values ('${id}','${orgA}',${m * 100})`); }
  const A = await person('mgr-a', orgA, 'manager'), B = await person('owner-b', orgB, 'org_owner');
  const img = k => sql(`insert into storefront_images(organization_id,kind,path,mime,size_bytes) values ('${orgA}','${k}','${orgA}/sf-${k}/zz-${run}-${randomUUID().slice(0, 4)}.png','image/png',1000) returning id`).split('\n')[0];
  const [banner, cat1, cat2, prodImg, adImg] = [img('banner'), img('category'), img('category'), img('product'), img('ad')];
  fx.options = (await rpc(A, 'sf_options')).j;
  fx.builder_starter = (await rpc(B, 'sf_builder_get')).j;
  await rpc(A, 'sf_profile_save', { public_name: 'The NOICE Store', description: 'Best snacks. Lowest prices. Discover Indian sweets, everyday munchies and more.', business_category: 'Snacks & Grocery', address_line: '24 Market Road, Indiranagar, Bengaluru', phone: '+919876543210', store_slug: `noice-${run}` });
  await rpc(A, 'sf_hours_save', { show: true, days: [1, 2, 3, 4, 5, 6, 7].map(day => ({ day, open: true, opens: '09:00', closes: '21:00' })) });
  fx.settings = (await rpc(A, 'sf_delivery_save', { pickup: true, home_delivery: true, method: 'own', radius_km: 5, est_min_minutes: 30, est_max_minutes: 45, delivery_fee_minor: 3000, min_order_minor: 9900, free_above_minor: 49900, use_business_hours: true })).j;
  fx.products_all = (await rpc(A, 'sf_products', {})).j;
  fx.products_on_offer = (await rpc(A, 'sf_products', { filter: 'on_offer' })).j;
  fx.product_saved = (await rpc(A, 'sf_product_save', { id: ids[0], description: 'Crispy potato and gram flour sticks with a bold Rajasthani spice blend.', image_id: prodImg })).j;
  fx.offer = (await rpc(A, 'sf_offer_save', { title: 'Weekend Binge, Lowest Prices!', message: 'Best snacks. Lowest prices.', product_ids: [ids[0], ids[1]], start_date: '2026-10-10T00:00:00Z', end_date: '2099-10-31T00:00:00Z' })).j;
  fx.offers = (await rpc(A, 'sf_offer_list')).j;
  fx.ad = (await rpc(A, 'sf_ad_save', { title: 'The NOICE Store', message: 'Best snacks. Lowest prices.', image_id: adImg, link_type: 'category', link_target: 'Best Deals', daily_budget_minor: 10000, starts_on: '2026-10-10', ends_on: '2026-10-31' })).j;
  fx.ads = (await rpc(A, 'sf_ad_list')).j;
  fx.images = (await rpc(A, 'sf_image_library', {})).j;
  const def = { theme: { primary: '#76EC00', secondary: '#0A0A0A', background: '#FFFFFF', section_style: 'rounded' }, sections: [
    { id: 'hdr', type: 'header', title: 'Header' },
    { id: 'ban', type: 'banner', title: 'Banner / Slider', config: { slides: [{ image_id: banner, link_type: 'category', link_target: 'c-best', title: 'The NOICE Store', subtitle: 'Best snacks. Lowest prices.' }] } },
    { id: 'cat', type: 'category_grid', title: 'Shop by Category', config: { layout: 'grid', columns: 3, categories: [{ id: 'c-best', name: 'Best Deals', image_id: cat1 }, { id: 'c-sweets', name: 'Indian sweets', image_id: cat2 }] } },
    { id: 'pl', type: 'product_list', title: 'Weekend Binge, Lowest Prices!', config: { layout: 'grid', columns: 3, show_ratings: true, show_delivery_time: true, show_discount: true, show_add_button: true, product_ids: [ids[0], ids[1]] } },
    { id: 'dl', type: 'deals', title: 'Deals', config: { offer_id: fx.offer.id } }] };
  fx.draft_saved = (await rpc(A, 'sf_draft_save', { expected_draft_version: 0, definition: def })).j;
  fx.preview = (await rpc(A, 'sf_preview', {})).j;
  fx.published = (await rpc(A, 'sf_publish', { expected_version: 0, expected_draft_version: 1 })).j;
  fx.builder_live = (await rpc(A, 'sf_builder_get')).j;
  fx.ids = { products: ids, banner, cat1, cat2 };
  writeFileSync('../test/fixtures/storefront_server.json', JSON.stringify(fx, null, 1));
  console.log('written', Object.keys(fx).join(' '));
} catch (e) { console.log('FAIL', e?.stack?.slice(0, 600)); process.exitCode = 1; }
finally { for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch {} } }
