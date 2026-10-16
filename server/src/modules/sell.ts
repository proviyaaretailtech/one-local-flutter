// VINII POS section F: the till on top of section E. Product search, split payment, transaction history and receipts, payment failures,
// customer returns and refunds, coupons. Every rule is a database function (migrations 0380 to 0382); this file authenticates, checks the
// shape of the request, calls the function AS the signed-in staff member (so row-level security and role checks apply) and words the answer.
//
//   GET  /api/partner/sell/catalog?q&category&available&sort        searchable items       menu_items (RLS)
//   POST /api/partner/sell/orders/:id/split-pay    (Idempotency-Key) 2 to 4 tenders         pos_split_pay
//   POST /api/partner/sell/orders/:id/refund       (Idempotency-Key) counter refund         pos_refund            manager
//   POST /api/partner/sell/orders/:id/attempts                       log a failed payment   pos_payment_attempt_record
//   POST /api/partner/sell/orders/:id/online-checkout                provider hook          503 until a provider is configured
//   GET  /api/partner/sell/receipts?q&status&from&to&before          transactions, receipts pos_receipt_list
//   GET  /api/partner/sell/returns?status&q                          customer returns       pos_return_list
//   POST /api/partner/sell/returns                 (Idempotency-Key) request a return       pos_return_create
//   POST /api/partner/sell/returns/:id/decide                        approve / reject       pos_return_decide     manager
//   POST /api/partner/sell/returns/:id/refund      (Idempotency-Key) refund an approved one pos_return_issue_refund manager
//   GET  /api/partner/sell/coupons                                   coupons                sell_coupons (RLS)
//   POST /api/partner/sell/coupons                                   create / change        pos_coupon_save       manager
import { HttpError, readBody } from '../http.ts';
import { asCaller, call, dayYear, dbFail, METHOD, money, requiredKey, rupees, text, time, uuid, view } from './orders.ts';

type Row = Record<string, any>;
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// ---------------------------------------------------------------- catalog / search
const SORTS = ['price_asc', 'price_desc', 'name'] as const;

export async function catalog(request: Request) {
  const q = new URL(request.url).searchParams;
  const term = text(q.get('q'), 60).replace(/[%_,()]/g, '');
  const category = text(q.get('category'), 60);
  const sort = q.get('sort') ?? 'name';
  if (!(SORTS as readonly string[]).includes(sort)) throw new HttpError(400, 'Unknown sort.', undefined, 'bad_request');
  let query = asCaller(request).from('menu_items').select('id, name, sku, price, image_url, is_available, category:menu_categories(name)').limit(200);
  if (q.get('available') === '1') query = query.eq('is_available', true);
  if (term) query = query.or(`name.ilike.%${term}%,sku.ilike.%${term}%`);
  const { data, error } = await query;
  if (error) dbFail(error);
  let items = (data ?? []).map(i => ({
    id: i.id, name: i.name, sku: i.sku ?? '', price: Number(i.price), image_url: i.image_url ?? null, available: !!i.is_available,
    category: (i.category as unknown as { name?: string } | null)?.name ?? '',
  }));
  const categories = [...new Set(items.map(i => i.category).filter(Boolean))].sort();
  if (category) items = items.filter(i => i.category.toLowerCase() === category.toLowerCase());
  items.sort(sort === 'price_asc' ? (a, b) => a.price - b.price : sort === 'price_desc' ? (a, b) => b.price - a.price : (a, b) => a.name.localeCompare(b.name));
  return { items, categories };
}

// ---------------------------------------------------------------- payment
export async function splitPay(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  if (!Array.isArray(body.payments)) throw new HttpError(400, 'Send the parts of the payment.', undefined, 'bad_request');
  const payments = (body.payments as Row[]).slice(0, 4).map(p => ({
    method: text(p?.method, 10), amount: money(p?.amount), tendered: money(p?.tendered), reference: text(p?.reference, 80) || null,
  }));
  const client = asCaller(request);
  const out = await call<Row>(client, 'pos_split_pay', {
    order_id: id, idempotency_key: requiredKey(request), payments, expected_updated_at: typeof body.version === 'string' ? body.version : '',
  });
  return { ...(await view(client, id)), replayed: !!out.replayed };
}

