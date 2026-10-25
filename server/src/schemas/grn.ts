// Request shapes for GRN matching and owner approval (database: migration 0391, section G, on top of section H's receipt documents).
// receipt_document_id is the RECEIPT document (inventory_documents.id). A friendly first check only; every rule is in the database.
// Money is in minor units (paise).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const money = z.number().int().min(0).max(100_000_000_000);
const version = z.number({ message: 'Refresh the purchase and try again.' }).int().min(1);
const receipt = { receipt_document_id: id };

export const List = z.object({}).strict();
export const Receipt = z.object(receipt).strict();   // grn_open, grn_view, grn_matching_view
export const Invoice = z.object({
  ...receipt, supplier_name: z.string().max(80), invoice_no: z.string().max(40), invoice_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invoice date is YYYY-MM-DD.'),
  po_ref: z.string().max(40).optional(),
  lines: z.array(z.object({ inventory_item_id: id.nullish(), product_name: z.string().min(1).max(120), qty: z.number().positive().max(1_000_000),
    unit: z.string().max(20).optional(), unit_price_minor: money }).strict()).min(1).max(200),
}).strict();
export const Costs = z.object({ ...receipt, costs: z.array(z.object({ line_id: id, unit_cost_minor: money }).strict()).min(1).max(200) }).strict();
export const Resolve = z.object({
  ...receipt, version, resolution: z.enum(['accept_claim_credit', 'accept_as_received']),
  claim_ref: z.string().max(40).nullish(), evidence: z.string().max(200).nullish(), note: z.string().max(200).nullish(),
}).strict();
export const RequestApproval = z.object({ ...receipt, version }).strict();
export const Decide = z.object({ ...receipt, version, decision: z.enum(['approve', 'reject']), note: z.string().max(200).nullish() }).strict();
