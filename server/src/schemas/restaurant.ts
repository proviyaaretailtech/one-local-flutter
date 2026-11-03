// Request shape for the restaurant dashboard (database: migration 0491). A friendly first check; the organisation, outlet and role
// are checked again in the database.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
export const Dashboard = z.object({ location_id: id.nullish() }).loose();
// 0524: the restaurant home for one outlet or 'all' (summed over the outlets the person may see)
export const DashboardScope = z.object({ location_id: z.union([id, z.literal('all')]).nullish() }).loose();
// The KOT view (0609): today's kitchen orders, one card each; status all / preparing / ready / completed.
export const KotOrders = z.object({ location_id: z.union([id, z.literal('all')]).nullish(), status: z.enum(['all', 'preparing', 'ready', 'completed', 'cancelled'], { message: 'Unknown status.' }).optional() }).loose();

// Restaurant menu and dish detail (database: migrations 0540-0541). Every rule (menu.update, windows, 500-character description, stale
// version, tenancy, rate limit) is checked again in the database.
const hhmm = z.string().regex(/^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$/, 'Use a time like 09:30.');
const Window = z.object({
  slot: z.enum(['morning', 'evening', 'night', 'custom'], { message: 'Availability is morning, evening, night or custom.' }),
  starts_at: hhmm.nullish(), ends_at: hhmm.nullish(), days: z.array(z.number().int().min(1).max(7)).max(7).nullish(),
}).strict();
export const Menu = z.object({
  location_id: id.nullish(), q: z.string().max(60).nullish(), filter: z.enum(['all', 'in_stock', 'out_of_stock', 'needs_image']).optional(),
}).strict();
export const MenuItemView = z.object({ id, location_id: id.nullish() }).strict();
export const MenuItemSave = z.object({
  id, version: z.number().int().min(1), location_id: id.nullish(), description: z.string().max(500, 'A description is up to 500 characters.').nullish(),
  food_type: z.enum(['veg', 'non_veg', 'egg']).optional(), availability: z.array(Window).max(6, 'Up to 6 serving windows per dish.').optional(),
}).strict();
export const MenuStockSet = z.object({ id: id.optional(), category_id: id.optional(), in_stock: z.boolean() }).strict()
  .refine(b => !!b.id !== !!b.category_id, { message: 'Choose one dish or one category.' });
// Write with AI: the owner's notes are capped here and again in the handler; the dish facts come from the database.
export const AiDescribe = z.object({ item_id: id, notes: z.string().max(1000, 'Notes are up to 1000 characters.').optional() }).strict();

// Restaurant bill and pay (database: migration 0550). The amounts of a split, the coupon rules, the roles and every state are worked out
// and checked again in the database; these are only shape checks. Extra keys are kept (`loose`).
const key = { idempotency_key: z.string().trim().max(90, 'The idempotency key is too long.').optional() };
const money = z.number({ message: 'Enter an amount.' }).positive('Enter an amount above zero.').max(1_000_000, 'The amount is too large.');
const method = z.enum(['cash', 'card', 'upi'], { message: 'Choose cash, card or UPI.' });
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
export const BillView = obj({ location_id: id.nullish(), table_id: id });
export const BillOrder = obj({ order_id: id });
export const BillSplit = obj({
  order_id: id,
  mode: z.enum(['equal', 'item', 'amount'], { message: 'Split equally, by item or by amount.' }),
  guests: z.number().int().min(2, 'Split between 2 and 20 guests.').max(20, 'Split between 2 and 20 guests.').optional(),
  parts: z.array(obj({
    label: z.string().trim().max(40, 'A guest name can be up to 40 characters.').nullish(),
    method: method.optional(),
    amount: money.optional(),
    item_ids: z.array(id).max(100).optional(),
  })).max(20, 'Split between 2 and 20 guests.').optional(),
  ...key,
});
export const BillPay = obj({
  order_id: id, part_id: id.nullish(), method, tendered: money.nullish(),
  reference: z.string().trim().max(80, 'The reference can be up to 80 characters.').nullish(), expected_updated_at: z.string().max(40).nullish(), ...key,
});
export const BillCoupon = obj({ order_id: id, code: z.string({ message: 'Enter a discount code.' }).trim().regex(/^[A-Za-z0-9_-]{3,20}$/, 'This coupon code is not valid.') });
// 0637: a manual discount at checkout: ₹ or %, with a reason (0 takes it off); the limit and the approval are the database's
export const BillDiscount = obj({ order_id: id, kind: z.enum(['amount', 'percent'], { message: 'Choose ₹ or %.' }),
  value: z.number({ message: 'Enter the discount.' }).min(0, 'Enter the discount.').max(1_000_000, 'That discount is too large.'),
  reason: z.string().trim().max(120, 'Keep the reason under 120 characters.').optional() })
  .refine(b => b.kind !== 'percent' || b.value <= 100, { message: 'A percentage is at most 100.', path: ['value'] });
