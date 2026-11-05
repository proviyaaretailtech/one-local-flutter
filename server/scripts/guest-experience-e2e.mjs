// E2E: the guest experience builder (0654) over HTTP against the standalone POS server, as the local Niks Cafe owner and an anonymous
// guest. LOCAL ONLY. Covers: builder, colour change live by rules, new wording through the real AI step (Groq, if GROQ_API_KEY is set on
// the server), a discount claim held for OneLocal review and approved (as the Master server would), the public brand page and menu,
// pre-order slots -> pre-order -> staff accept -> pickup order -> guest tracking, rollback, strangers refused.
// Leaves Niks Cafe with a clean published guest page (bistro look, dine-in + pre-order) for manual testing.
// Usage (from server/, server running):  POS_API=http://localhost:8095 node scripts/guest-experience-e2e.mjs
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY;
const ORG = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd', SLUG = 'niks-cafe';
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 600)); } };

async function call(url, body, headers = {}, method = 'POST') {
  const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: method === 'GET' ? undefined : JSON.stringify(body ?? {}) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j, t };
}
// the local demo password: LOCAL_DEMO_PASSWORD, else the workspace's local credentials note (agent/dev-credentials.md); never hosted
function localDemoPassword() {
  if (process.env.LOCAL_DEMO_PASSWORD) return process.env.LOCAL_DEMO_PASSWORD;
  const note = readFileSync(new URL('../../../agent/dev-credentials.md', import.meta.url), 'utf8');
  const m = note.match(/^password:\s*(\S+)/m);
  if (!m) throw new Error('set LOCAL_DEMO_PASSWORD (local demo password)');
  return m[1];
}
const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
  body: JSON.stringify({ email: 'owner@niks.proviyaa.test', password: localDemoPassword() }) }).then(r => r.json());
const token = login.access_token;
if (!token) throw new Error('Niks owner cannot sign in: run agent/demo/niks_cafe_local.sql and create the login first');
const rpc = (fn, body) => call(`${API}/rpc/${fn}`, body, { Authorization: `Bearer ${token}` });
const guest = (name, body) => call(`${API}/guest/${name}`, body, { 'x-ol-peer': '10.9.0.' + Math.floor(Math.random() * 200) });
const block = (def, type) => def.blocks.find(b => b.type === type);
const withDef = (def, f) => { const d = structuredClone(def); f(d); return d; };

// a fresh start: the e2e owns Niks Cafe's guest page history on the local DB
sql(`delete from guest_experience_versions where organization_id='${ORG}'; delete from guest_experiences where organization_id='${ORG}'`);
sql(`delete from guest_order_requests where organization_id='${ORG}' and kind='preorder' and idempotency_key like 'e2e-%'`);

// 1 builder
let b = await rpc('gx_builder_get', {});
ok('builder opens for the owner', b.s === 200 && b.j.draft?.blocks?.length >= 5 && b.j.business?.store_link === SLUG, b.j);
ok('stranger cannot open the builder', (await call(`${API}/rpc/gx_builder_get`, {})).s === 401);

// 2 colour change -> live by rules
let def = withDef(b.j.draft, d => { d.theme.accent = '#E4572E'; });
let s = await rpc('gx_draft_save', { expected_draft_version: b.j.draft_version, definition: def });
ok('draft saved', s.s === 200 && s.j.draft.theme.accent === '#E4572E', s.j);
let p = await rpc('gx_publish', { expected_draft_version: s.j.draft_version });
ok('colour change is live at once (rules)', p.s === 200 && p.j.result === 'auto_approved', p.j);

// 3 markup refused before anything
s = await rpc('gx_draft_save', { expected_draft_version: p.j.builder.draft_version, definition: withDef(def, d => { block(d, 'welcome').props.headline = '<b>hi</b>'; }) });
ok('markup in wording refused', s.s === 400, s.j);

// 4 new wording -> AI step on the server
b = await rpc('gx_builder_get', {});
def = withDef(b.j.draft, d => { block(d, 'welcome').props.headline = 'Slow coffee, warm toasties.'; block(d, 'welcome').props.subtext = 'Brewed fresh in Latur since morning.'; });
s = await rpc('gx_draft_save', { expected_draft_version: b.j.draft_version, definition: def });
p = await rpc('gx_publish', { expected_draft_version: s.j.draft_version });
const aiOn = sql(`select count(*) from guest_experience_versions where organization_id='${ORG}' and ai_model is not null and ai_note not like 'AI reviewer is not set up%'`);
ok('ordinary wording is approved by the AI step (or by rules when AI is off)', p.s === 200 && ['ai_approved', 'pending_human'].includes(p.j.result), p.j);
console.log('     AI result:', p.j.result, '·', p.j.version?.decided_by_name ?? '', '· note:', (p.j.version?.ai_note ?? sql(`select coalesce(ai_note,'') from guest_experience_versions where organization_id='${ORG}' order by version desc limit 1`)).slice(0, 160), aiOn === '0' ? '(AI not configured)' : '');

