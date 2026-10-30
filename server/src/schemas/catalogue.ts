// Request shapes for the store catalogue functions (database: migration 0390, section G). A friendly first check of the shape of the
// request; every rule (unique SKU and barcode, price not above MRP, GST slabs, tax needed unless draft, stale version, linking a stock item,
// permissions, tenancy) is checked again in the database. Money is in minor units (paise).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const money = z.number().int().min(0).max(100_000_000_000);
const opt = <T extends z.ZodType>(t: T) => t.nullish();
const loc = { location_id: id.nullish() };

// list and search: the sell screen's search is this same call with status 'active' (no second alias)
export const List = z.object({
  ...loc, q: opt(z.string().max(60)), status: z.enum(['all', 'active', 'inactive', 'draft', 'out', 'combo'], { message: 'Unknown filter.' }).optional(),
  category: opt(z.string().max(60)), page: z.number().int().min(1).max(10_000).optional(), page_size: z.number().int().min(1).max(100).optional(),
}).strict();
export const View = z.object({ ...loc, id }).strict();
export const Lookup = z.object({ ...loc, code: z.string().trim().min(1, 'Enter the code text.').max(80) }).strict();
// create (no id; the Idempotency-Key header becomes idempotency_key) or change (id + version)
export const Save = z.object({
  id: id.optional(), version: z.number().int().min(1).optional(), idempotency_key: z.string().trim().max(100).optional(),
  mode: z.enum(['quick', 'full']).optional(), draft: z.boolean().optional(),
  name: z.string().max(120).optional(), sku: z.string().max(40).optional(), category: opt(z.string().max(60)), brand: opt(z.string().max(60)),
  barcode: opt(z.string().max(48)), price_minor: money.optional(), mrp_minor: opt(money), cost_minor: opt(money),
  hsn: opt(z.string().max(8)), gst_pct: opt(z.number().min(0).max(100)),
  selling_unit: z.enum(['pc', 'pack', 'kg', 'g', 'l', 'ml', 'dozen', 'box']).optional(),
  net_qty: opt(z.number().positive().max(1_000_000)), net_qty_unit: opt(z.enum(['g', 'kg', 'ml', 'l', 'pc'])),
  unit_description: opt(z.string().max(40)), purchase_pack_units: opt(z.number().positive().max(1_000_000)), storage: opt(z.string().max(40)),
}).strict().refine(b => !b.id || b.version, { message: 'Refresh the item and try again.', path: ['version'] });

// "Remove background (AI)" on the item form: the photo as base64 (JPG, PNG or WebP, up to 5 MB before encoding). Nothing is saved.
export const IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const RemoveBg = z.object({
  image_b64: z.string().min(16, 'That photo is empty.').max(Math.ceil(IMAGE_MAX_BYTES / 3) * 4 + 8, 'Each photo can be up to 5 MB.').regex(/^[A-Za-z0-9+/]+=*$/, 'That photo could not be read.'),
  content_type: z.enum(['image/jpeg', 'image/png', 'image/webp'], { message: 'Use a JPG, PNG or WebP photo.' }),
  // "AI picture · With background" on the Menu: the dish cut out and set on this colour (hex, no #); without it, a transparent PNG
  bg_color: z.string().regex(/^[0-9a-fA-F]{6}$/, 'Choose a background colour.').optional(),
}).strict();

// The item's saved photo (item-images bucket): ask for an upload slot, confirm the upload, or take the photo off.
export const PHOTO_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
export const PhotoAsk = z.object({
  item_id: id,
  content_type: z.enum(['image/jpeg', 'image/png', 'image/webp'], { message: 'Use a JPG, PNG or WebP photo.' }),
  size: z.number().int().min(1, 'That photo is empty.').max(IMAGE_MAX_BYTES, 'Each photo can be up to 5 MB.'),
}).strict();
export const PhotoAttach = PhotoAsk.extend({ path: z.string().min(5).max(300) }).strict();
export const PhotoRemove = z.object({ item_id: id }).strict();
