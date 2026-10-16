// Workspace setup after approval, from the VINII Partner app (Figma section C, 16 Oct 2026). The approved owner (or an admin)
// sets up plan, payments, tax, POS device, staff, first items, OneLocal listing and delivery, then completes setup. This file is
// the doorway only: who is calling, a first check of each answer's shape, the listing image upload, and the encryption key.
// Every rule that matters (whose business, which values, when setup may complete) is enforced by the database functions of
// migration 0350, so a second client cannot get around them.
import { z } from 'zod';
import { piiKey as configPiiKey } from '../config.ts';
import { db, fromDbError, rpc } from '../db.ts';
import { HttpError } from '../http.ts';
import { requireUser } from '../staff.ts';

const BUCKET = 'partner-listing-media';
const MAX_BYTES = 5 * 1024 * 1024;
const EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png' };
const IMAGE_KINDS = ['logo', 'cover'] as const;

/** Who is calling. Any signed-in person; the database decides whether they own an approved business. */
export const partner = (request: Request): Promise<string> => requireUser(request, 'setup');

// Same key as onboarding (0348): a settlement account copied from the application must decrypt with it.
function piiKey(): string {
  const k = configPiiKey();
  if (!k) throw new HttpError(503, 'Saving these details is not available right now.', undefined, 'not_configured');
  return k;
}

function parse<T extends z.ZodTypeAny>(schema: T, raw: unknown): z.infer<T> {
  const r = schema.safeParse(raw);
  if (!r.success) {
    const first = r.error.issues[0];
    throw new HttpError(400, first?.message && first.message !== 'Required' ? first.message : `${first?.path.join('.') || 'request'}: please check this`, undefined, 'validation');
  }
  return r.data;
}

const clean = (s: string) => s.replace(/\s+/g, ' ').trim();
const text = (max: number, msg: string, min = 1) => z.string({ message: msg }).transform(clean).pipe(z.string().min(min, msg).max(max, msg));
const hhmm = (msg: string) => z.string({ message: msg }).regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, msg);
const amount = (msg: string) =>
  z.union([z.number(), z.string().trim().regex(/^(\d+(\.\d{1,2})?)?$/, msg).transform(s => (s === '' ? null : Number(s)))]).nullish();

// ---------- reading ----------

type Setup = Record<string, unknown> & { listing?: Record<string, unknown> };

/** The setup as the database describes it, with short-lived links to the listing images instead of storage paths. */
export async function getSetup(userId: string): Promise<Setup> {
  return withImageLinks(await rpc<Setup>('partner_setup_get', { p_user_id: userId }));
}

async function withImageLinks(s: Setup): Promise<Setup> {
  const l = s.listing;
  if (!l) return s;
  for (const kind of IMAGE_KINDS) {
    const path = l[`${kind}_path`] as string | null | undefined;
    delete l[`${kind}_path`];
    l[`${kind}_url`] = null;
    if (path) {
      const signed = await db().storage.from(BUCKET).createSignedUrl(path, 600);
      l[`${kind}_url`] = signed.error ? null : signed.data?.signedUrl ?? null;
    }
  }
  return s;
}

const call = async (fn: string, args: Record<string, unknown>) => withImageLinks(await rpc<Setup>(fn, args));

// ---------- frames ----------

export async function confirmPlan(userId: string, raw: unknown) {
  const b = parse(z.object({ plan_code: z.string().trim().max(60).nullish() }), raw);
  return call('partner_setup_confirm_plan', { p_user_id: userId, p_plan_code: b.plan_code || null });
}

const Payment = z.object({
  holder_name: text(120, 'Enter the name as on the bank account.', 2),
  bank_name: z.string().transform(clean).pipe(z.string().max(100, 'Bank name is too long.')).optional(),
  // Empty means "keep the saved account" (or the one from the application); the database refuses it when there is none.
  account_number: z.string().transform(s => s.replace(/\s/g, '')).pipe(z.string().regex(/^(\d{9,18})?$/, 'Account number must be 9 to 18 digits.')).optional(),
  ifsc: z.string().trim().toUpperCase().regex(/^([A-Z]{4}0[A-Z0-9]{6})?$/, 'IFSC looks wrong. It has 4 letters, a zero and 6 characters.').optional(),
  accept_upi: z.boolean().default(false),
  accept_card: z.boolean().default(false),
  upi_id: z.string().trim().toLowerCase().max(130).optional(),
});
export const savePayment = (userId: string, raw: unknown) =>
  call('partner_setup_save_payment', { p_user_id: userId, p: parse(Payment, raw), p_key: piiKey() });

const Tax = z.object({
  gst_registered: z.boolean({ message: 'Tell us whether your business is GST-registered.' }),
  gstin: z.string().trim().toUpperCase().optional(),
  invoice_prefix: z.string().trim().toUpperCase().max(6, 'Invoice prefix can have up to 6 letters or digits.').optional(),
  prices_include_tax: z.boolean({ message: 'Choose whether your prices include tax.' }),
  show_address_on_receipt: z.boolean().optional(),
  show_gstin_on_invoice: z.boolean().optional(),
});
export const saveTax = (userId: string, raw: unknown) => call('partner_setup_save_tax', { p_user_id: userId, p: parse(Tax, raw) });

const Pos = z.object({
  device_name: text(60, 'Give this POS device a name.', 2),
  peripherals: z.array(z.enum(['receipt_printer', 'scanner', 'kot_printer'], { message: 'Unknown peripheral.' })).max(3).default([]),
  connection: z.enum(['bluetooth', 'usb', 'lan'], { message: 'Choose Bluetooth, USB or network for your peripherals.' }).optional(),
});
export const registerPos = (userId: string, raw: unknown) => call('partner_setup_register_pos', { p_user_id: userId, p: parse(Pos, raw) });