const ATTEMPT_STATUS = ['declined', 'failed', 'cancelled'];
const ATTEMPT_METHOD = ['cash', 'upi', 'card', 'online'];

export async function recordAttempt(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  const status = text(body.status, 12) || 'declined', method = text(body.method, 10);
  if (!ATTEMPT_STATUS.includes(status) || !ATTEMPT_METHOD.includes(method)) throw new HttpError(400, 'Unknown payment method or status.', undefined, 'bad_request');
  const client = asCaller(request);
  await call(client, 'pos_payment_attempt_record', { order_id: id, method, status, code: text(body.code, 60), message: text(body.message, 200) });
  const order = await view(client, id);
  return { ...failure(order, method, status, text(body.code, 60), text(body.message, 200)) };
}

/** What the "Transaction failed" screen shows. Nothing was charged: a failed attempt never writes a payment. */
function failure(order: Row, method: string, status: string, code: string, message: string) {
  const methodLabel = method === 'online' ? 'Online payment' : `${METHOD[method] ?? method} payment`;
  return {
    order_id: order.id, display_no: order.display_no, method, status, code, message,
    headline: `${methodLabel} ${status === 'declined' ? 'declined' : status === 'cancelled' ? 'cancelled' : 'failed'}`,
    detail: `This payment was ${status === 'cancelled' ? 'cancelled' : status}. Your cart is still saved.`,
    amount_due: Number(order.bill?.due ?? order.bill?.total ?? 0), charged: false,
  };
}

// The hosted online checkout (Razorpay) needs a provider account and keys on the server. This build has none, so the answer is an honest 503
// and the app falls back to taking UPI or card on the counter terminal. Wiring a provider is a separate, reviewed step (test mode first).
export async function onlineCheckout(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  await view(asCaller(request), id); // proves the order is the caller's
  throw new HttpError(503, 'Online payment is not switched on for this shop yet. Take the payment on the card machine or UPI and confirm it here.', undefined, 'provider_not_configured');
}

// ---------------------------------------------------------------- refund of a bill
const REFUND_METHODS = ['cash', 'upi', 'card', 'other'], REFUND_KINDS = ['missing_items', 'cancel', 'goodwill'];

export async function refundOrder(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  const method = text(body.method, 10), kind = text(body.kind, 20) || 'goodwill', reason = text(body.reason, 300), amount = money(body.amount);
  if (!REFUND_METHODS.includes(method) || !REFUND_KINDS.includes(kind)) throw new HttpError(400, 'Choose how the money goes back.', undefined, 'bad_request');
  if (amount === null) throw new HttpError(400, 'Enter the amount to refund.', undefined, 'bad_request');
  if (reason.length < 3) throw new HttpError(400, 'Say why the refund is given.', undefined, 'bad_request');
  const client = asCaller(request);
  const out = await call<Row>(client, 'pos_refund', { order_id: id, amount, method, kind, reason, idempotency_key: requiredKey(request) });
  return { ...(await view(client, id)), refund: { amount: Number(out.amount), refundable_left: out.refundable_left ?? null, replayed: !!out.replayed } };
}

// ---------------------------------------------------------------- receipts and transaction history
const STATUS_LABEL: Record<string, string> = { paid: 'Paid', part_paid: 'Partially paid', unpaid: 'Unpaid', refunded: 'Refunded', cancelled: 'Cancelled' };

