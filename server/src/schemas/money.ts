// Request shapes for the money functions (database: migration 0435, section K). A friendly first check of the shape of the request; every rule
// (organisation, location, permission, amounts, state) is checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'The date must look like 2026-10-17.');
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ location_id: id.nullish(), ...shape }).loose();
const window = { period: z.enum(['today', 'week', 'month', 'all'], { message: 'Unknown period.' }).optional(), from: day.optional(), to: day.optional() };
const page = { page: z.number().int().min(1).max(10_000).optional(), page_size: z.number().int().min(1).max(50).optional() };
const amount = z.number({ message: 'Enter an amount.' }).int('Enter whole paise.').min(1, 'Enter an amount greater than zero.').max(99_999_999_999, 'That amount is too large.');
const method = z.enum(['cash', 'upi', 'card', 'bank', 'other'], { message: 'Unknown payment method.' });

export const Options = obj({});
export const Window = obj({ ...window });
export const Day = obj({ day: day.optional() });
export const IdOnly = z.object({ id }).loose();
export const Payments = obj({ ...window, ...page, method: z.string().max(20).optional(), status: z.string().max(20).optional() });
export const Transactions = obj({ ...window, ...page, type: z.string().max(20).optional(), status: z.string().max(20).optional(), q: z.string().max(100).optional(), party: z.string().max(60).optional() });
export const Invoices = obj({ ...window, ...page, kind: z.string().max(20).optional(), payment: z.string().max(20).optional(), q: z.string().max(100).optional() });
export const Expenses = obj({ day: day.optional(), category: z.string().max(40).optional() });
export const Refunds = obj({ ...window, ...page, kind: z.string().max(20).optional() });
export const Settlements = z.object({ month: z.string().regex(/^\d{4}-\d{2}$/, 'The month must look like 2026-10.').optional(), status: z.string().max(20).optional() }).loose();
export const Payouts = z.object({ month: z.string().regex(/^\d{4}-\d{2}$/, 'The month must look like 2026-10.').optional(), recipient: z.string().max(20).optional(), status: z.string().max(20).optional() }).loose();
export const ReportRows = obj({ ...window, report: z.string({ message: 'Choose a report.' }).min(1).max(40) });
export const ExpenseRecord = obj({ category: z.string().trim().min(1, 'Choose a category.').max(40), title: z.string().trim().min(1, 'Describe the expense.').max(80), amount_minor: amount, method: method.optional(),
  expense_date: day.optional(), note: z.string().max(300).optional(), ...key });
export const Void = z.object({ id, note: z.string().trim().min(3, 'Say why (3 to 200 characters).').max(200), ...key }).loose();
export const CashRecord = obj({ direction: z.enum(['in', 'out'], { message: 'Choose Cash In or Cash Out.' }), title: z.string().trim().min(1, 'Describe the entry.').max(80), amount_minor: amount,
  category: z.string().max(40).optional(), entry_date: day.optional(), note: z.string().max(300).optional(), ...key });
export const PartyRecord = obj({ party_name: z.string().trim().min(1, 'Enter a name.').max(60), direction: z.enum(['gave', 'got'], { message: 'Choose You gave or You got.' }), amount_minor: amount,
  method: z.enum(['cash', 'upi', 'card', 'bank', 'other', 'unspecified']).optional(), entry_date: day.optional(), note: z.string().max(300).optional(), ...key });
export const AdjustmentRequest = obj({ order_id: id.nullish(), kind: z.enum(['price_correction', 'fee_reversal', 'discount', 'other']).optional(), reason: z.string().trim().min(3, 'Say why (3 to 200 characters).').max(200),
  amount_minor: z.number().int().refine(n => n !== 0 && Math.abs(n) < 100_000_000_000, 'Enter an amount.'), ...key });
export const AdjustmentDecide = z.object({ id, decision: z.enum(['approve', 'reject'], { message: 'Choose approve or reject.' }), note: z.string().max(300).optional(), ...key }).loose();
export const InvoicePay = z.object({ invoice_id: id, amount_minor: amount, method: method.optional(), paid_on: day.optional(), note: z.string().max(300).optional(), ...key }).loose();
export const InvoiceDue = z.object({ invoice_id: id, due_date: day }).loose();
