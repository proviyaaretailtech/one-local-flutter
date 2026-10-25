// Request shapes for the purchasing functions (database: migration 0430, section H purchasing). A friendly first check of the shape of
// the request; every rule (organisation, location, role, state, quantities, money) is checked again in the database. Extra keys are kept
// (`loose`) because the database functions read their own fields from the same object. Money is paise (`*_minor`, whole numbers).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const loc = { location_id: id.nullish() };
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ ...loc, ...shape }).loose();

export const Options = obj({});
export const PoList = obj({
  status: z.enum(['all', 'open', 'pending', 'received'], { message: 'Unknown status filter.' }).optional(),
  due: z.enum(['all', 'open', 'overdue'], { message: 'Unknown due filter.' }).optional(),
  q: z.string().max(100).optional(), limit: z.number().int().min(1).max(50).optional(),
});
export const PoView = obj({ id: id.optional(), number: z.string().trim().min(1).max(40).optional() })
  .refine(v => !!v.id || !!v.number, { message: 'Give the order id or number.' });
export const PoLine = z.object({
  inventory_item_id: id,
  qty: z.number({ message: 'Quantity must be a number.' }).positive('Quantity must be above zero.').max(1_000_000),
  unit_cost_minor: z.number({ message: 'Price must be a number.' }).int('Price must be in whole paise.').min(0).max(100_000_000),
  gst_pct: z.number().min(0, 'GST cannot be negative.').max(100, 'GST cannot be above 100.').optional(),
}).loose();
export const PoCreate = obj({
  supplier_id: z.string({ message: 'Choose a supplier.' }).trim().min(1, 'Choose a supplier.').max(100),
  expected_delivery: z.string().max(40).nullish(), notes: z.string().max(500).nullish(),
  submit: z.boolean().optional(),   // true = Pending (awaiting approval), otherwise a Draft
  lines: z.array(PoLine).min(1, 'Add at least one item.').max(100, 'An order can have at most 100 items.'), ...key,
});
// A supplier added (no id) or changed (id) from Item → Purchase → Suppliers. Only the name is required.
export const SupplierSave = obj({
  id: z.string().trim().min(1).max(100).optional(),
  name: z.string({ message: 'Enter the supplier name.' }).trim().min(2, 'Enter the supplier name.').max(80, 'The supplier name is too long.'),
  phone: z.string().trim().max(16).optional(), gstin: z.string().trim().max(15, 'A GSTIN has 15 letters and numbers.').optional(),
  city: z.string().trim().max(60, 'The city name is too long.').optional(), ...key,
});
export const PoAct = obj({ id, action: z.enum(['submit', 'approve', 'reject', 'cancel'], { message: 'Unknown action.' }), note: z.string().max(200).nullish() });
export const PoReceive = obj({ id, ...key });
export const PriceView = obj({ price_id: id });
export const SourcingSelect = obj({ price_id: id, note: z.string().max(200).nullish(), ...key });
export const AuditRecord = obj({
  price_id: id, ...key,
  checks: z.array(z.object({
    name: z.string().trim().min(1, 'Each check needs a name.').max(80),
    detail: z.string().max(200).optional(),
    result: z.enum(['pass', 'warning', 'fail'], { message: 'Each check is pass, warning or fail.' }),
  }).loose()).min(1, 'Record at least one check.').max(20, 'At most 20 checks.'),
});
