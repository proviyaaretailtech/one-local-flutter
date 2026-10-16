// Request shapes for the setup functions (database: migration 0350 behind the 0360 gw_ wrappers). Same split as onboarding: a friendly
// first check here, every rule again in the database.
import { z } from 'zod';
import { amount, clean, hhmm, text } from '../validate.ts';

export const IMAGE_KINDS = ['logo', 'cover'] as const;
export const IMAGE_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png' };
export const IMAGE_MAX_BYTES = 5 * 1024 * 1024;

export const ConfirmPlan = z.object({ plan_code: z.string().trim().max(60).nullish() });

export const Payment = z.object({
  holder_name: text(120, 'Enter the name as on the bank account.', 2),
  bank_name: z.string().transform(clean).pipe(z.string().max(100, 'Bank name is too long.')).optional(),
  // Empty means "keep the saved account" (or the one from the application); the database refuses it when there is none.
  account_number: z.string().transform(s => s.replace(/\s/g, '')).pipe(z.string().regex(/^(\d{9,18})?$/, 'Account number must be 9 to 18 digits.')).optional(),
  ifsc: z.string().trim().toUpperCase().regex(/^([A-Z]{4}0[A-Z0-9]{6})?$/, 'IFSC looks wrong. It has 4 letters, a zero and 6 characters.').optional(),
  accept_upi: z.boolean().default(false),
  accept_card: z.boolean().default(false),
  upi_id: z.string().trim().toLowerCase().max(130).optional(),
});

export const Tax = z.object({
  gst_registered: z.boolean({ message: 'Tell us whether your business is GST-registered.' }),
  gstin: z.string().trim().toUpperCase().optional(),
  invoice_prefix: z.string().trim().toUpperCase().max(6, 'Invoice prefix can have up to 6 letters or digits.').optional(),
  prices_include_tax: z.boolean({ message: 'Choose whether your prices include tax.' }),
  show_address_on_receipt: z.boolean().optional(),
  show_gstin_on_invoice: z.boolean().optional(),
});

export const Pos = z.object({
  device_name: text(60, 'Give this POS device a name.', 2),
  peripherals: z.array(z.enum(['receipt_printer', 'scanner', 'kot_printer'], { message: 'Unknown peripheral.' })).max(3).default([]),
  connection: z.enum(['bluetooth', 'usb', 'lan'], { message: 'Choose Bluetooth, USB or network for your peripherals.' }).optional(),
});

export const Staff = z.object({
  name: text(120, "Enter the staff member's name.", 2),
  email: z.string({ message: 'Enter a valid email for the invite.' }).trim().toLowerCase().email('Enter a valid email for the invite.').max(200),
  role: z.enum(['cashier', 'manager', 'kitchen'], { message: 'Choose a role.' }),
  permissions: z.array(z.enum(['billing.collect', 'catalogue.view', 'refunds.manage', 'settings.manage'], { message: 'Unknown permission.' })).max(4).default([]),
});

export const Item = z.object({
  name: text(120, 'Enter the item name.', 2),
  category: text(60, 'Enter a category.', 2),
  price: z.union([z.number(), z.string().trim().regex(/^\d+(\.\d{1,2})?$/, 'Enter a selling price above zero.').transform(Number)], { message: 'Enter a selling price above zero.' })
    .refine(n => n > 0 && n <= 1_000_000, 'Enter a selling price above zero.'),
  food_type: z.enum(['veg', 'non_veg', 'egg']).optional(),
});

export const Listing = z.object({
  public_name: text(80, 'Enter your public business name.', 2),
  description: z.string({ message: 'Tell customers what you sell in 10 to 500 characters.' }).trim()
    .min(10, 'Tell customers what you sell in 10 to 500 characters.').max(500, 'Tell customers what you sell in 10 to 500 characters.'),
  address_line: text(250, 'Enter the address customers should see.', 5),
  open_days: z.array(z.number().int().min(1).max(7), { message: 'Select the days you are open.' }).min(1, 'Select the days you are open.').max(7),
  opens_at: hhmm('Choose an opening time.'),
  closes_at: hhmm('Choose a closing time.'),
});

export const Fulfilment = z.object({
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

export const Tour = z.object({ step: z.number().int().min(1).max(10) });

export const ImageAsk = z.object({
  kind: z.enum(IMAGE_KINDS, { message: 'Unknown image type.' }),
  content_type: z.string().refine(t => t in IMAGE_EXT, 'Upload a JPG or PNG.'),
  size: z.number().int().min(1, 'That file is empty.').max(IMAGE_MAX_BYTES, 'Each image can be up to 5 MB.'),
});
export const ImageAttach = ImageAsk.extend({ path: z.string().min(5).max(300) });
