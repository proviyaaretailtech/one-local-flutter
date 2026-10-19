// Request shape for the restaurant dashboard (database: migration 0491). A friendly first check; the organisation, outlet and role
// are checked again in the database.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
export const Dashboard = z.object({ location_id: id.nullish() }).loose();

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
export const BillNote = obj({ order_id: id, note: z.string().max(300, 'A note can be up to 300 characters.').nullish() });
export const ReceiptLog = obj({
  order_id: id, channel: z.enum(['print', 'whatsapp', 'sms', 'email'], { message: 'Print, WhatsApp, SMS or email.' }),
  to: z.string().trim().max(200).nullish(),
});
