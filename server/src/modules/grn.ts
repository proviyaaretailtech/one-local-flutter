// VINII POS section G: GRN matching and owner approval, on top of section H's receipt documents. Database: migration 0391
// (the receipt itself, its counts and the stock posting are section H: inventory_documents / inv_document_act).
// :id in every path is the RECEIPT document id (inventory_documents.id).
//
//   GET  /api/partner/grn                       receipts waiting for GRN review, and recently approved ones
//   POST /api/partner/grn/open                  {receipt_document_id}          open (or find) the GRN of a receipt that was sent to GRN review
//   GET  /api/partner/grn/:id                   the dashboard: totals, resolution, posting preview, checklist, allowed actions
//   GET  /api/partner/grn/:id/matching          supplier invoice against physical receiving, row by row
//   PUT  /api/partner/grn/:id/invoice           {supplier_name, invoice_no, invoice_date, po_ref?, lines:[{inventory_item_id?, product_name, qty, unit?, unit_price_minor}]}
//   PUT  /api/partner/grn/:id/costs             {costs:[{line_id, unit_cost_minor}]}   unit prices noticed at receiving
//   POST /api/partner/grn/:id/resolve           {version, resolution: accept_claim_credit|accept_as_received, claim_ref?, evidence?, note?}
//   POST /api/partner/grn/:id/request-approval  {version}
//   POST /api/partner/grn/:id/decide            {version, decision: approve|reject, note?}   approve posts the stock through section H
//
// Money is in minor units (paise). Every rule is in the database; this file checks the shape of the request only.
import { z } from 'zod';
import { HttpError, readBody } from '../http.ts';
import { asCaller, call, needUuid } from './pos_db.ts';

const money = z.number().int().min(0).max(100_000_000_000);
const version = z.number().int().min(1);
const schemas = {
  invoice: z.object({
    supplier_name: z.string().max(80), invoice_no: z.string().max(40), invoice_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), po_ref: z.string().max(40).optional(),
    lines: z.array(z.object({ inventory_item_id: z.string().uuid().nullish(), product_name: z.string().min(1).max(120), qty: z.number().positive().max(1_000_000),
      unit: z.string().max(20).optional(), unit_price_minor: money }).strict()).min(1).max(200),
  }).strict(),
  costs: z.object({ costs: z.array(z.object({ line_id: z.string().uuid(), unit_cost_minor: money }).strict()).min(1).max(200) }).strict(),
  resolve: z.object({ version, resolution: z.enum(['accept_claim_credit', 'accept_as_received']), claim_ref: z.string().max(40).nullish(), evidence: z.string().max(200).nullish(), note: z.string().max(200).nullish() }).strict(),
  request: z.object({ version }).strict(),
  decide: z.object({ version, decision: z.enum(['approve', 'reject']), note: z.string().max(200).nullish() }).strict(),
  open: z.object({ receipt_document_id: z.string().uuid() }).strict(),
};

async function body<K extends keyof typeof schemas>(request: Request, kind: K): Promise<z.infer<(typeof schemas)[K]>> {
  const r = schemas[kind].safeParse(await readBody(request));
  if (!r.success) throw new HttpError(400, `Check the details: ${r.error.issues[0]?.path.join('.') || 'request'} is not valid.`, undefined, 'bad_request');
  return r.data as z.infer<(typeof schemas)[K]>;
}

const receipt = (id: string) => needUuid(id, 'Receipt');

export const list = (request: Request) => call(asCaller(request), 'grn_list', {});
export async function open(request: Request) { return call(asCaller(request), 'grn_open', await body(request, 'open')); }
export const view = (request: Request, id: string) => call(asCaller(request), 'grn_view', { receipt_document_id: receipt(id) });
export const matching = (request: Request, id: string) => call(asCaller(request), 'grn_matching_view', { receipt_document_id: receipt(id) });
export async function saveInvoice(request: Request, id: string) { return call(asCaller(request), 'grn_invoice_save', { ...(await body(request, 'invoice')), receipt_document_id: receipt(id) }); }
export async function saveCosts(request: Request, id: string) { return call(asCaller(request), 'grn_costs_save', { ...(await body(request, 'costs')), receipt_document_id: receipt(id) }); }
export async function resolve(request: Request, id: string) { return call(asCaller(request), 'grn_resolve', { ...(await body(request, 'resolve')), receipt_document_id: receipt(id) }); }
export async function requestApproval(request: Request, id: string) { return call(asCaller(request), 'grn_request_approval', { ...(await body(request, 'request')), receipt_document_id: receipt(id) }); }
export async function decide(request: Request, id: string) { return call(asCaller(request), 'grn_decide', { ...(await body(request, 'decide')), receipt_document_id: receipt(id) }); }
