// One Local POS control centre (Figma section D): the store dashboard and the owner's sales feed.
// Read-only. Every query is scoped to the caller's organisation, and to the outlets they are
// assigned to in org_user_locations when they have any assignment. Numbers come straight from the
// source tables (Commerce = orders/order_items, Inventory = inventory_* / pos_raw_materials,
// Purchasing = posted receipt documents with their recorded unit costs, plus legacy pos_goods_receipts). A figure with no source is sent as null, never as a guess.
import type { SupabaseClient } from '@supabase/supabase-js';
import { db, fromDbError } from '../db.ts';
import { HttpError } from '../http.ts';
import type { Staff } from '../staff.ts';

export type Outlet = { id: string; name: string; kind: string | null; timezone: string; last_sync_at: string | null };

// POS order states that are still moving (orders.status CHECK).
const ACTIVE = ['new', 'in_billing', 'sent_to_kitchen', 'ready', 'awaiting_payment'];
const SETTLED = ['paid', 'delivered'];
const DEFAULT_TZ = 'Asia/Kolkata';
const PAGE = 1000;

type Row = Record<string, any>;

function must<T>(r: { data: T | null; error: { message?: string; code?: string } | null }): T {
  if (r.error) fromDbError(r.error);
  return r.data as T;
}

// Reads every row of a query in pages (PostgREST answers at most 1000 rows at a time).
async function all(build: (from: number, to: number) => PromiseLike<{ data: Row[] | null; error: any }>): Promise<Row[]> {
  const out: Row[] = [];
  for (let from = 0; ; from += PAGE) {
    const page = must(await build(from, from + PAGE - 1)) ?? [];
    out.push(...page);
    if (page.length < PAGE) return out;
  }
}

function chunks<T>(list: T[], size = 200): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

const num = (v: unknown) => (v == null ? 0 : Number(v) || 0);
const money = (v: number) => Math.round(v * 100) / 100;

// ---------------- time ----------------

// Minutes the zone is ahead of UTC at a given instant.
function offsetMinutes(tz: string, at: Date): number {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
    .formatToParts(at).reduce<Record<string, string>>((m, p) => ({ ...m, [p.type]: p.value }), {});
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return Math.round((asUtc - at.getTime()) / 60000);
}

// The local calendar date (YYYY-MM-DD) of an instant in a zone.
export function localDate(tz: string, at: Date): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(at);
}

// The UTC instant at which a local date starts in a zone.
export function startOfLocalDay(tz: string, date: string): Date {
  const [y, m, d] = date.split('-').map(Number);
  const guess = new Date(Date.UTC(y, m - 1, d));
  const first = new Date(guess.getTime() - offsetMinutes(tz, guess) * 60000);
  // A second pass settles the rare day on which the offset itself changes.
  return new Date(guess.getTime() - offsetMinutes(tz, first) * 60000);
}

export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

// ---------------- scope ----------------

export type Scope = {
  // Reads run through this client: the caller's own (row-level security applies) when a route passes one.
  client: SupabaseClient;
  organizationId: string;
  outlets: Outlet[];
  // null = the whole organisation (no outlet assignment, so bills without an outlet count too)
  locationIds: string[] | null;
  timezone: string;
};

