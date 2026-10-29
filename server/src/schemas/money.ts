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

// Restaurant Money in the store's design (0622): the wallet, Money in / out, Transfer, cash register and close, dues, contacts to pay.
const rmAccount = z.enum(['cash', 'upi', 'bank'], { message: 'Choose cash, UPI or bank.' });
export const RmEntries = obj({ direction: z.enum(['in', 'out'], { message: 'Choose money in or money out.' }), method: z.enum(['all', 'cash', 'upi', 'card']).optional(),
  from: day.optional(), to: day.optional() });
export const RmRecord = obj({ direction: z.enum(['in', 'out', 'move'], { message: 'Choose money in, money out or a move.' }), amount_minor: amount,
  kind: z.string().trim().max(40).optional(), category: z.string().max(60).optional(),
  method: z.enum(['cash', 'upi', 'gpay', 'phonepe', 'card', 'bank'], { message: 'Choose how the money moved.' }).optional(),
  party: z.string().max(60).optional(), party_phone: z.string().max(20).optional(), reference: z.string().max(60).optional(), note: z.string().max(300).optional(),
  from_account: rmAccount.optional(), to_account: rmAccount.optional(), entry_date: day.optional(), ...key });
export const RmVoid = z.object({ id, reason: z.string().trim().min(3, 'Say why (3 to 200 characters).').max(200) }).loose();
export const RmClose = obj({ day: day.optional(), counted_minor: z.number({ message: 'Enter the cash you counted.' }).int().min(0).max(99_999_999_999) });
export const RmContacts = z.object({ q: z.string().max(60).optional() }).loose();
export const RmContactSave = z.object({ id: id.optional(), name: z.string().trim().min(1, 'Enter a name.').max(60), phone: z.string().max(20).optional(),
  upi_id: z.string().max(260).optional() }).loose();
// Store money, minimal (founder, 28 Oct 2026; C:\\onelocal\\hosted_store_money_2026-10-28.sql): accounts, Record transaction, cash register, dues.
const account = z.enum(['cash', 'bank', 'upi'], { message: 'Choose the account.' });
export const StoreEntries = obj({ from: day.nullish(), to: day.nullish(), direction: z.enum(['all', 'in', 'out']).optional(), method: z.enum(['all', 'cash', 'upi', 'card', 'bank']).optional(), q: z.string().max(100).optional() });
export const StoreRecord = obj({
  kind: z.enum(['goods_sale', 'sale', 'other_income', 'due_received', 'owner_in', 'partner_topup', 'aggregator_settlement', 'other_in',
    'expense', 'purchase', 'supplier_payment', 'salary', 'owner_out', 'refund', 'other_out', 'transfer'], { message: 'Choose what kind of money this is.' }),
  account: account.nullish(), to_account: account.nullish(), amount_minor: amount, entry_date: day.optional(),
  // how it moved (redesign, 28 Oct 2026): the account follows it when none is named
  method: z.enum(['cash', 'upi', 'gpay', 'phonepe', 'card', 'bank'], { message: 'Choose how the money moved.' }).optional(),
  party_phone: z.string().max(20).optional(), proof_path: z.string().max(200).nullish(),
  category: z.string().max(40).optional(), party: z.string().max(60).optional(), reference: z.string().max(40).optional(), note: z.string().max(300).optional(),
  bill_receipt_id: id.nullish(), ...key,
});
export const StoreVoid = obj({ id, reason: z.string().trim().min(3, 'Say why (3 to 200 characters).').max(200) });
export const StoreRegister = obj({ day: day.nullish() });
export const StoreClose = obj({ day: day.nullish(), counted_minor: z.number().int().min(0).max(99_999_999_999) });
// Money redesign (founder's sketches, 28 Oct 2026; C:\onelocal\hosted_money_redesign_2026-10-28.sql): contacts to pay, proof photos.
export const StoreContacts = obj({ q: z.string().max(60).optional() });
export const StoreContactSave = obj({ id: id.nullish(), name: z.string().trim().min(1, 'Enter the name.').max(60), phone: z.string().max(20).optional(), upi_id: z.string().max(100).optional() });
export const PROOF_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
export const PROOF_MAX_BYTES = 5 * 1024 * 1024;
export const ProofAsk = z.object({
  content_type: z.string({ message: 'Upload a JPG, PNG or PDF.' }).refine(t => t in PROOF_EXT, 'Upload a JPG, PNG or PDF.'),
  size: z.number().int().min(1, 'That file is empty.').max(PROOF_MAX_BYTES, 'Each file can be up to 5 MB.'),
});
export const ProofLink = z.object({ id });
