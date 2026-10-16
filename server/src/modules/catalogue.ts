// VINII POS section G: the store catalogue. Database: migration 0390 (cat_item_* functions; items stay in menu_items and are linked to inventory_items).
//
//   GET  /api/partner/catalogue?q=&status=&category=&page=&page_size=&location=   counts, categories and one page of items
//   GET  /api/partner/catalogue/search?q=&limit=                                  compact search for the sell screen: active items by name, SKU or barcode
//   GET  /api/partner/catalogue/lookup?code=                                      one item by barcode or SKU (the Scan QR sheet)
//   GET  /api/partner/catalogue/:id                                               one item (detail drawer)
//   POST /api/partner/catalogue            (Idempotency-Key optional)             create: quick add or full item creation
//   PUT  /api/partner/catalogue/:id        (body.version required)                change an item
//
// Money is in minor units (paise): price_minor, mrp_minor, cost_minor. The server only checks the shape of the request; every rule
// (unique SKU and barcode, price not above MRP, GST slabs, tax needed unless draft, stale version, permissions, tenancy) is in the database.
import { z } from 'zod';
import { HttpError, readBody } from '../http.ts';
import { idempotencyKey } from '../idempotency.ts';
import { asCaller, call, needUuid } from './pos_db.ts';

const money = z.number().int().min(0).max(100_000_000_000);
const opt = <T extends z.ZodType>(t: T) => t.nullish();
const itemBody = z.object({
  mode: z.enum(['quick', 'full']).optional(), draft: z.boolean().optional(), version: z.number().int().min(1).optional(),
  name: z.string().max(120).optional(), sku: z.string().max(40).optional(), category: opt(z.string().max(60)), brand: opt(z.string().max(60)),
  barcode: opt(z.string().max(48)), price_minor: money.optional(), mrp_minor: opt(money), cost_minor: opt(money),
  hsn: opt(z.string().max(8)), gst_pct: opt(z.number().min(0).max(100)),
  selling_unit: z.enum(['pc', 'pack', 'kg', 'g', 'l', 'ml', 'dozen', 'box']).optional(),
  net_qty: opt(z.number().positive().max(1_000_000)), net_qty_unit: opt(z.enum(['g', 'kg', 'ml', 'l', 'pc'])),
  unit_description: opt(z.string().max(40)), purchase_pack_units: opt(z.number().positive().max(1_000_000)), storage: opt(z.string().max(40)),
}).strict();

function parse(body: unknown) {
  const r = itemBody.safeParse(body);
  if (!r.success) throw new HttpError(400, `Check the item details: ${r.error.issues[0]?.path.join('.') || 'request'} is not valid.`, undefined, 'bad_request');
  return r.data;
}

const q = (request: Request, name: string, max = 80) => (new URL(request.url).searchParams.get(name) ?? '').trim().slice(0, max);

export async function list(request: Request) {
  const page = Number(q(request, 'page', 6) || 1), size = Number(q(request, 'page_size', 4) || 20);
  if (!Number.isInteger(page) || page < 1 || !Number.isInteger(size) || size < 1 || size > 100) throw new HttpError(400, 'Page must be a whole number from 1; page size 1 to 100.', undefined, 'bad_request');
  return call(asCaller(request), 'cat_item_list', {
    q: q(request, 'q', 60) || null, status: q(request, 'status', 12) || 'all', category: q(request, 'category', 60) || null,
    location_id: q(request, 'location', 40) || null, page, page_size: size,
  });
}

export async function search(request: Request) {
  const size = Math.min(Math.max(Number(q(request, 'limit', 3) || 20), 1), 50);
  const out = await call<{ items: unknown[] }>(asCaller(request), 'cat_item_list', { q: q(request, 'q', 60) || null, status: 'active', page: 1, page_size: size });
  return { items: out.items };
}

export async function lookup(request: Request) {
  const code = q(request, 'code', 80);
  if (!code) throw new HttpError(400, 'Enter the code text.', undefined, 'bad_request');
  return call(asCaller(request), 'cat_item_lookup', { code });
}

export async function getOne(request: Request, id: string) {
  return call(asCaller(request), 'cat_item_view', { id: needUuid(id, 'Item') });
}

export async function create(request: Request) {
  const body = parse(await readBody(request));
  const key = idempotencyKey(request);
  return call(asCaller(request), 'cat_item_save', { ...body, ...(key ? { idempotency_key: key } : {}) });
}

export async function update(request: Request, id: string) {
  const body = parse(await readBody(request));
  if (!body.version) throw new HttpError(400, 'Refresh the item and try again.', undefined, 'bad_request');
  return call(asCaller(request), 'cat_item_save', { ...body, id: needUuid(id, 'Item') });
}
