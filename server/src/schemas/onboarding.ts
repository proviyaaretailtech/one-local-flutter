// Request shapes for the onboarding functions (database: migration 0348 behind the 0360 gw_ wrappers). A first check of each answer
// so the app gets a friendly sentence; the database functions enforce every rule again, so a second client cannot get around them.
import { z } from 'zod';
import taxonomy from '../data/partner-taxonomy.json' with { type: 'json' };
import { HttpError } from '../http.ts';
import { clean, parse, text } from '../validate.ts';

export const MAX_BYTES = 5 * 1024 * 1024;
export const EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png' };
export const KINDS = ['pan_copy', 'business_proof', 'food_license'] as const;

type Family = { name: string; categories: { name: string; subcategories: string[] }[] };
const families = (taxonomy as unknown as { store: { families: Family[] } }).store.families;
const restaurantTypes = (taxonomy as unknown as { restaurant: { types: { name: string }[] } }).restaurant.types.map(t => t.name);
const serviceCategories = (taxonomy as unknown as { service: { categories: { name: string; subcategories: string[] }[] } }).service.categories;

export const STATES = ['Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh', 'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh', 'Jharkhand', 'Karnataka', 'Kerala',
  'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram', 'Nagaland', 'Odisha', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu', 'Telangana', 'Tripura',
  'Uttar Pradesh', 'Uttarakhand', 'West Bengal', 'Andaman and Nicobar Islands', 'Chandigarh', 'Dadra and Nagar Haveli and Daman and Diu', 'Delhi', 'Jammu and Kashmir',
  'Ladakh', 'Lakshadweep', 'Puducherry'];
const BANKS = ['State Bank of India', 'HDFC Bank', 'ICICI Bank', 'Axis Bank', 'Kotak Mahindra Bank', 'Punjab National Bank', 'Bank of Baroda', 'Canara Bank', 'Union Bank of India',
  'Bank of India', 'Bank of Maharashtra', 'Central Bank of India', 'Indian Bank', 'IndusInd Bank', 'Yes Bank', 'IDFC FIRST Bank', 'Federal Bank', 'UCO Bank',
  'Indian Overseas Bank', 'South Indian Bank', 'Karnataka Bank', 'Other'];

/** The lists the screens show (static, no database). */
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

export const Profile = z.object({
  partner_type: z.enum(['store', 'restaurant', 'service'], { message: 'Choose Restaurant, Store or Service.' }),
  business_name: text(120, 'Enter your shop name.', 2),
  owner_name: text(120, "Enter the owner's full name.", 2),
  phone: z.string({ message: 'Enter a 10-digit mobile number.' }).transform(s => s.replace(/\D/g, '').replace(/^(91|0)(?=[6-9]\d{9}$)/, '')).pipe(z.string().regex(/^[6-9]\d{9}$/, 'Enter a 10-digit mobile number.')),
  email: z.string().trim().toLowerCase().email('That email looks wrong.').max(200).optional().or(z.literal('')),
  selling_mode: z.enum(['physical', 'online_or_both'], { message: 'Choose how you sell.' }),
  category: text(80, 'Choose your category.').optional(),
  categories: z.array(text(80, 'Choose your cuisines.')).max(30, 'Too many cuisines.').optional(), // restaurant: every cuisine it serves
  subcategory: text(80, 'Choose your subcategory.').optional(),
  specialty: text(80, 'Subcategory is too long.').optional().or(z.literal('')),
});