export function receiptText(r: Row) {
  const out = [`Receipt ${r.display_no}`, `${dayYear(r.created_at)} · ${time(r.created_at)}`, ''];
  for (const i of r.items as Row[]) out.push(`${i.qty} x ${i.name}  ${rupees(Number(i.amount))}`);
  out.push('', `Subtotal ${rupees(r.subtotal)}`);
  if (Number(r.gst_amount)) out.push(`GST (${Number(r.gst_pct)}%) ${rupees(r.gst_amount)}`);
  if (Number(r.service_charge)) out.push(`Service charge ${rupees(r.service_charge)}`);
  if (Number(r.discount)) out.push(`Discount${r.coupon_code ? ` ${r.coupon_code}` : ''} -${rupees(r.discount)}`);
  if (Number(r.round_off)) out.push(`Round off ${rupees(r.round_off)}`);
  out.push(`Total ${rupees(r.total)}`, Number(r.paid) > 0 ? `Paid ${rupees(r.paid)} (${methodLabel(r.methods)})` : 'Not paid');
  if (Number(r.refunded) > 0) out.push(`Refunded ${rupees(r.refunded)}`);
  return out.join('\n');
}

function methodLabel(methods: string[]) {
  return methods.length > 1 ? 'Split' : methods.length === 1 ? METHOD[methods[0]] ?? methods[0] : 'Not chosen';
}

export function shapeReceipt(r: Row) {
  const total = Number(r.total), paid = Number(r.paid), refunded = Number(r.refunded);
  const methods = (r.methods ?? []) as string[];
  const status = String(r.status);
  const statusLabel = status === 'paid' ? `Paid · ${methodLabel(methods)}` : status === 'refunded' ? `Refunded · ${rupees(refunded)}` : STATUS_LABEL[status] ?? status;
  const units = Number(r.units);
  const discount = Number(r.discount);
  return {
    id: r.id, display_no: r.display_no, customer: r.customer_name || 'Guest', customer_phone: r.customer_phone ?? null,
    created_at: r.created_at, when: `${dayYear(r.created_at)} · ${time(r.created_at)}`, paid_at: r.paid_at ?? null, paid_at_label: r.paid_at ? `Paid at ${time(r.paid_at)}` : null,
    status, status_label: statusLabel, payment_mode: methodLabel(methods), channel: r.channel,
    total, paid, refunded, balance_due: status === 'part_paid' || status === 'unpaid' ? Math.max(0, Math.round((total - paid) * 100) / 100) : 0,
    units, lines: Number(r.lines), counts: `${plural(Number(r.lines), 'line')} · ${plural(units, 'unit')}`, items: r.items,
    subtotal: Number(r.subtotal), discount, coupon_code: r.coupon_code ?? null, gst_pct: Number(r.gst_pct), gst_amount: Number(r.gst_amount),
    tax_and_charges: Math.round((Number(r.gst_amount) + Number(r.service_charge)) * 100) / 100, service_charge: Number(r.service_charge), round_off: Number(r.round_off),
    kind_label: status === 'paid' ? 'Sales receipt' : 'Sales invoice', receipt_text: receiptText(r),
  };
}

const STATUSES = ['all', 'paid', 'part_paid', 'unpaid', 'refunded', 'cancelled'];
const isDate = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v));

export async function receipts(request: Request) {
  const q = new URL(request.url).searchParams;
  const status = q.get('status') ?? 'all', from = q.get('from') ?? '', to = q.get('to') ?? '', before = q.get('before') ?? '';
  if (!STATUSES.includes(status)) throw new HttpError(400, 'Unknown status.', undefined, 'bad_request');
  if ((from && !isDate(from)) || (to && !isDate(to))) throw new HttpError(400, 'Dates look like 2026-10-09.', undefined, 'bad_request');
  if (before && Number.isNaN(Date.parse(before))) throw new HttpError(400, 'Unknown position in the list.', undefined, 'bad_request');
  const rows = await call<Row[]>(asCaller(request), 'pos_receipt_list', { q: text(q.get('q'), 60), status, from, to, before });
  return { receipts: (rows ?? []).map(shapeReceipt) };
}

// ---------------------------------------------------------------- returns
const RET_LABEL: Record<string, string> = { requested: 'Requested', approved: 'Approved', rejected: 'Rejected', refunded: 'Refunded' };
const RET_NOTE: Record<string, string> = { requested: 'Awaiting a manager', approved: 'Approved · refund not issued', rejected: 'Rejected', refunded: 'Refund issued' };