const Staff = z.object({
  name: text(120, "Enter the staff member's name.", 2),
  email: z.string({ message: 'Enter a valid email for the invite.' }).trim().toLowerCase().email('Enter a valid email for the invite.').max(200),
  role: z.enum(['cashier', 'manager', 'kitchen'], { message: 'Choose a role.' }),
  permissions: z.array(z.enum(['billing.collect', 'catalogue.view', 'refunds.manage', 'settings.manage'], { message: 'Unknown permission.' })).max(4).default([]),
});
export const inviteStaff = (userId: string, raw: unknown) => call('partner_setup_invite_staff', { p_user_id: userId, p: parse(Staff, raw) });

const Item = z.object({
  name: text(120, 'Enter the item name.', 2),
  category: text(60, 'Enter a category.', 2),
  price: z.union([z.number(), z.string().trim().regex(/^\d+(\.\d{1,2})?$/, 'Enter a selling price above zero.').transform(Number)], { message: 'Enter a selling price above zero.' })
    .refine(n => n > 0 && n <= 1_000_000, 'Enter a selling price above zero.'),
  food_type: z.enum(['veg', 'non_veg', 'egg']).optional(),
});
export const addItem = (userId: string, raw: unknown) => call('partner_setup_add_item', { p_user_id: userId, p: parse(Item, raw) });

const Listing = z.object({
  public_name: text(80, 'Enter your public business name.', 2),
  description: z.string({ message: 'Tell customers what you sell in 10 to 500 characters.' }).trim()
    .min(10, 'Tell customers what you sell in 10 to 500 characters.').max(500, 'Tell customers what you sell in 10 to 500 characters.'),
  address_line: text(250, 'Enter the address customers should see.', 5),
  open_days: z.array(z.number().int().min(1).max(7), { message: 'Select the days you are open.' }).min(1, 'Select the days you are open.').max(7),
  opens_at: hhmm('Choose an opening time.'),
  closes_at: hhmm('Choose a closing time.'),
});
export const saveListing = (userId: string, raw: unknown) => call('partner_setup_save_listing', { p_user_id: userId, p: parse(Listing, raw) });

const Fulfilment = z.object({
  pickup: z.boolean().default(false),
  self_delivery: z.boolean().default(false),
  onelocal_delivery: z.boolean().default(false),
  radius_km: amount('Delivery radius must be 0.5 to 30 km.'),
  service_areas: z.array(z.string().max(60, 'Each area can be up to 60 characters.')).max(20, 'Up to 20 areas.').default([]),
  min_order: amount('Enter the minimum order in rupees.'),
  delivery_fee: amount('Enter the delivery fee in rupees.'),
  delivery_hours: z.enum(['same_as_opening', 'custom']).default('same_as_opening'),
  delivery_from: hhmm('Choose a delivery start time.').optional(),
  delivery_to: hhmm('Choose a delivery end time.').optional(),
});
export const saveFulfilment = (userId: string, raw: unknown) => call('partner_setup_save_fulfilment', { p_user_id: userId, p: parse(Fulfilment, raw) });

export async function tourSeen(userId: string, raw: unknown) {
  const b = parse(z.object({ step: z.number().int().min(1).max(10) }), raw);
  return call('partner_setup_tour_seen', { p_user_id: userId, p_step: b.step });
}

export const complete = (userId: string) => call('partner_setup_complete', { p_user_id: userId });

// ---------- listing images ----------
// Two steps, like the onboarding documents: ask for a private slot, the phone sends the bytes, then confirm. The database
// attaches the file only when the path is inside this business's own folder.

const UploadAsk = z.object({
  kind: z.enum(IMAGE_KINDS, { message: 'Unknown image type.' }),
  content_type: z.string().refine(t => t in EXT, 'Upload a JPG or PNG.'),
  size: z.number().int().min(1, 'That file is empty.').max(MAX_BYTES, 'Each image can be up to 5 MB.'),
});

async function organizationId(userId: string): Promise<string> {
  const s = await rpc<{ organization?: { id?: string } }>('partner_setup_get', { p_user_id: userId });
  const id = s.organization?.id;
  if (!id) throw new HttpError(404, 'Your business is not approved yet.', undefined, 'not_found');
  return id;
}

export async function askImageUpload(userId: string, raw: unknown) {
  const b = parse(UploadAsk, raw);
  const org = await organizationId(userId);
  const path = `${org}/${b.kind}/${crypto.randomUUID()}.${EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[setup] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: MAX_BYTES };
}

export async function confirmImageUpload(userId: string, raw: unknown) {
  const b = parse(UploadAsk.extend({ path: z.string().min(5).max(300) }), raw);
  const org = await organizationId(userId);
  if (!b.path.startsWith(`${org}/${b.kind}/`)) throw new HttpError(400, 'That file does not belong to your business.', undefined, 'validation');
  const info = await db().storage.from(BUCKET).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1 || size > MAX_BYTES) {
    await db().storage.from(BUCKET).remove([b.path]);
    throw new HttpError(422, size < 1 ? 'That file is empty.' : 'Each image can be up to 5 MB.', undefined, 'validation');
  }
  const res = await rpc<Setup>('partner_setup_attach_listing_image', { p_user_id: userId, p_kind: b.kind, p_path: b.path, p_mime: b.content_type, p_size: size });
  const replaced = res.replaced_path as string | null | undefined;
  if (replaced) await db().storage.from(BUCKET).remove([replaced]);       // the old copy is not kept
  delete res.replaced_path;
  return withImageLinks(res);
}

export { fromDbError };