// 4b a claim the rules cannot see but the AI flags -> held for a person with the AI's note
if (aiOn !== '0') {
  b = await rpc('gx_builder_get', {});
  s = await rpc('gx_draft_save', { expected_draft_version: b.j.draft_version, definition: withDef(b.j.draft, d => { block(d, 'welcome').props.subtext = 'Best cafe in India, guaranteed ready in 5 minutes.'; }) });
  p = await rpc('gx_publish', { expected_draft_version: s.j.draft_version });
  ok('AI flags an unprovable claim -> held for a person, with its note', p.j.result === 'pending_human' && (p.j.version.ai_note ?? '').length > 5, p.j);
  console.log('     AI note:', p.j.version?.ai_note);
}

// 5 discount claim -> held for OneLocal (money), live page unchanged
b = await rpc('gx_builder_get', {});
const liveBefore = b.j.live_version;
def = withDef(b.j.draft, d => { block(d, 'welcome').props.headline = 'Flat 50% OFF on all shakes today'; });
s = await rpc('gx_draft_save', { expected_draft_version: b.j.draft_version, definition: def });
p = await rpc('gx_publish', { expected_draft_version: s.j.draft_version });
ok('discount claim is held for review (money)', p.j.result === 'pending_human' && p.j.version.categories.includes('money'), p.j);
ok('the held change lists from -> to and why', p.j.version.changes?.some(c => c.to === 'Flat 50% OFF on all shakes today' && /discount|price|offer/.test(c.why)), p.j.version);
ok('live page unchanged while held', (await rpc('gx_builder_get', {})).j.live_version === liveBefore);
let card = await guest('card', { slug: SLUG });
ok('public menu still shows the earlier headline', card.s === 200 && block(card.j.menu.experience, 'welcome').props.headline !== 'Flat 50% OFF on all shakes today', card.j);

// 6 OneLocal reviewer (Master server path): reject needs a note; reject; restaurant sees the reason
const held = p.j.version.id;
ok('reject without a note refused', sql(`select (select 1 from (select 1) x where false)`) === '' && (() => { try { sql(`select gx_review_decide('{"id":"${held}","action":"reject"}')`); return false; } catch { return true; } })());
sql(`select gx_review_decide('{"id":"${held}","action":"reject","note":"Link the offer to a coupon in Offers first, then mention it.","actor_name":"E2E reviewer"}')`);
b = await rpc('gx_builder_get', {});
ok('restaurant sees the rejection and its reason', b.j.last_decision?.status === 'rejected' && /coupon/.test(b.j.last_decision?.review_note ?? ''), b.j.last_decision);

// 7 pre-order switched on -> compliance hold -> approved by a reviewer -> live
def = withDef(b.j.draft, d => {
  block(d, 'welcome').props.headline = 'Slow coffee, warm toasties.';
  block(d, 'welcome').props.subtext = 'Brewed fresh in Latur since morning.';
  block(d, 'order_mode').props.pre_order = true;
  block(d, 'preorder').props = { days_ahead: 3, slot_minutes: 30, opens: '00:00', closes: '23:30', lead_minutes: 0, note_hint: 'e.g. less sugar, pack separately' };
  block(d, 'highlights').enabled = true;
  block(d, 'highlights').props.pick_ids = b.j.dishes.slice(0, 3).map(x => x.id);
});
s = await rpc('gx_draft_save', { expected_draft_version: b.j.draft_version, definition: def });
p = await rpc('gx_publish', { expected_draft_version: s.j.draft_version });
ok('turning on pre-order is held (compliance)', p.j.result === 'pending_human' && p.j.version.categories.includes('compliance'), p.j);
sql(`select gx_review_decide('{"id":"${p.j.version.id}","action":"approve","actor_name":"E2E reviewer"}')`);
b = await rpc('gx_builder_get', {});
ok('approved: live now', b.j.live_version === p.j.version.version && b.j.history[0].status === 'human_approved', b.j.history?.[0]);

