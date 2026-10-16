// Partner onboarding from the VINII Partner app (Figma section B, 15 Oct 2026). A person who has signed in (any login, no store
// yet) fills seven sections and submits; operations reviews the same application in Master Admin. This file is only the doorway:
// who is calling, a first check of the shape of each answer, the file handling, and the encryption key. Every rule that matters
// (which fields, which formats, who may edit what, when submit is allowed) is enforced by the database functions of
// migration 0348, so a second client cannot get around them.
import { z } from 'zod';
import taxonomy from '../data/partner-taxonomy.json' with { type: 'json' };
import { piiKey as configPiiKey } from '../config.ts';
import { db, fromDbError, rpc } from '../db.ts';
import { HttpError } from '../http.ts';
import { requireUser } from '../staff.ts';

const BUCKET = 'partner-documents';
const MAX_BYTES = 5 * 1024 * 1024;
const EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png' };
const KINDS = ['pan_copy', 'business_proof', 'food_license'] as const;

/** Who is calling. Any signed-in person; no store or role is needed yet. */
export const applicant = (request: Request): Promise<string> => requireUser(request, 'onboarding');

// Encrypts PAN and the bank account number inside the database. The key lives only on this server.
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

// ---------- the lists the screens show ----------

type Family = { name: string; categories: { name: string; subcategories: string[] }[] };
const families = (taxonomy as unknown as { store: { families: Family[] } }).store.families;
const restaurantTypes = (taxonomy as unknown as { restaurant: { types: { name: string }[] } }).restaurant.types.map(t => t.name);
const serviceCategories = (taxonomy as unknown as { service: { categories: { name: string; subcategories: string[] }[] } }).service.categories;

const STATES = ['Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh', 'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh', 'Jharkhand', 'Karnataka', 'Kerala',
  'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram', 'Nagaland', 'Odisha', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu', 'Telangana', 'Tripura',
  'Uttar Pradesh', 'Uttarakhand', 'West Bengal', 'Andaman and Nicobar Islands', 'Chandigarh', 'Dadra and Nagar Haveli and Daman and Diu', 'Delhi', 'Jammu and Kashmir',
  'Ladakh', 'Lakshadweep', 'Puducherry'];
const BANKS = ['State Bank of India', 'HDFC Bank', 'ICICI Bank', 'Axis Bank', 'Kotak Mahindra Bank', 'Punjab National Bank', 'Bank of Baroda', 'Canara Bank', 'Union Bank of India',
  'Bank of India', 'Bank of Maharashtra', 'Central Bank of India', 'Indian Bank', 'IndusInd Bank', 'Yes Bank', 'IDFC FIRST Bank', 'Federal Bank', 'UCO Bank',
  'Indian Overseas Bank', 'South Indian Bank', 'Karnataka Bank', 'Other'];

export function lists() {
  return {
    store: families.flatMap(f => f.categories.map(c => ({ family: f.name, name: c.name, subcategories: c.subcategories }))),
    restaurant: { categories: restaurantTypes },
    service: { categories: serviceCategories.map(c => ({ name: c.name, subcategories: c.subcategories })) },
    states: STATES,
    banks: BANKS,
    account_types: [{ id: 'savings', title: 'Savings account' }, { id: 'current', title: 'Current account' }],
    document_kinds: KINDS,
    upload: { max_bytes: MAX_BYTES, types: Object.keys(EXT) },
  };
}

// ---------- reading ----------

export const getApplication = (userId: string) => rpc<Record<string, unknown>>('partner_app_get', { p_user_id: userId });

// ---------- sections ----------

const Profile = z.object({
  partner_type: z.enum(['store', 'restaurant', 'service'], { message: 'Choose Restaurant, Store or Service.' }),
  business_name: text(120, 'Enter your shop name.', 2),
  owner_name: text(120, "Enter the owner's full name.", 2),
  phone: z.string({ message: 'Enter a 10-digit mobile number.' }).transform(s => s.replace(/\D/g, '').replace(/^(91|0)(?=[6-9]\d{9}$)/, '')).pipe(z.string().regex(/^[6-9]\d{9}$/, 'Enter a 10-digit mobile number.')),
  email: z.string().trim().toLowerCase().email('That email looks wrong.').max(200).optional().or(z.literal('')),
  selling_mode: z.enum(['physical', 'online_or_both'], { message: 'Choose how you sell.' }),
  category: text(80, 'Choose your category.').optional(),
  subcategory: text(80, 'Choose your subcategory.').optional(),
  specialty: text(80, 'Subcategory is too long.').optional().or(z.literal('')),
});

