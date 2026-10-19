// Request shapes for customers, the One Local Wallet and Manage account (database: migrations 0510-0512). A friendly first check; the
// organisation, outlet, role, phone format, duplicates and every money figure are decided again in the database.
// Extra keys are kept (`loose`) because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const page = { limit: z.number().int().min(1).max(100).optional(), offset: z.number().int().min(0).max(100_000).optional() };
const text = (max: number, msg: string) => z.string().max(max, msg);
const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Dates look like 2026-10-20.');

// ---- customers (0510)
export const List = z.object({ q: text(80, 'Search is too long.').optional(), ...page }).loose();
export const Lookup = z.object({ phone: z.string().min(10, 'Enter a 10-digit mobile number.').max(16, 'Enter a 10-digit mobile number.') }).loose();
export const View = z.object({ id }).loose();
export const Save = z.object({
  id: id.nullish(),
  location_id: id.nullish(),
  first_name: z.string().trim().min(1, 'Enter the customer\'s name.').max(80, 'Name is too long.'),
  last_name: text(80, 'Name is too long.').optional(),
  phone: z.string().min(10, 'Enter a 10-digit mobile number.').max(16, 'Enter a 10-digit mobile number.'),
  email: text(200, 'Email is too long.').nullish(),
  gst_number: text(15, 'GSTIN has 15 characters.').nullish(),
  date_of_birth: date.nullish().or(z.literal('')),
  anniversary: date.nullish().or(z.literal('')),
  preferred_dining: z.enum(['dine_in', 'takeaway', 'delivery'], { message: 'Choose dine-in, takeaway or delivery.' }).optional(),
  address: text(500, 'Address is too long.').optional(),
  notes: text(1000, 'Notes are too long.').optional(),
}).loose();
export const Attach = z.object({ order_id: id, customer_id: id.nullish(), walk_in: z.boolean().optional() }).loose()
  .refine(a => Boolean(a.customer_id) !== Boolean(a.walk_in), { message: 'Choose a customer or walk-in.' });

// ---- One Local Wallet (0511)
export const WalletOverview = z.object({}).loose();
export const WalletMovements = z.object({ ...page }).loose();
export const WalletSettlement = z.object({ id }).loose();

// ---- Manage account (0512)
export const SaveName = z.object({ name: z.string().trim().min(2, 'Enter your full name.').max(120, 'Name is too long.') }).loose();