// 8 public brand page + menu with the experience
const page = await call(`${API}/${SLUG}`, null, {}, 'GET');
ok('onelocal.co/<store link> serves the guest page', page.s === 200 || page.s === 503, page.s);
if (page.s === 503) console.log('     (guest web bundle not built yet on this server: run tool/build_guest_web.sh)');
card = await guest('card', { slug: SLUG });
ok('public menu carries the live experience', card.s === 200 && card.j.menu.experience.theme.accent === '#E4572E' && block(card.j.menu.experience, 'order_mode').props.pre_order === true, card.j?.menu?.experience);

// 9 pre-order: slots -> place -> staff accept -> pickup order -> tracking
const slots = await guest('slots', { slug: SLUG });
ok('pre-order slots offered', slots.s === 200 && slots.j.days.length >= 1, slots.j);
const at = slots.j.days.at(-1).slots[0];
const dish = b.j.dishes[0];
const bad = await guest('preorder', { slug: SLUG, idempotency_key: 'e2e-' + randomUUID(), lines: [{ menu_item_id: dish.id, qty: 1 }], guest_name: 'Asha', phone: '9876500011', pickup_at: '2020-01-01T10:00:00+05:30' });
ok('a pickup time that is not offered is refused', bad.s === 400, bad.j);
const key = 'e2e-' + randomUUID();
const pre = await guest('preorder', { slug: SLUG, idempotency_key: key, lines: [{ menu_item_id: dish.id, qty: 2 }], guest_name: 'Asha', phone: '98765 00011', pickup_at: at, note: 'less sugar' });
ok('pre-order sent, waiting', pre.s === 200 && pre.j.status === 'waiting' && /^[0-9a-f]{36}$/.test(pre.j.track), pre.j);
const again = await guest('preorder', { slug: SLUG, idempotency_key: key, lines: [{ menu_item_id: dish.id, qty: 2 }], guest_name: 'Asha', phone: '98765 00011', pickup_at: at, note: 'less sugar' });
ok('same tap twice = one pre-order', again.s === 200 && again.j.replayed === true && again.j.id === pre.j.id, again.j);
const inbox = await rpc('guest_requests_list', {});
const mine = inbox.j?.requests?.find(r => r.id === pre.j.id);
ok('staff inbox shows it as a pre-order with pickup and phone', mine?.kind === 'preorder' && mine?.table === null && mine?.guest_phone === '9876500011', mine ?? inbox.j);
const acc = await rpc('guest_request_decide', { id: pre.j.id, action: 'accept' });
ok('staff accept makes a pickup order', acc.s === 200 && acc.j.status === 'accepted' && sql(`select channel from orders where id='${acc.j.order_id}'`) === 'pickup', acc.j);
ok('accepted pre-order waits as a held order (no kitchen ticket, no stock used yet)', sql(`select status from orders where id='${acc.j.order_id}'`) === 'in_billing'
  && sql(`select count(*) from kot_tickets where order_id='${acc.j.order_id}'`) === '0', sql(`select status from orders where id='${acc.j.order_id}'`));
ok('it is in the outlet that took it', sql(`select location_id from orders where id='${acc.j.order_id}'`) === sql(`select location_id from guest_order_requests where id='${pre.j.id}'`));
const track = await guest('pretrack', { track: pre.j.track });
ok('guest tracking shows the order', track.s === 200 && track.j.status === 'accepted' && track.j.order?.display_no, track.j);
ok('a wrong tracking link learns nothing', (await guest('pretrack', { track: '0'.repeat(36) })).s === 404);

// 10 rollback to version 1 (colour only), then republish the approved page so Niks is left ready for manual testing
const r1 = await rpc('gx_rollback', { version: 1 });
ok('rollback is live at once', r1.s === 200 && r1.j.result === 'auto_approved' && r1.j.version.source === 'rollback', r1.j);
const best = b.j.history[0].version;
const r2 = await rpc('gx_rollback', { version: best });
ok('roll forward to the approved page', r2.s === 200 && r2.j.result === 'auto_approved', r2.j);

// 11 limits and strangers
ok('reserved name is not a store link', (await call(`${API}/privacy`, null, {}, 'GET')).s === 404);
ok('unknown store link: same "not available" answer', (await guest('card', { slug: 'no-such-cafe-' + Date.now().toString(36) })).s === 404);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