export async function saveProfile(userId: string, raw: unknown) {
  const b = parse(Profile, raw);
  let family: string | null = null, category: string | null = null, subs: string[] = [];
  if (b.partner_type === 'restaurant') {
    if (!b.category) throw new HttpError(400, 'Choose your category.', undefined, 'validation');
    if (!restaurantTypes.includes(b.category)) throw new HttpError(400, 'Choose your category from the list.', undefined, 'validation');
    category = b.category; subs = [b.category];
  } else if (b.partner_type === 'store') {
    const found = families.flatMap(f => f.categories.map(c => ({ f, c }))).find(x => x.c.name === b.category);
    if (!b.category) throw new HttpError(400, 'Choose your category.', undefined, 'validation');
    if (!found) throw new HttpError(400, 'Choose your category from the list.', undefined, 'validation');
    if (!b.subcategory) throw new HttpError(400, 'Choose your subcategory.', undefined, 'validation');
    if (!found.c.subcategories.includes(b.subcategory)) throw new HttpError(400, 'Choose your subcategory from the list.', undefined, 'validation');
    family = found.f.name; category = found.c.name; subs = [b.subcategory];
  } else {
    if (!b.category) throw new HttpError(400, 'Choose your service.', undefined, 'validation');
    if (!serviceCategories.some(c => c.name === b.category)) throw new HttpError(400, 'Choose your service from the list.', undefined, 'validation');
    category = b.category;
  }
  return rpc('partner_app_save_profile', { p_user_id: userId, p: {
    partner_type: b.partner_type, business_name: b.business_name, owner_name: b.owner_name, phone: b.phone, email: b.email || '',
    selling_mode: b.selling_mode, category_family: family, category, subcategories: subs, specialty: b.specialty || '' } });
}

export async function choosePlan(userId: string, raw: unknown) {
  const b = parse(z.object({ plan: z.enum(['pos_and_onelocal', 'onelocal_app'], { message: 'Choose how you want to sell.' }) }), raw);
  return rpc('partner_app_choose_plan', { p_user_id: userId, p_plan: b.plan });
}

const Address = z.object({
  address_line: text(200, 'Enter your address line.', 3),
  locality: text(100, 'Enter your area or locality.', 2),
  city: text(80, 'Enter your city.', 2),
  state: z.string({ message: 'Choose your state.' }).refine(s => STATES.includes(s), 'Choose your state from the list.'),
  pin_code: z.string({ message: 'PIN code must be 6 digits.' }).regex(/^[1-9][0-9]{5}$/, 'PIN code must be 6 digits.'),
  lat: z.number().min(-90).max(90).nullish(),
  lng: z.number().min(-180).max(180).nullish(),
  confirmed: z.literal(true, { message: 'Confirm that the address identifies your business.' }),
});
export async function saveAddress(userId: string, raw: unknown) {
  const b = parse(Address, raw);
  return rpc('partner_app_save_address', { p_user_id: userId, p: b });
}

const Tax = z.object({
  // Empty is allowed: a PAN already saved cannot be shown again, so the person may leave it blank and the database keeps it
  // (and refuses a first save with none).
  // Empty or missing means "keep the PAN already saved"; the database refuses it when none was ever saved.
  pan: z.string().trim().toUpperCase().regex(/^([A-Z]{5}[0-9]{4}[A-Z])?$/, 'PAN looks wrong. It has 5 letters, 4 digits and 1 letter.').optional(),
  gst_registered: z.boolean({ message: 'Tell us whether your business is GST-registered.' }),
  gstin: z.string().trim().toUpperCase().optional().or(z.literal('')),
});
export async function saveTax(userId: string, raw: unknown) {
  const b = parse(Tax, raw);
  return rpc('partner_app_save_tax', { p_user_id: userId, p: b, p_key: piiKey() });
}

const Identity = z.object({
  consent: z.literal(true, { message: 'Please consent to the use of your details for verification.' }),
  aadhaar_last4: z.string().regex(/^[0-9]{4}$/, 'Enter only the last 4 digits of your Aadhaar. Never share the full number.').optional().or(z.literal('')),
  business_structure: text(60, 'Business type is too long.').optional(),
});
export async function saveIdentity(userId: string, raw: unknown) {
  return rpc('partner_app_save_identity', { p_user_id: userId, p: parse(Identity, raw) });
}