export const BillNote = obj({ order_id: id, note: z.string().max(300, 'A note can be up to 300 characters.').nullish() });
// 0640: cancel dishes (all of a line or part of it), refund and void a bill, and the manager's approval of what a cashier asked. Who may do
// what, the amounts and every state are the database's.
const reason = (max: number) => z.string({ message: 'Say why.' }).trim().min(3, 'Say why (3 characters or more).').max(max, `Keep the reason under ${max} characters.`);
const back = z.enum(['cash', 'upi', 'card', 'other'], { message: 'Choose how the money goes back.' });
export const ItemsCancel = obj({
  order_id: id,
  items: z.array(obj({ item_id: id, qty: z.number().int('Cancel whole dishes.').min(1, 'Cancel at least one.').max(999) }))
    .min(1, 'Choose a dish to cancel.').max(50, 'At most 50 dishes at a time.'),
  reason: reason(200), ...key,
});
export const BillRefund = obj({ order_id: id, amount: money, method: back, reason: reason(300), ...key });
export const BillVoid = obj({ order_id: id, method: back.nullish(), reason: reason(200), ...key });
export const RequestsList = obj({ order_id: id.nullish() });
// 0643: a takeaway or delivery order held on the floor sent to the kitchen from Orders → Hold
export const HoldSend = obj({ order_id: id, ...key });
export const RequestDecide = obj({ request_id: id, decision: z.enum(['approve', 'reject'], { message: 'Approve or reject.' }),
  note: z.string().trim().max(200, 'Keep the note under 200 characters.').nullish() });
export const ReceiptLog = obj({
  order_id: id, channel: z.enum(['print', 'whatsapp', 'sms', 'email'], { message: 'Print, WhatsApp, SMS or email.' }),
  to: z.string().trim().max(200).nullish(),
});
// The Activity log in Settings (0614): every order's operational timeline, newest first; 'before' pages back to older entries.
export const ActivityLog = z.object({
  location_id: z.union([id, z.literal('all')]).nullish(),
  before: z.string().datetime({ offset: true, message: 'Not a valid time.' }).nullish(),
  limit: z.number().int().min(1).max(100).optional(),
}).loose();

// 0638: Devices (printers) for the restaurant; every rule (who, IP address, defaults) is checked again in the database
export const DevicesList = obj({});
export const PrinterSave = obj({ id: id.nullish(), location_id: id.nullish(), name: z.string().trim().min(1, 'Give the printer a name.').max(40, 'The name can be up to 40 letters.'),
  type: z.enum(['receipt', 'kot', 'label'], { message: 'Choose what it prints.' }), connection: z.enum(['lan', 'usb', 'bluetooth', 'system'], { message: 'Choose how it connects.' }),
  address: z.string().trim().max(60).nullish(), model: z.string().trim().max(40).nullish(), paper_mm: z.union([z.literal(58), z.literal(80)]).optional(),
  label_size: z.enum(['38x25', '50x25', '50x30', '75x50', '100x50']).nullish(), copies: z.number().int().min(1).max(5).optional(),
  auto_cut: z.boolean().optional(), is_default: z.boolean().optional() });
export const PrinterId = obj({ id });