// Outlets this person may see. With rows in org_user_locations they see only those; without, every open outlet of
// their organisation. `wanted` narrows to one outlet and must be one of them (another organisation's id is a 404).
export async function scopeFor(staff: Staff, wanted?: string | null, client: SupabaseClient = db()): Promise<Scope> {
  const d = client;
  const assigned = must(await d.from('org_user_locations').select('location_id')
    .eq('organization_id', staff.organizationId).eq('user_id', staff.userId)) as Row[];
  let q = d.from('locations').select('id, name, kind, timezone, last_sync_at')
    .eq('organization_id', staff.organizationId).neq('status', 'closed').order('name');
  if (assigned.length) q = q.in('id', assigned.map(a => a.location_id));
  const outlets: Outlet[] = (must(await q) as Row[]).map(l => ({ id: l.id, name: l.name ?? '', kind: l.kind ?? null, timezone: l.timezone || DEFAULT_TZ, last_sync_at: l.last_sync_at ?? null }));

  if (wanted) {
    if (!/^[0-9a-f-]{36}$/i.test(wanted)) throw new HttpError(400, 'Unknown outlet.');
    const one = outlets.find(o => o.id === wanted);
    if (!one) throw new HttpError(404, 'Outlet not found.');
    return { client: d, organizationId: staff.organizationId, outlets: [one], locationIds: [one.id], timezone: one.timezone };
  }
  if (assigned.length && !outlets.length) throw new HttpError(403, 'No outlet is assigned to you yet.');
  return {
    client: d,
    organizationId: staff.organizationId,
    outlets,
    locationIds: assigned.length ? outlets.map(o => o.id) : null,
    timezone: outlets[0]?.timezone ?? DEFAULT_TZ,
  };
}

// Organisation filter, plus the outlet filter when the person is limited to some outlets.
function scoped(q: any, s: Scope): any {
  const base = q.eq('organization_id', s.organizationId);
  return s.locationIds ? base.in('location_id', s.locationIds) : base;
}

async function ordersBetween(s: Scope, from: Date, to: Date, columns: string): Promise<Row[]> {
  return all((a, b) => scoped(s.client.from('orders').select(columns), s)
    .gte('created_at', from.toISOString()).lt('created_at', to.toISOString())
    .order('created_at').order('id').range(a, b));
}

// Rows whose `column` is one of `ids`, read in batches so the request address stays short.
async function rowsFor(client: SupabaseClient, table: string, column: string, ids: string[], columns: string, extra?: (q: any) => any): Promise<Row[]> {
  const out: Row[] = [];
  for (const part of chunks(ids)) {
    let q: any = client.from(table).select(columns).in(column, part);
    if (extra) q = extra(q);
    out.push(...(must(await q) as Row[]));
  }
  return out;
}

async function accepting(client: SupabaseClient, organizationId: string): Promise<boolean | null> {
  const row = must(await client.rpc('pos_home_channel')) as Row | null;   // (0362) the marketplace switch, for the caller's own business
  return row ? row.accepting === true : null;
}

// ---------------- the dashboard ----------------

export function kindOf(domain: string | null | undefined, outletKind: string | null | undefined): 'store' | 'restaurant' | 'service' {
  const d = (domain ?? '').toLowerCase();
  if (d.includes('restaurant') || d.includes('food')) return 'restaurant';
  if (d.includes('service')) return 'service';
  if (d.includes('retail') || d.includes('store') || d.includes('grocery')) return 'store';
  return outletKind === 'restaurant' ? 'restaurant' : 'store';
}

// A One Local delivery order (ol_orders) speaks for its POS bill: its status is what the customer sees.
export function cardStatus(pos: string, ol: string | null): string {
  if (ol === 'placed') return 'new';
  if (ol === 'accepted') return 'preparing';
  if (ol === 'packed') return 'ready';
  if (ol === 'out') return 'out_for_delivery';
  return pos === 'sent_to_kitchen' ? 'preparing' : pos;
}

// Goods received: bills = old device receipts + posted receipts. Amount = the old receipts' totals + accepted units x the unit cost
// recorded at receiving (grn_receipt_costs, paise). If any accepted line of a posted receipt has no cost yet the amount is null
// (not reported), never a partial sum shown as the whole.
export function goodsReceived(legacy: Row[], receiptCount: number, lines: Row[], costs: Row[]): { bills: number; amount: number | null } {
  const cost = new Map(costs.map(c => [String(c.line_id), c.unit_cost_minor == null ? null : Number(c.unit_cost_minor)]));
  let paise = 0;
  let known = true;
  for (const l of lines) {
    const accepted = Math.max(num(l.qty) - num(l.rejected_qty), 0);
    if (accepted === 0) continue;
    const c = cost.get(String(l.id));
    if (c == null || !Number.isFinite(c)) { known = false; continue; }
    paise += Math.round(accepted * c);
  }
  const legacyRupees = legacy.reduce((n, g) => n + num(g.total), 0);
  return { bills: legacy.length + receiptCount, amount: known ? money(legacyRupees + paise / 100) : null };
}