const Bank = z.object({
  holder_name: z.string().optional(), bank_name: z.string().optional(), account_number: z.string().optional(),
  confirm_account_number: z.string().optional(), ifsc: z.string().trim().toUpperCase().optional(),
  account_type: z.enum(['savings', 'current']).optional(), authorised: z.boolean().optional(), draft: z.boolean().optional(),
});
export async function saveBank(userId: string, raw: unknown) {
  const b = parse(Bank, raw);
  const { draft, ...fields } = b;
  return rpc('partner_app_save_bank', { p_user_id: userId, p: fields, p_key: piiKey(), p_draft: draft === true });
}

const Consents = z.object({
  service_terms: z.boolean(), privacy_notice: z.boolean(), marketing_updates: z.boolean().optional(),
});
export async function saveConsents(userId: string, raw: unknown) {
  return rpc('partner_app_save_consents', { p_user_id: userId, p: parse(Consents, raw) });
}

export async function acceptAgreement(userId: string, raw: unknown) {
  const b = parse(z.object({ version: z.string().min(1).max(40), acknowledged: z.boolean() }), raw);
  return rpc('partner_app_accept_agreement', { p_user_id: userId, p_version: b.version, p_ack: b.acknowledged });
}

export const submit = (userId: string) => rpc('partner_app_submit', { p_user_id: userId });

// ---------- documents ----------
// Two steps, like the rider uploads: ask for a private slot, the phone sends the bytes to it, then confirm. The database
// function attaches the file only when the path is inside this person's own application folder.

const UploadAsk = z.object({
  kind: z.enum(KINDS, { message: 'Unknown document type.' }),
  content_type: z.string().refine(t => t in EXT, 'Upload a PDF, JPG or PNG.'),
  size: z.number().int().min(1, 'That file is empty.').max(MAX_BYTES, 'Each file can be up to 5 MB.'),
  file_name: text(200, 'The file needs a name.'),
});

async function applicationId(userId: string): Promise<string> {
  const g = await getApplication(userId) as { exists?: boolean; application?: { id: string; status: string } };
  if (!g.exists || !g.application) throw new HttpError(404, 'Start your application first.', undefined, 'not_found');
  if (g.application.status !== 'draft') throw new HttpError(409, 'Your application has already been submitted.', undefined, 'wrong_state');
  return g.application.id;
}

export async function askUpload(userId: string, raw: unknown) {
  const b = parse(UploadAsk, raw);
  const appId = await applicationId(userId);
  const path = `${appId}/${b.kind}/${crypto.randomUUID()}.${EXT[b.content_type]}`;
  const signed = await db().storage.from(BUCKET).createSignedUploadUrl(path);
  if (signed.error || !signed.data) { console.error('[onboarding] signed upload failed', signed.error?.message); throw new HttpError(502, 'Uploads are not available right now.'); }
  return { path, upload_url: signed.data.signedUrl, max_bytes: MAX_BYTES };
}

export async function confirmUpload(userId: string, raw: unknown) {
  const b = parse(UploadAsk.extend({ path: z.string().min(5).max(300) }), raw);
  const appId = await applicationId(userId);
  if (!b.path.startsWith(`${appId}/${b.kind}/`)) throw new HttpError(400, 'That file does not belong to your application.', undefined, 'validation');
  const info = await db().storage.from(BUCKET).info(b.path);
  if (info.error || !info.data) throw new HttpError(422, 'The file has not finished uploading.', undefined, 'upload_missing');
  const size = Number(info.data.size ?? 0);
  if (size < 1) { await db().storage.from(BUCKET).remove([b.path]); throw new HttpError(422, 'That file is empty.', undefined, 'validation'); }
  if (size > MAX_BYTES) { await db().storage.from(BUCKET).remove([b.path]); throw new HttpError(422, 'Each file can be up to 5 MB.', undefined, 'validation'); }
  const res = await rpc<Record<string, unknown>>('partner_app_attach_document', {
    p_user_id: userId, p_kind: b.kind, p_path: b.path, p_name: b.file_name, p_mime: b.content_type, p_size: size });
  const replaced = res.replaced_path as string | null | undefined;
  if (replaced) await db().storage.from(BUCKET).remove([replaced]);       // the old copy is not kept
  delete res.replaced_path;
  return res;
}

export async function previewUrl(userId: string, kind: string) {
  if (!(KINDS as readonly string[]).includes(kind)) throw new HttpError(400, 'Unknown document type.', undefined, 'validation');
  const path = await rpc<string>('partner_app_document_path', { p_user_id: userId, p_kind: kind });
  const signed = await db().storage.from(BUCKET).createSignedUrl(path, 300);
  if (signed.error || !signed.data) throw new HttpError(502, 'The preview is not available right now.');
  return { url: signed.data.signedUrl, expires_in: 300 };
}

export { fromDbError };
