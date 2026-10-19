// Request shapes for the store cash shift, payment pending and refund check (database: migrations 0500 to 0502). A friendly first check of
// the shape; every rule (organisation, store, role, amounts, one open shift, one pending payment, return window) is checked again in the
// database. Extra keys are kept (`loose`) because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const cash = z.number({ message: 'Enter an amount.' }).min(0, 'Enter 0 or more.').max(999_999.99, 'That amount is too large.');
const money = z.number({ message: 'Enter an amount.' }).positive('Enter an amount above zero.').max(999_999.99, 'That amount is too large.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const store = { location_id: id.optional() };

export const Current = obj({ ...store });
export const List = obj({ ...store, limit: z.number().int().min(1).max(100).optional(), before: z.string().max(40).optional() });
export const Open = obj({ ...store, opening_float: cash, ...key });
export const CashMove = obj({ shift_id: id, kind: z.enum(['in', 'out'], { message: 'Cash in or cash out.' }), amount: money, reason: z.string().trim().min(3, 'Give a reason.').max(120), ...key });
export const Close = obj({ shift_id: id, counted_cash: cash, variance_reason: z.string().max(200).optional(), expected_version: z.number().int().min(1).optional(), ...key });
export const Approve = obj({ shift_id: id, note: z.string().trim().min(3, 'Add a note.').max(300) });
export const Policy = obj({ ...store, require_open_shift: z.boolean().optional(), variance_limit: cash.optional(), return_days: z.number().int().min(0).max(365).optional() });

export const PayStart = obj({ order_id: id, method: z.enum(['upi', 'card'], { message: 'A pending payment is UPI or card.' }), ...key });
export const PayConfirm = obj({ intent_id: id, reference: z.string().trim().min(4, 'Enter the reference (4 to 40 characters).').max(40, 'Enter the reference (4 to 40 characters).') });
export const PayFail = obj({ intent_id: id, status: z.enum(['declined', 'failed', 'cancelled'], { message: 'Declined, failed or cancelled.' }).optional(), code: z.string().max(60).optional(), message: z.string().max(200).optional() });
export const PayStatus = obj({ intent_id: id.optional(), order_id: id.optional() }).refine(a => a.intent_id || a.order_id, { message: 'Send the payment or the bill.' });

export const RefundCheck = obj({ order_id: id, purpose: z.enum(['refund', 'return'], { message: 'Refund or return.' }).optional(), amount: money.optional() });