export function fulfilment(channel: string, hasAddress: boolean): string {
  if (channel === 'pickup' || channel === 'dine_in' || channel === 'delivery') return channel;
  if (channel === 'online' || channel === 'swiggy' || channel === 'zomato') return hasAddress ? 'delivery' : 'pickup';
  return 'other';
}

export async function homeSummary(staff: Staff, wanted?: string | null, now = new Date(), client: SupabaseClient = db()) {
  const d = client;
  const s = await scopeFor(staff, wanted, client);
  const today = localDate(s.timezone, now);
  const from = startOfLocalDay(s.timezone, today);
  const to = startOfLocalDay(s.timezone, addDays(today, 1));

  const org = must(await d.from('organizations').select('business_domain').eq('id', staff.organizationId).maybeSingle()) as Row | null;
  const kind = kindOf(org?.business_domain, s.outlets[0]?.kind);

  // Today's bills (Commerce). Cancelled bills are not sales.
  const day = await ordersBetween(s, from, to, 'id, status, total, guest_count, paid_at');
  const sold = day.filter(o => o.status !== 'cancelled');
  const lines = await rowsFor(d, 'order_items', 'order_id', sold.map(o => o.id as string), 'name, qty, unit_price, status', q => q.neq('status', 'cancelled'));
  const byItem = new Map<string, { qty: number; revenue: number }>();
  for (const l of lines) {
    const k = String(l.name ?? '').trim() || 'Item';
    const e = byItem.get(k) ?? { qty: 0, revenue: 0 };
    e.qty += num(l.qty);
    e.revenue += num(l.qty) * num(l.unit_price);
    byItem.set(k, e);
  }
  const topItems = [...byItem.entries()].sort((a, b) => b[1].qty - a[1].qty || b[1].revenue - a[1].revenue).slice(0, 3)
    .map(([name, e]) => ({ name, qty: e.qty, revenue: money(e.revenue) }));

  // Bills still moving, whatever day they were placed on.
  const head = await scoped(d.from('orders').select('id', { count: 'exact', head: true }), s).in('status', ACTIVE);
  if (head.error) fromDbError(head.error);
  const latest = must(await scoped(d.from('orders').select('id, display_no, order_no, status, channel, total, created_at'), s)
    .in('status', ACTIVE).order('created_at', { ascending: false }).limit(3)) as Row[];
  const latestIds = latest.map(o => o.id as string);
  const latestLines = await rowsFor(d, 'order_items', 'order_id', latestIds, 'order_id, qty', q => q.neq('status', 'cancelled'));
  const latestOl = (must(await d.rpc('pos_home_online', { p: { order_ids: latestIds } })) ?? []) as Row[];   // (0362) status, has_address, eta only
  const activeOrders = latest.map(o => {
    const ol = latestOl.find(x => x.pos_order_id === o.id) ?? null;
    const eta = ol?.status === 'out' && ol.promised_eta_at ? Math.max(0, Math.round((Date.parse(ol.promised_eta_at) - now.getTime()) / 60000)) : null;
    return {
      id: o.id as string,
      number: (o.display_no as string) || String(o.order_no ?? ''),
      items: latestLines.filter(l => l.order_id === o.id).reduce((n, l) => n + num(l.qty), 0),
      total: money(num(o.total)),
      fulfilment: fulfilment(o.channel, !!ol?.has_address),
      status: cardStatus(o.status, ol?.status ?? null),
      eta_minutes: eta,
    };
  });

  // Catalogue gaps. menu_items belongs to the organisation (it has no outlet column).
  const items = await all((a, b) => d.from('menu_items').select('id, description, image_url')
    .eq('organization_id', staff.organizationId).order('id').range(a, b));
  let missingRecipes: number | null = null;
  if (kind === 'restaurant') {
    const linked = await all((a, b) => d.from('menu_item_recipes').select('menu_item_id').eq('organization_id', staff.organizationId).order('id').range(a, b));
    const posLinked = await all((a, b) => d.from('pos_recipes').select('linked_menu_item_id').eq('organization_id', staff.organizationId).is('deleted_at', null).order('row_id').range(a, b));
    const has = new Set([...linked.map(r => String(r.menu_item_id)), ...posLinked.map(r => String(r.linked_menu_item_id))]);
    missingRecipes = items.filter(i => !has.has(String(i.id))).length;
  }

  // Stock at or under its reorder level (Inventory): the OS ledger and the POS-synced raw materials.
  const balances = await all((a, b) => scoped(d.from('inventory_balances').select('inventory_item_id, available'), s).order('inventory_item_id').range(a, b));
  const materials = await all((a, b) => scoped(d.from('pos_raw_materials').select('name, unit, stock_qty, reorder_level'), s).is('deleted_at', null).order('row_id').range(a, b));
  const invItems = await rowsFor(d, 'inventory_items', 'id', [...new Set(balances.map(b => String(b.inventory_item_id)))], 'id, name, unit, reorder_level', q => q.eq('organization_id', staff.organizationId));
  const low: { name: string; quantity: number; unit: string | null; level: 'out' | 'low' }[] = [];
  for (const b of balances) {
    const it = invItems.find(i => i.id === b.inventory_item_id);
    if (!it || it.reorder_level == null) continue;
    const q = num(b.available);
    if (q <= num(it.reorder_level)) low.push({ name: it.name, quantity: q, unit: it.unit ?? null, level: q <= 0 ? 'out' : 'low' });
  }
  for (const m of materials) {
    if (m.reorder_level == null) continue;
    const q = num(m.stock_qty);
    if (q <= num(m.reorder_level)) low.push({ name: m.name, quantity: q, unit: m.unit ?? null, level: q <= 0 ? 'out' : 'low' });
  }
  low.sort((a, b) => (a.level === b.level ? a.quantity - b.quantity : a.level === 'out' ? -1 : 1));

  // Food the kitchen was told to make (a KOT) on a bill that was then cancelled: made, never charged.
  const cancelledIds = day.filter(o => o.status === 'cancelled').map(o => o.id as string);
  const kots = await rowsFor(d, 'kot_tickets', 'order_id', cancelledIds, 'id', q => q.eq('organization_id', staff.organizationId).neq('status', 'cancelled'));

  // Goods received today (Purchasing): receipts posted into stock today (section H/G documents, the record of what arrived) plus any
  // receipt still synced by the old device app (pos_goods_receipts).
  const legacyGrn = must(await scoped(d.from('pos_goods_receipts').select('total'), s).is('deleted_at', null)
    .gte('received_at', from.toISOString()).lt('received_at', to.toISOString())) as Row[];
  const receipts = await all((a, b) => scoped(d.from('inventory_documents').select('id'), s).eq('doc_type', 'receipt').in('status', ['posted', 'completed'])
    .gte('posted_at', from.toISOString()).lt('posted_at', to.toISOString()).order('id').range(a, b));
  const receiptIds = receipts.map(r => String(r.id));
  const receiptLines = await rowsFor(d, 'inventory_document_lines', 'document_id', receiptIds, 'id, qty, rejected_qty', q => q.eq('organization_id', staff.organizationId));
  const receiptCosts = await rowsFor(d, 'grn_receipt_costs', 'receipt_document_id', receiptIds, 'line_id, unit_cost_minor', q => q.eq('organization_id', staff.organizationId));
  const grn = goodsReceived(legacyGrn, receiptIds.length, receiptLines, receiptCosts);

  const one = s.outlets.length === 1 ? s.outlets[0] : null;
  return {
    person: { name: staff.name, role: staff.role },
    outlet: {
      id: one?.id ?? null,
      name: one?.name || (s.outlets.length > 1 ? `All outlets (${s.outlets.length})` : staff.organizationName),
      organization: staff.organizationName,
      kind,
      is_open: await accepting(s.client, staff.organizationId),
      last_sync_at: one?.last_sync_at ?? null,
    },
    outlets: s.outlets.map(o => ({ id: o.id, name: o.name })),
    date: today,
    timezone: s.timezone,
    as_of: now.toISOString(),
    sales: {
      total: money(sold.reduce((n, o) => n + num(o.total), 0)),
      orders: sold.length,
      settled: sold.filter(o => SETTLED.includes(o.status) || o.paid_at).length,
      pax: sold.reduce((n, o) => n + num(o.guest_count), 0),
      units: lines.reduce((n, l) => n + num(l.qty), 0),
      active: head.count ?? 0,
    },
    catalogue: {
      items: items.length,
      missing_descriptions: items.filter(i => !String(i.description ?? '').trim()).length,
      missing_photos: items.filter(i => !String(i.image_url ?? '').trim()).length,
      missing_recipes: missingRecipes,
    },
    active_orders: activeOrders,
    stock_tracked: balances.length > 0 || materials.length > 0,
    stock_health: low.slice(0, 4),
    stock_low_count: low.length,
    top_items: topItems,
    insights: {
      // No expense ledger exists in the schema yet (pos_expense_heads holds budgets, not spending).
      expenses: null,
      kot_not_billed: kots.length,
      grn,
      // No purchase price history is stored (pos_supplier_prices keeps only the latest price).
      price_trend: null,
    },
  };
}

