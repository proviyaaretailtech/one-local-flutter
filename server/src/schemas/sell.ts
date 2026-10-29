// Request shapes for the till functions (database: migrations 0380 to 0383, section F). A friendly first check of the shape; every rule
// (organisation, store, role, amounts, caps, coupon, state) is checked again in the database. Extra keys are kept (`loose`) because the
// database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const text = (n: number) => z.string().max(n);
const money = z.number({ message: 'Enter an amount.' }).positive('Enter an amount above zero.').max(1_000_000);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Dates look like 2026-10-09.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();

export const Catalog = obj({
  q: text(60).optional(), category: text(60).optional(), available: z.boolean().optional(), sort: z.enum(['name', 'price_asc', 'price_desc'], { message: 'Unknown sort.' }).optional(),
});
// bought together (27 Oct 2026): the products in the cart; the database ranks what is bought with them
export const Basket = obj({ item_ids: z.array(id).max(50, 'Too many items.').optional(), limit: z.number().int().min(1).max(40).optional() });
export const SplitPay = obj({
  order_id: id, expected_updated_at: z.string().max(40).optional(),
  payments: z.array(obj({ method: z.enum(['cash', 'card', 'upi'], { message: 'Each part is cash, card or UPI.' }), amount: money, tendered: money.nullish(), reference: text(80).nullish() }))
    .min(2, 'A split payment has 2 to 4 parts.').max(4, 'A split payment has 2 to 4 parts.'),
  ...key,
});
export const Attempt = obj({
  order_id: id, method: z.enum(['cash', 'upi', 'card', 'online'], { message: 'Unknown payment method.' }),
  status: z.enum(['declined', 'failed', 'cancelled'], { message: 'Unknown status.' }).optional(), code: text(60).optional(), message: text(200).optional(),
});
export const OnlineCheckout = obj({ order_id: id });
export const Receipts = obj({
  q: text(60).optional(), status: z.enum(['all', 'paid', 'part_paid', 'unpaid', 'refunded', 'cancelled'], { message: 'Unknown status.' }).optional(),
  from: day.optional(), to: day.optional(), before: z.string().max(40).optional(), limit: z.number().int().min(1).max(100).optional(),
});
export const ReturnList = obj({ status: z.enum(['all', 'requested', 'approved', 'rejected', 'refunded'], { message: 'Unknown status.' }).optional(), q: text(60).optional() });
export const ReturnCreate = obj({
  order_id: id, reason: text(200), note: text(300).optional(),
  lines: z.array(obj({ order_item_id: id, qty: z.number().int().min(1).max(99), restock: z.boolean().optional() })).min(1, 'Choose the items being returned.').max(50), ...key,
});
export const ReturnDecide = obj({ return_id: id, decision: z.enum(['approve', 'reject'], { message: 'Approve or reject.' }), note: text(300).optional() });
export const ReturnRefund = obj({ return_id: id, method: z.enum(['cash', 'upi', 'card', 'other'], { message: 'Choose how the money goes back.' }), ...key });
export const CouponList = obj({});
export const CouponSave = obj({
  code: text(20), label: text(80).optional(), kind: z.enum(['percent', 'flat'], { message: 'Choose percent or flat.' }), value: z.number().positive('Enter a value above zero.'),
  min_order: z.number().min(0).nullish(), max_discount: z.number().positive().nullish(), max_uses: z.number().int().positive().nullish(), max_uses_per_customer: z.number().int().positive().nullish(), active: z.boolean().optional(), starts_at: text(40).nullish(), ends_at: text(40).nullish(),
});
