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
// the categories the store registered with at onboarding: Quick add lists them first
export const StoreCategories = z.object({ ...loc }).strict();
export const Lookup = z.object({ ...loc, code: z.string().trim().min(1, 'Enter the code text.').max(80) }).strict();
// The SKU's parts: subcategory (3 letters), brand / item code (3), size with unit (500G, 1L, 6X80G, KG), and an OneLocal product to reuse.
const code3 = z.string().trim().regex(/^[A-Za-z0-9]{3}$/, 'Choose from the OneLocal list.');
export const SkuParts = z.object({
  sub: code3, slot3: code3, size: z.string().trim().min(1, 'Give the size and unit.').max(16, 'Give the size and unit.'),
  master_sku: z.string().trim().max(40).nullish(),
}).strict();
export const SkuOptions = z.object({}).strict();
export const SkuLookup = z.object({ barcode: z.string().trim().min(4).max(48) }).strict();
export const SkuVariants = z.object({ sub: code3, slot3: code3, size: z.string().trim().min(1).max(16) }).strict();
export const SkuBrandPropose = z.object({
  name: z.string().trim().min(2, 'Enter the brand name.').max(60, 'The brand name is too long.'),
  kind: z.enum(['brand', 'loose_item', 'local_brand']).optional(), barcode: z.string().trim().max(48).nullish(),
}).strict();

// create (no id; the Idempotency-Key header becomes idempotency_key) or change (id + version)
export const Save = z.object({
  id: id.optional(), version: z.number().int().min(1).optional(), idempotency_key: z.string().trim().max(100).optional(),
  mode: z.enum(['quick', 'full']).optional(), draft: z.boolean().optional(),
  name: z.string().max(120).optional(), sku: z.string().max(40).optional(), category: opt(z.string().max(60)), brand: opt(z.string().max(60)),
  barcode: opt(z.string().max(48)), price_minor: money.optional(), mrp_minor: opt(money), cost_minor: opt(money),
  hsn: opt(z.string().max(8)), gst_pct: opt(z.number().min(0).max(100)),
  // the units fit the product's category (31 Oct 2026): pc, kg, l … and pair, set, metre or the store's own short word (hosted_quick_add_units_2026-10-31.sql)
  selling_unit: z.string().trim().toLowerCase().regex(/^[a-z][a-z0-9 .-]{0,11}$/, 'A unit is a short word, like pc, kg, pair or metre.').optional(),
  net_qty: opt(z.number().positive().max(1_000_000)), net_qty_unit: opt(z.enum(['g', 'kg', 'ml', 'l', 'pc'])),
  unit_description: opt(z.string().max(40)), purchase_pack_units: opt(z.number().positive().max(1_000_000)), storage: opt(z.string().max(40)),
  // MRP-based (packed goods) or store-based (the store's own price): hosted_price_basis_2026-10-31.sql
  price_basis: opt(z.enum(['mrp', 'store'], { message: 'Choose MRP-based or store-based pricing.' })),
  // the SKU's parts (founder's OL SKU sheet, 31 Oct 2026): the database makes the SKU from them; a new item needs them
  sku_parts: SkuParts.optional(),
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