export function shapeReturn(r: Row) {
  const lines = (r.lines ?? []) as Row[];
  return {
    id: r.id, return_no: r.return_no, status: r.status, status_label: RET_LABEL[r.status] ?? r.status, date: dayYear(r.created_at),
    customer: r.customer_name || 'Guest', order_no: r.order_no, order_id: r.order_id, reason: r.reason, note: r.note || null,
    status_note: r.status === 'refunded' && r.refund_method ? `Refund issued · ${METHOD[r.refund_method] ?? r.refund_method}` : r.status === 'rejected' && r.decision_note ? `Rejected · ${r.decision_note}` : RET_NOTE[r.status] ?? '',
    amount: Number(r.amount), lines: lines.map(l => ({ name: l.name, qty: Number(l.qty), amount: Number(l.amount) })),
  };
}

const RET_STATUS = ['all', 'requested', 'approved', 'rejected', 'refunded'];

export async function returnsList(request: Request) {
  const q = new URL(request.url).searchParams;
  const status = q.get('status') ?? 'all';
  if (!RET_STATUS.includes(status)) throw new HttpError(400, 'Unknown status.', undefined, 'bad_request');
  const rows = await call<Row[]>(asCaller(request), 'pos_return_list', { status, q: text(q.get('q'), 60) });
  return { returns: (rows ?? []).map(shapeReturn) };
}

export async function returnCreate(request: Request) {
  const body = await readBody(request);
  const orderId = uuid(body.order_id);
  if (!orderId) throw new HttpError(400, 'Choose the bill the items came from.', undefined, 'bad_request');
  if (!Array.isArray(body.lines) || body.lines.length < 1) throw new HttpError(400, 'Choose the items being returned.', undefined, 'bad_request');
  const lines = (body.lines as Row[]).slice(0, 50).map(l => ({ order_item_id: uuid(l?.order_item_id), qty: Number(l?.qty) }));
  const out = await call<Row>(asCaller(request), 'pos_return_create', { order_id: orderId, lines, reason: text(body.reason, 200), note: text(body.note, 300), idempotency_key: requiredKey(request) });
  return { return_id: out.return_id, return_no: out.return_no, amount: Number(out.amount), status: out.status, replayed: !!out.replayed };
}

export async function returnDecide(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Return not found.', undefined, 'not_found');
  const body = await readBody(request);
  const decision = text(body.decision, 10);
  if (decision !== 'approve' && decision !== 'reject') throw new HttpError(400, 'Approve or reject.', undefined, 'bad_request');
  return call(asCaller(request), 'pos_return_decide', { return_id: id, decision, note: text(body.note, 300) });
}

export async function returnRefund(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Return not found.', undefined, 'not_found');
  const body = await readBody(request);
  const method = text(body.method, 10);
  if (!REFUND_METHODS.includes(method)) throw new HttpError(400, 'Choose how the money goes back.', undefined, 'bad_request');
  return call(asCaller(request), 'pos_return_issue_refund', { return_id: id, method, idempotency_key: requiredKey(request) });
}

// ---------------------------------------------------------------- coupons
export async function couponsList(request: Request) {
  const { data, error } = await asCaller(request).from('sell_coupons')
    .select('id, code, label, kind, value, min_order, max_discount, active, starts_at, ends_at, used_count').order('code');
  if (error) dbFail(error);
  return { coupons: data ?? [] };
}

export async function couponSave(request: Request) {
  const body = await readBody(request);
  const num = (v: unknown) => (v === undefined || v === null || v === '' ? null : Number(v));
  return call(asCaller(request), 'pos_coupon_save', {
    code: text(body.code, 20), label: text(body.label, 80), kind: text(body.kind, 10), value: num(body.value), min_order: num(body.min_order) ?? 0, max_discount: num(body.max_discount),
    active: body.active === false ? false : true, starts_at: text(body.starts_at, 40), ends_at: text(body.ends_at, 40),
  });
}