/** The profile the database stores: the picked category checked against the lists and split into family, category, subcategories. */
export function profileArgs(b: z.infer<typeof Profile>) {
  let family: string | null = null, category: string | null = null, subs: string[] = [];
  const bad = (m: string) => new HttpError(400, m, undefined, 'validation');
  if (b.partner_type === 'restaurant') {
    // A restaurant can serve several cuisines; the first one picked is its main category. An older app sends just `category`.
    const picked = [...new Set(b.categories?.length ? b.categories : b.category ? [b.category] : [])];
    if (picked.length === 0) throw bad('Choose the cuisines you serve.');
    if (picked.some(c => !restaurantTypes.includes(c))) throw bad('Choose your cuisines from the list.');
    category = picked[0]; subs = picked;
  } else if (b.partner_type === 'store') {
    const found = families.flatMap(f => f.categories.map(c => ({ f, c }))).find(x => x.c.name === b.category);
    if (!b.category) throw bad('Choose your category.');
    if (!found) throw bad('Choose your category from the list.');
    if (!b.subcategory) throw bad('Choose your subcategory.');
    if (!found.c.subcategories.includes(b.subcategory)) throw bad('Choose your subcategory from the list.');
    family = found.f.name; category = found.c.name; subs = [b.subcategory];
  } else {
    if (!b.category) throw bad('Choose your service.');
    if (!serviceCategories.some(c => c.name === b.category)) throw bad('Choose your service from the list.');
    category = b.category;
  }
  return { partner_type: b.partner_type, business_name: b.business_name, owner_name: b.owner_name, phone: b.phone, email: b.email || '',
    selling_mode: b.selling_mode, category_family: family, category, subcategories: subs, specialty: b.specialty || '' };
}

export const Plan = z.object({ plan: z.enum(['pos_and_onelocal', 'onelocal_app'], { message: 'Choose how you want to sell.' }) });

export const Address = z.object({
  address_line: text(200, 'Enter your address line.', 3),
  locality: text(100, 'Enter your area or locality.', 2),
  city: text(80, 'Enter your city.', 2),
  state: z.string({ message: 'Choose your state.' }).refine(s => STATES.includes(s), 'Choose your state from the list.'),
  pin_code: z.string({ message: 'PIN code must be 6 digits.' }).regex(/^[1-9][0-9]{5}$/, 'PIN code must be 6 digits.'),
  lat: z.number().min(-90).max(90).nullish(),
  lng: z.number().min(-180).max(180).nullish(),
  confirmed: z.literal(true, { message: 'Confirm that the address identifies your business.' }),
});

// Empty or missing PAN means "keep the PAN already saved"; the database refuses it when none was ever saved.
export const Tax = z.object({
  pan: z.string().trim().toUpperCase().regex(/^([A-Z]{5}[0-9]{4}[A-Z])?$/, 'PAN looks wrong. It has 5 letters, 4 digits and 1 letter.').optional(),
  gst_registered: z.boolean({ message: 'Tell us whether your business is GST-registered.' }),
  gstin: z.string().trim().toUpperCase().optional().or(z.literal('')),
});

export const Identity = z.object({
  consent: z.literal(true, { message: 'Please consent to the use of your details for verification.' }),
  aadhaar_last4: z.string().regex(/^[0-9]{4}$/, 'Enter only the last 4 digits of your Aadhaar. Never share the full number.').optional().or(z.literal('')),
  business_structure: text(60, 'Business type is too long.').optional(),
});

export const Bank = z.object({
  holder_name: z.string().optional(), bank_name: z.string().optional(), account_number: z.string().optional(),
  confirm_account_number: z.string().optional(), ifsc: z.string().trim().toUpperCase().optional(),
  account_type: z.enum(['savings', 'current']).optional(), authorised: z.boolean().optional(), draft: z.boolean().optional(),
});

export const Consents = z.object({ service_terms: z.boolean(), privacy_notice: z.boolean(), marketing_updates: z.boolean().optional() });
export const Agreement = z.object({ version: z.string().min(1).max(40), acknowledged: z.boolean() });

export const UploadAsk = z.object({
  kind: z.enum(KINDS, { message: 'Unknown document type.' }),
  content_type: z.string().refine(t => t in EXT, 'Upload a PDF, JPG or PNG.'),
  size: z.number().int().min(1, 'That file is empty.').max(MAX_BYTES, 'Each file can be up to 5 MB.'),
  file_name: text(200, 'The file needs a name.'),
});
export const Attach = UploadAsk.extend({ path: z.string().min(5).max(300) });
export const PreviewAsk = z.object({ kind: z.enum(KINDS, { message: 'Unknown document type.' }) });

export { clean, parse };