// ---------------- the owner's feed ----------------

function periodTotals(rows: Row[]) {
  const sold = rows.filter(o => o.status !== 'cancelled');
  const net = sold.reduce((n, o) => n + num(o.total), 0);
  return {
    net_sales: money(net),
    orders: sold.length,
    orders_completed: sold.filter(o => SETTLED.includes(o.status)).length,
    aov: sold.length ? money(net / sold.length) : null,
  };
}

export async function homeFeed(staff: Staff, opts: { days: number; compare: boolean; location?: string | null }, now = new Date(), client: SupabaseClient = db()) {
  if (![1, 7, 30].includes(opts.days)) throw new HttpError(400, 'Choose 1, 7 or 30 days.');
  const s = await scopeFor(staff, opts.location, client);
  const today = localDate(s.timezone, now);
  const firstDay = addDays(today, 1 - opts.days);
  const from = startOfLocalDay(s.timezone, firstDay);
  const to = startOfLocalDay(s.timezone, addDays(today, 1));
  const prevFrom = startOfLocalDay(s.timezone, addDays(firstDay, -opts.days));
  const todayFrom = startOfLocalDay(s.timezone, today).getTime();

  const rows = await ordersBetween(s, opts.compare ? prevFrom : from, to, 'id, status, total, created_at');
  const inPeriod = rows.filter(o => Date.parse(o.created_at) >= from.getTime());
  const before = rows.filter(o => Date.parse(o.created_at) < from.getTime());
  const todays = periodTotals(inPeriod.filter(o => Date.parse(o.created_at) >= todayFrom));

  const daily = Array.from({ length: opts.days }, (_, i) => ({ date: addDays(firstDay, i), sales: 0 }));
  for (const o of inPeriod) {
    if (o.status === 'cancelled') continue;
    const slot = daily.find(x => x.date === localDate(s.timezone, new Date(o.created_at)));
    if (slot) slot.sales = money(slot.sales + num(o.total));
  }

  return {
    outlets: s.outlets.map(o => ({ id: o.id, name: o.name })),
    scope: s.outlets.length === 1 ? s.outlets[0].name : `All outlets (${s.outlets.length})`,
    days: opts.days,
    date: today,
    as_of: now.toISOString(),
    today: { sales: todays.net_sales, orders: todays.orders, is_open: await accepting(s.client, staff.organizationId) },
    period: periodTotals(inPeriod),
    previous: opts.compare ? periodTotals(before) : null,
    daily,
  };
}
