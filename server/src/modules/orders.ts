// One Local POS section E: the counter bill, the order lifecycle after payment and the order history (spec: specs/pos-section-e-orders in the
// workspace root; database: migration 0370).
//
//   GET  /api/partner/pos-orders?filter=all|completed|pending|cancelled&q=   history          pos_order_history
//   GET  /api/partner/pos-orders/catalog?q=                                   sellable items   menu_items (RLS)
//   POST /api/partner/pos-orders/quote                                        cart totals      pos_quote_order (writes nothing)
//   POST /api/partner/pos-orders/checkout   (Idempotency-Key)                 place + pay      pos_checkout
//   POST /api/partner/pos-orders/hold       (Idempotency-Key)                 place unpaid     pos_hold_place (pos_checkout {hold} + reason, 0530)
//   GET  /api/partner/pos-orders/:id                                          one order        pos_order_view
//   POST /api/partner/pos-orders/:id/pay    (Idempotency-Key)                 pay a held bill  pos_checkout_pay
//   POST /api/partner/pos-orders/:id/cancel                                   cancel unpaid    pos_set_order_status
//   POST /api/partner/pos-orders/:id/act    (Idempotency-Key)                 fulfilment       pos_fulfilment_act; an online order goes to restaurant.act
//
// Every call runs in the database AS the signed-in staff member (their own access token on an anon-key client), so auth.uid(),
// current_org_id(), the role checks inside the functions and row-level security all apply: org A can never read or move org B's orders.
// This file holds no business rules of its own: it turns the database's facts into the labels and buttons the app shows.
import type { SupabaseClient } from '@supabase/supabase-js';
import { userClient } from '../db.ts';
import { HttpError, readBody } from '../http.ts';
import { idempotencyKey } from '../idempotency.ts';

type Row = Record<string, any>;

// ---------------------------------------------------------------- database access as the caller
export const asCaller = (request: Request): SupabaseClient => userClient(request);

const POS_ERRORS: Record<string, { status: number; code: string }> = {
  POS_BAD_REQUEST: { status: 400, code: 'bad_request' }, POS_BAD_QTY: { status: 400, code: 'bad_quantity' }, POS_EMPTY: { status: 400, code: 'empty_cart' },
  POS_BAD_TABLE: { status: 400, code: 'bad_table' }, POS_FORBIDDEN: { status: 403, code: 'forbidden' }, POS_NOT_FOUND: { status: 404, code: 'not_found' },
  POS_STALE: { status: 409, code: 'version_conflict' }, POS_WRONG_STATE: { status: 409, code: 'wrong_state' }, POS_ITEM_UNAVAILABLE: { status: 409, code: 'item_unavailable' },
  POS_HAS_PAYMENTS: { status: 409, code: 'has_payments' }, POS_NOT_PAID_IN_FULL: { status: 409, code: 'not_paid_in_full' },
  POS_UNDERPAID: { status: 422, code: 'underpaid' }, POS_OVERPAY: { status: 422, code: 'overpay' }, POS_COUPON_UNKNOWN: { status: 422, code: 'coupon_unknown' },
  POS_COUPON_MIN: { status: 422, code: 'coupon_minimum' }, POS_COUPON_LIMIT: { status: 422, code: 'coupon_limit' }, POS_COUPON_CUSTOMER: { status: 422, code: 'coupon_customer' }, POS_COUPON_ZERO: { status: 422, code: 'coupon_zero' }, POS_IDEMPOTENCY_MISMATCH: { status: 422, code: 'idempotency_mismatch' },
  OL_IDEMPOTENCY_MISMATCH: { status: 422, code: 'idempotency_mismatch' }, OL_IN_PROGRESS: { status: 409, code: 'in_progress' },
  OL_STATUS_AUTHORITY: { status: 409, code: 'wrong_state' }, OL_ORDER_FROZEN: { status: 409, code: 'wrong_state' },
};

function dbFail(error: { message?: string; code?: string }): never {
  const message = String(error.message ?? '');
  const m = message.match(/^([A-Z]+_[A-Z_]+):\s*(.*)$/);
  if (m && POS_ERRORS[m[1]]) throw new HttpError(POS_ERRORS[m[1]].status, sentence(m[2]), undefined, POS_ERRORS[m[1]].code);
  if (error.code === '42501' || /permission denied/i.test(message)) throw new HttpError(403, 'You do not have permission to do that.', undefined, 'forbidden');
  console.error('[pos-orders]', { code: error.code, message: message.slice(0, 200) });
  throw new HttpError(500, 'Something went wrong. Please try again.');
}
const sentence = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? '' : '.') : 'Request refused.');

async function call<T = Row>(client: SupabaseClient, fn: string, p: Row): Promise<T> {
  const { data, error } = await client.rpc(fn, { p });
  if (error) dbFail(error);
  return data as T;
}

// ---------------------------------------------------------------- input
const uuid = (v: unknown) => (typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? v : null);
const text = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
function lines(v: unknown) {
  if (!Array.isArray(v) || v.length < 1 || v.length > 50) throw new HttpError(400, 'Add between 1 and 50 items.', undefined, 'empty_cart');
  return v.map(l => {
    const id = uuid((l as Row)?.menu_item_id), qty = Number((l as Row)?.qty);
    if (!id || !Number.isInteger(qty) || qty < 1 || qty > 99) throw new HttpError(400, 'Each item needs a quantity from 1 to 99.', undefined, 'bad_quantity');
    return { menu_item_id: id, qty };
  });
}
function requiredKey(request: Request) {
  const key = idempotencyKey(request);
  if (!key) throw new HttpError(400, 'Idempotency-Key header is required.', undefined, 'invalid_request');
  return key;
}
function money(v: unknown) {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw new HttpError(400, 'Enter the amount received.', undefined, 'bad_request');
  return Math.round(n * 100) / 100;
}

// ---------------------------------------------------------------- formatting
const rupees = (n: number | string) => {
  const v = Number(n);
  return `${v < 0 ? '-' : ''}₹${Math.abs(v).toLocaleString('en-IN', { minimumFractionDigits: Number.isInteger(v) ? 0 : 2, maximumFractionDigits: 2 })}`;
};
const IST = { timeZone: 'Asia/Kolkata' } as const;
const time = (iso: string) => new Intl.DateTimeFormat('en-IN', { ...IST, hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso)).replace(/\s?([ap])\.?m\.?$/i, (_, a: string) => ` ${a.toUpperCase()}M`);
const day = (iso: string) => new Intl.DateTimeFormat('en-GB', { ...IST, day: '2-digit', month: 'short' }).format(new Date(iso));
const dayYear = (iso: string) => new Intl.DateTimeFormat('en-GB', { ...IST, day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(iso));
const METHOD: Record<string, string> = { cash: 'Cash', upi: 'UPI', card: 'Card', split: 'Split', wallet: 'Wallet', online: 'Online', other: 'Other', due: 'Due' };
const OL_METHOD: Record<string, string> = { cod: 'Cash on delivery', upi: 'UPI', card: 'Card', netbanking: 'Net banking', wallet: 'Wallet', paylater: 'Pay Later', emi: 'EMI', cardless_emi: 'EMI' };
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

function channelLabel(o: Row) {
  return o.channel === 'online' || o.placed_by === 'integration' ? 'Online Order' : o.channel === 'dine_in' ? 'Dine-in' : 'Store Checkout';
}

// ---------------------------------------------------------------- the order view
export type Stage = 'checkout' | 'pending' | 'preparing' | 'picked' | 'ready' | 'in_transit' | 'completed' | 'cancelled' | 'exception';
type Action = { id: string; label: string; style: 'primary' | 'secondary' | 'link' };

const OL_STAGE: Record<string, Stage> = { placed: 'pending', accepted: 'preparing', packed: 'ready', out: 'in_transit', delivered: 'completed', cancelled: 'cancelled' };
const F_STAGE: Record<string, Stage> = { awaiting_acceptance: 'pending', picking: 'preparing', picked: 'picked', ready: 'ready', dispatched: 'in_transit', completed: 'completed' };

export function stageOf(v: Row): Stage {
  const o = v.order, f = v.fulfilment, ol = v.online;
  if (o.status === 'cancelled' || ol?.status === 'cancelled') return 'cancelled';
  if (ol) return OL_STAGE[ol.status] ?? 'pending';
  if (f) return f.exception ? 'exception' : F_STAGE[f.stage] ?? 'pending';
  if (o.status === 'paid' || o.status === 'delivered') return 'completed';
  return 'checkout';
}

const TITLE: Record<Stage, string> = {
  checkout: 'Checkout', pending: 'Order Confirmation', preparing: 'Order Preparing', picked: 'Order Picked', ready: 'Order Ready',
  in_transit: 'Order In Transit', completed: 'Order Completed', cancelled: 'Order Cancelled', exception: 'Order Exception',
};

export function shapeView(v: Row) {
  const o = v.order, f = (v.fulfilment ?? null) as Row | null, ol = (v.online ?? null) as Row | null;
  const stage = stageOf(v);
  const items = (v.items ?? []) as Row[];
  const units = items.reduce((n, i) => n + i.qty, 0);
  const picked = items.reduce((n, i) => n + (i.picked_qty ?? 0), 0);
  const missing = items.reduce((n, i) => n + (i.missing_qty ?? 0), 0);
  const paid = Number(v.paid ?? 0), total = Number(o.total), due = Math.max(0, Math.round((total - paid) * 100) / 100);
  const payments = (v.payments ?? []) as Row[];
  const cash = payments.filter(p => p.method === 'cash');
  const tendered = cash.reduce((n, p) => n + Number(p.tendered ?? p.amount), 0);
  const cashAmount = cash.reduce((n, p) => n + Number(p.amount), 0);
  const methods = [...new Set(payments.map(p => p.method as string))];
  const methodName = methods.length > 1 ? 'Split' : METHOD[methods[0]] ?? (ol ? OL_METHOD[ol.payment_method] ?? 'Online' : 'Not chosen');
  const onlinePaid = ol?.payment_status === 'paid';

  const orderStatus = ({
    checkout: 'Held · awaiting payment', pending: 'Pending', preparing: 'Preparing', picked: 'Preparing', ready: 'Ready', in_transit: 'Dispatched',
    completed: 'Completed', cancelled: 'Cancelled', exception: f?.stage === 'dispatched' ? 'Dispatched' : 'Ready',
  } as Record<Stage, string>)[stage];

  let fulfilment: string;
  switch (stage) {
    case 'checkout': fulfilment = 'Not started'; break;
    case 'pending': fulfilment = ol ? 'Awaiting restaurant acceptance' : 'Awaiting store acceptance'; break;
    case 'preparing': fulfilment = ol ? 'Being prepared' : `Picking items · ${picked} of ${units} checked${missing ? ` · ${missing} missing` : ''}`; break;
    case 'picked': fulfilment = `${units} of ${units} units picked · not packed`; break;
    case 'ready': fulfilment = ol ? 'Packed · waiting for pickup' : `${units} of ${units} units ready for handover${f?.handover_method === 'collection' ? ' · store collection' : ''}`; break;
    case 'in_transit': fulfilment = ol?.rider_name ? `With ${ol.rider_name}${ol.eta_minutes ? ` · about ${ol.eta_minutes} min` : ''}` : 'In transit · delivery not confirmed'; break;
    case 'exception': fulfilment = f?.exception === 'delivery_issue' ? 'Delivery issue · not delivered' : 'Dispatch blocked · not handed over'; break;
    case 'completed': fulfilment = f?.completed_at ? `${f.handover_method === 'store_delivery' ? 'Delivered' : 'Handed over'} · ${day(f.completed_at)} · ${time(f.completed_at)}` : 'Fulfilled'; break;
    default: fulfilment = 'Stopped · no units fulfilled';
  }

  const paymentChip = stage === 'cancelled' && paid === 0 && !onlinePaid ? 'Not captured'
    : paid >= total && paid > 0 ? `Paid · ${methodName}`
    : onlinePaid ? 'Paid · Online'
    : ol?.payment_method === 'cod' ? 'Cash on delivery'
    : paid > 0 ? `Part paid · ${rupees(due)} due` : stage === 'checkout' ? 'Awaiting payment' : 'Unpaid';

  const lineState = (i: Row) => {
    switch (stage) {
      case 'checkout': return 'ready for checkout';
      case 'pending': return 'placed';
      case 'preparing': return ol ? 'preparing' : i.missing_qty ? `${i.missing_qty} missing` : i.picked_qty === i.qty ? 'picked' : i.picked_qty ? `${i.picked_qty} of ${i.qty} picked` : 'awaiting pick check';
      case 'picked': return 'picked';
      case 'ready': return 'ready';
      case 'in_transit': return 'in transit';
      case 'exception': return f?.exception === 'delivery_issue' ? 'in transit · delivery issue' : 'ready · dispatch blocked';
      case 'completed': return f?.handover_method === 'store_delivery' ? 'delivered' : ol ? 'delivered' : 'handed over';
      default: return 'cancelled · retained in bill';
    }
  };

  const active = ['pending', 'preparing', 'picked', 'ready', 'in_transit', 'exception'].includes(stage);
  return {
    id: o.id,
    display_no: o.display_no,
    stage,
    title: TITLE[stage],
    danger: stage === 'exception',
    channel_label: channelLabel(o),
    place_label: v.table_label ?? null,
    customer: o.customer_name || 'Guest',
    placed_at: time(o.created_at),
    order_status: orderStatus,
    fulfilment,
    payment_chip: paymentChip,
    note: noteFor(stage, { f, ol, paid, methodName, missing, reason: v.cancel_reason ?? ol?.cancel_reason, photo: v.photo_required !== false }),
    // where the order is, as four simple steps (founder, 29 Oct 2026: "the current way is a bit confusing"): Accept · Pack · Hand over · Done.
    // current = the step to do now; 4 = all done. Null for a counter bill and a cancelled order.
    steps: (f || ol) && stage !== 'cancelled' && stage !== 'checkout'
      ? { labels: ['Accept', 'Pack', ol ? 'Rider' : 'Hand over', 'Done'], current: STEP[stage] ?? 0 } : null,
    // the photo of the packed bag (returns spec §6): has_photo, or skip_reason when there is none; photo_required: the store asks for one
    packed_photo: v.packed_photo ?? null,
    photo_required: v.photo_required !== false,
    // Fulfilment moves carry the fulfilment version; a held bill (pay / cancel) carries the order's updated_at.
    version: f ? f.version : o.updated_at,
    online: !!ol,
    items: items.map(i => ({
      order_item_id: i.order_item_id, menu_item_id: i.menu_item_id, name: i.name, qty: i.qty, picked_qty: i.picked_qty ?? null, missing_qty: i.missing_qty ?? null,
      amount: Number(i.unit_price) * i.qty, sub: `${plural(i.qty, 'unit')} ordered · ${lineState(i)}`,
    })),
    summary: `${plural(items.length, 'line')} · ${plural(units, 'unit')}`,
    adjustments: 'No coupon · No tip added',
    bill: { subtotal: Number(o.subtotal), gst_pct: Number(o.gst_pct), gst: Number(o.gst_amount), service_charge: Number(o.service_charge),
      discount: Number(o.discount), round_off: Number(o.round_off), total },
    payment: {
      label: stage === 'checkout' ? 'Amount received · not yet captured'
        : cash.length ? `Cash tendered · settled amount ${rupees(cashAmount)}`
        : paid > 0 ? `${methodName} · settled amount ${rupees(paid)}` : onlinePaid ? `Paid online · ${rupees(total)}` : 'Amount captured · no cash collected',
      settled: paid, due, method: methodName,
      tendered: cash.length ? tendered : paid,
      change: cash.length ? Math.round((tendered - cashAmount) * 100) / 100 : 0,
      record: stage === 'checkout' ? null : paid > 0 || onlinePaid
        ? { title: `${methodName} payment`, value: `${rupees(onlinePaid && paid === 0 ? total : paid)} settled`, second: 'Balance due', second_value: rupees(onlinePaid ? 0 : due),
            footer: due === 0 || onlinePaid ? 'Payment complete. Duplicate charging is disabled.' : `${rupees(due)} still due.` }
        : { title: 'Cash payment', value: '₹0 captured', second: 'Refund due', second_value: '₹0', footer: 'No cash collected. No refund required.' },
    },
    // Customer phone and address only while the order is active (same rule as the partner order inbox).
    delivery: active && f ? { name: f.delivery_name, phone: f.delivery_phone, address: f.delivery_address, method: f.handover_method } : null,
    exception: f?.exception ? { kind: f.exception, note: f.exception_note } : null,
    cancel_reason: v.cancel_reason ?? ol?.cancel_reason ?? null,
    actions: actionsFor(stage, { f, ol, next: (v.next_events ?? []) as string[] }),
    events: ((v.events ?? []) as Row[]).map(e => ({ message: e.message, at: `${day(e.at)} · ${time(e.at)}` })),
    receipt_text: receiptText(o, items, paid, methodName, tendered, cashAmount),
  };
}

const STEP: Partial<Record<Stage, number>> = { pending: 0, preparing: 1, picked: 1, ready: 2, exception: 2, in_transit: 3, completed: 4 };

function noteFor(stage: Stage, c: { f: Row | null; ol: Row | null; paid: number; methodName: string; missing: number; reason?: string | null; photo: boolean }) {
  const n = (tone: 'info' | 'warn' | 'bad', title: string, body: string) => ({ tone, title, body });
  switch (stage) {
    case 'checkout': return n('info', 'Bill on hold', 'No payment has been collected. Complete the payment or cancel this bill.');
    case 'pending': return n('info', 'New order', c.ol ? 'Accept it to start packing. The customer is waiting for your answer.' : 'Accept it, then pack the items.');
    case 'preparing': case 'picked': return n('warn', 'Pack the order',
      `Tick each item as it goes in the bag${c.photo ? ', then take a photo of the packed bag' : ''}.${c.missing ? ` ${plural(c.missing, 'unit')} reported missing.` : ''}`);
    case 'ready': return c.ol ? n('info', 'Packed and ready', 'Hand it to the rider when they arrive.')
      : n('info', 'Packed and ready', 'Give it to the customer, or send it for delivery.');
    case 'in_transit': return n('info', 'Awaiting delivery confirmation', c.ol ? 'The rider confirms delivery with the customer.' : 'Tracking and ETA are unavailable. Verify delivery before completing the order.');
    case 'exception': return c.f?.exception === 'delivery_issue'
      ? n('bad', 'Delivery issue reported', `${c.f.exception_note ?? 'An issue was reported'}. Confirm delivery or bring the order back to the store.`)
      : n('bad', 'Delivery information is missing', 'Address and contact details unavailable. Confirm the handover method to proceed.');
    case 'completed': return n('info', 'Order completed', 'This order is closed. The receipt stays available.');
    default: return n('info', c.paid > 0 ? 'Order cancelled' : 'Cancelled before cash capture',
      `${rupees(c.paid)} captured; ₹0 refund due. ${c.reason ? `Reason: ${c.reason}.` : 'Cancellation reason is not recorded.'}`);
  }
}

function actionsFor(stage: Stage, c: { f: Row | null; ol: Row | null; next: string[] }): Action[] {
  const a = (id: string, label: string, style: Action['style']): Action => ({ id, label, style });
  if (c.ol) {
    switch (stage) {
      case 'pending': return [a('online_accept', 'Accept order', 'primary'), a('online_reject', 'Reject order', 'secondary'), a('receipt', 'View receipt', 'link')];
      // packing screen first (it marks the order ready); then the delivery status page (0619)
      case 'preparing': return [a('pack_order', 'Pack order', 'primary'), a('receipt', 'View receipt', 'link')];
      case 'ready': return [a('online_delivery', 'Check rider status', 'primary'), a('receipt', 'View receipt', 'link')];
      case 'in_transit': return [a('online_delivery', 'Check delivery status', 'primary'), a('receipt', 'View receipt', 'link')];
      default: return [a('receipt', 'View receipt', 'link')];
    }
  }
  switch (stage) {
    case 'checkout': return [a('pay', 'Complete Payment', 'primary'), a('cancel', 'Cancel bill', 'secondary')];
    // one clear next step per stage (founder, 29 Oct 2026); packing is one screen: tick the items, photo of the bag, packed
    case 'pending': return [a('accept', 'Accept order', 'primary'), a('whatsapp', 'Send receipt on WhatsApp', 'link')];
    case 'preparing': case 'picked': return [a('pack_order', 'Pack order', 'primary'), a('report_missing', 'Something missing?', 'link')];
    case 'ready': return [a('handover', 'Customer collected it', 'primary'), a('dispatch', 'Send for delivery', 'secondary'), a('receipt', 'View receipt', 'link')];
    case 'in_transit': return [a('delivery_status', 'Mark delivered', 'primary'), a('report_delivery_issue', 'Report a delivery problem', 'secondary'), a('receipt', 'View receipt', 'link')];
    case 'exception': return c.f?.exception === 'delivery_issue'
      ? [a('delivery_status', 'Check delivery status', 'primary'), a('return_to_store', 'Return to store', 'secondary'), a('exception_details', 'Review exception details', 'link')]
      : [a('set_delivery_info', 'Resolve missing information', 'primary'), a('choose_collection', 'Arrange store collection', 'secondary'), a('exception_details', 'Review exception details', 'link')];
    case 'completed': return [a('print', 'Print receipt', 'primary'), a('whatsapp', 'Send by WhatsApp', 'secondary'), a('receipt', 'View receipt', 'link')];
    default: return [a('review_cancellation', 'Review cancellation', 'primary'), a('new_cart', 'Create new cart from items', 'secondary'), a('receipt', 'View original bill', 'link')];
  }
}

function receiptText(o: Row, items: Row[], paid: number, method: string, tendered: number, cashAmount: number) {
  const out = [`Receipt ${o.display_no}`, `${dayYear(o.created_at)} · ${time(o.created_at)}`, ''];
  for (const i of items) out.push(`${i.qty} x ${i.name}  ${rupees(Number(i.unit_price) * i.qty)}`);
  out.push('', `Subtotal ${rupees(o.subtotal)}`, `GST (${Number(o.gst_pct)}%) ${rupees(o.gst_amount)}`);
  if (Number(o.service_charge)) out.push(`Service charge ${rupees(o.service_charge)}`);
  if (Number(o.discount)) out.push(`Discount -${rupees(o.discount)}`);
  if (Number(o.round_off)) out.push(`Round off ${rupees(o.round_off)}`);
  out.push(`Total ${rupees(o.total)}`, paid > 0 ? `Paid ${rupees(paid)} (${method})` : 'Not paid');
  if (cashAmount > 0 && tendered > cashAmount) out.push(`Cash tendered ${rupees(tendered)} · change ${rupees(tendered - cashAmount)}`);
  return out.join('\n');
}

// ---------------------------------------------------------------- history cards
export function shapeCard(r: Row) {
  const f = (r.fulfilment ?? null) as Row | null, ol = (r.online ?? null) as Row | null;
  const total = Number(r.total), paid = Number(r.paid), refunded = Number(r.refunded ?? 0);
  const cancelled = r.status === 'cancelled' || ol?.status === 'cancelled';
  const completed = !cancelled && (r.status === 'delivered' || ol?.status === 'delivered' || (r.status === 'paid' && !f && !ol));
  const methods = (r.methods ?? []) as string[];
  const mode = methods.length > 1 ? 'Split' : METHOD[methods[0]] ?? (ol ? OL_METHOD[ol.payment_method] ?? 'Online' : 'Not chosen');
  const onlinePaid = ol?.payment_status === 'paid' || ol?.payment_status === 'refunded';
  const payStatus = refunded > 0 ? (refunded >= total ? `Refunded · ${rupees(refunded)}` : 'Partially refunded')
    : paid >= total && paid > 0 ? 'Paid' : onlinePaid ? 'Paid' : paid > 0 ? `Part paid · ${rupees(total - paid)} due` : cancelled ? 'Not captured' : `Unpaid · ${rupees(total)} due`;
  const units = Number(r.units);
  let delivery: string, when: string;
  if (cancelled) { delivery = 'Cancelled · not dispatched'; when = 'Not delivered'; }
  else if (completed) {
    const at = f?.completed_at ?? ol?.delivered_at ?? r.paid_at;
    delivery = f ? `Delivered · ${Number(f.units_picked)} of ${units} units` : ol ? 'Delivered' : 'Completed at counter';
    when = at ? `${day(at)} · ${time(at)}` : 'Time not recorded';
  } else if (f) {
    delivery = ({ awaiting_acceptance: 'Awaiting acceptance · not dispatched', picking: `Picking · ${f.units_picked} of ${units} units`, picked: 'Picked · not packed',
      ready: f.exception ? 'Dispatch blocked · not handed over' : 'Ready · not handed over', dispatched: f.exception ? 'Delivery issue · in transit' : 'In transit' } as Row)[f.stage] ?? 'In progress';
    when = f.stage === 'dispatched' ? 'Not delivered · ETA unavailable' : 'Not delivered';
  } else if (ol) {
    delivery = ({ placed: 'Awaiting acceptance', accepted: 'Preparing', packed: 'Packed · waiting for rider', out: 'Out for delivery' } as Row)[ol.status] ?? 'In progress';
    when = 'Not delivered';
  } else { delivery = 'Not started · bill unpaid'; when = 'Not delivered'; }
  // where the order is, in the words of the Online order tab (founder, 27 Oct 2026):
  //   new (waiting to be accepted) · ongoing (being packed, or on the way) · ready (packed, waiting for a delivery partner)
  //   · delivered · return (delivered, and the customer asked for a return) · cancelled · counter (a bill at the counter: not an online order)
  const asked = r.return_status === 'requested' || r.return_status === 'approved';
  const fs_ = f?.stage as string | undefined, os = ol?.status as string | undefined;
  const state = cancelled ? 'cancelled'
    : asked ? 'return'
    : completed ? (f || ol ? 'delivered' : 'counter')
    : fs_ === 'awaiting_acceptance' || os === 'placed' ? 'new'
    : (fs_ === 'ready' && !f?.exception) || os === 'packed' ? 'ready'
    : f || ol ? 'ongoing'
    : 'counter';
  const missing = Number(f?.units_missing ?? 0);
  const damages = [refunded > 0 ? `${rupees(refunded)} issued` : null, missing ? plural(missing, 'missing unit') : null].filter(Boolean).join(' · ') || 'None';
  return {
    id: r.id, display_no: r.display_no, channel_label: channelLabel(r), customer: r.customer_name || 'Guest', placed_at: `${dayYear(r.created_at)} · ${time(r.created_at)}`,
    status: cancelled ? 'cancelled' : completed ? 'completed' : 'pending', status_label: cancelled ? 'Cancelled' : completed ? 'Completed' : 'Pending',
    total, items: `${plural(Number(r.lines), 'line')} · ${plural(units, 'unit')}`, payment_status: payStatus, payment_mode: mode,
    delivery_status: delivery, delivery_time: when, refund_damages: damages,
    state, return_status: r.return_status ?? null,
  };
}

// ---------------------------------------------------------------- handlers
export async function history(request: Request) {
  const { searchParams } = new URL(request.url);
  const filter = searchParams.get('filter') ?? 'all';
  if (!['all', 'completed', 'pending', 'cancelled'].includes(filter)) throw new HttpError(400, 'Unknown filter.', undefined, 'bad_request');
  const before = searchParams.get('before') ?? '';
  if (before && Number.isNaN(Date.parse(before))) throw new HttpError(400, 'Unknown position in the list.', undefined, 'bad_request');
  const rows = await call<Row[]>(asCaller(request), 'pos_order_history', { filter, q: text(searchParams.get('q'), 60), before });
  return { orders: (rows ?? []).map(shapeCard) };
}

export async function catalog(request: Request) {
  const q = text(new URL(request.url).searchParams.get('q'), 60).replace(/[%_,()]/g, '');
  let query = asCaller(request).from('menu_items').select('id, name, price').eq('is_available', true).order('name').limit(60);
  if (q) query = query.ilike('name', `%${q}%`);
  const { data, error } = await query;
  if (error) dbFail(error);
  return { items: (data ?? []).map(i => ({ id: i.id, name: i.name, price: Number(i.price) })) };
}

export async function quote(request: Request) {
  const body = await readBody(request);
  const coupon = text(body.coupon_code, 40);
  return call(asCaller(request), 'pos_quote_order', { lines: lines(body.lines), ...(coupon ? { coupon_code: coupon } : {}) });
}

export async function checkout(request: Request, hold: boolean) {
  const body = await readBody(request);
  const key = requiredKey(request);
  const client = asCaller(request);
  const coupon = text(body.coupon_code, 40);
  const reason = hold ? text(body.reason, 200) : '';
  const out = await call<Row>(client, hold ? 'pos_hold_place' : 'pos_checkout', {
    idempotency_key: key, hold, lines: lines(body.lines), method: text(body.method, 10), tendered: hold ? null : money(body.tendered),
    ...(reason ? { reason } : {}),
    reference: text(body.reference, 80) || null, customer_name: text(body.customer_name, 80) || null, customer_phone: text(body.customer_phone, 20) || null, notes: text(body.notes, 200) || null,
    ...(coupon ? { coupon_code: coupon } : {}),
  });
  return { ...(await view(client, out.order_id)), replayed: !!out.replayed };
}

async function view(client: SupabaseClient, id: string) {
  return shapeView(await call<Row>(client, 'pos_order_view', { order_id: id }));
}

export async function getOne(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  return view(asCaller(request), id);
}

export async function pay(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  const client = asCaller(request);
  const out = await call<Row>(client, 'pos_checkout_pay', {
    order_id: id, idempotency_key: requiredKey(request), method: text(body.method, 10), tendered: money(body.tendered),
    reference: text(body.reference, 80) || null, expected_updated_at: typeof body.version === 'string' ? body.version : '',
  });
  return { ...(await view(client, id)), replayed: !!out.replayed };
}

export async function cancel(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  const reason = text(body.reason, 200);
  if (reason.length < 3) throw new HttpError(400, 'Say why the bill is cancelled.', undefined, 'bad_request');
  const client = asCaller(request);
  await call(client, 'pos_set_order_status', { order_id: id, to: 'cancelled', reason, expected_updated_at: typeof body.version === 'string' ? body.version : '' });
  return view(client, id);
}

const FULFIL = ['accept', 'pick', 'report_missing', 'pack', 'handover', 'dispatch', 'set_delivery_info', 'choose_collection', 'confirm_delivery', 'report_delivery_issue', 'return_to_store'];
const ONLINE: Record<string, 'accept' | 'reject' | 'ready'> = { online_accept: 'accept', online_reject: 'reject', online_ready: 'ready' };

export async function actOn(request: Request, id: string) {
  if (!uuid(id)) throw new HttpError(404, 'Order not found.', undefined, 'not_found');
  const body = await readBody(request);
  const action = text(body.action, 40);
  const client = asCaller(request);
  // No "packed" without a photo of the packed bag, or a reason there is none, when the store asks for one (returns spec §6).
  if (action === 'pack' || action === 'online_ready') {
    const ok = await call<Row>(client, 'pos_packed_photo_ok', { order_id: id });
    if (!ok?.ok) throw new HttpError(409, 'Add a photo of the packed order first.', undefined, 'photo_needed');
  }
  if (ONLINE[action]) {
    // One Local orders keep their own state machine (ol_orders). The database function gw_online_order_act (0361) checks the order is the
    // caller's, that it is an online order and that their role may move orders, then runs ol_partner_act and records the delivery follow-up
    // as an outbox event. Nothing here uses a privileged key.
    await call(client, 'gw_online_order_act', { order_id: id, action: ONLINE[action], prep_minutes: Number(body.prep_minutes ?? 20), reason: text(body.reason, 200) });
    return view(client, id);
  }
  if (!FULFIL.includes(action)) throw new HttpError(400, 'Unknown action.', undefined, 'bad_request');
  if (!Number.isInteger(body.version)) throw new HttpError(400, 'Refresh the order and try again.', undefined, 'bad_request');
  const p: Row = { order_id: id, action, expected_version: body.version, idempotency_key: requiredKey(request) };
  if (action === 'pick' || action === 'report_missing') {
    if (!Array.isArray(body.lines)) throw new HttpError(400, 'Send the lines.', undefined, 'bad_request');
    p.lines = (body.lines as Row[]).slice(0, 50).map(l => ({ order_item_id: uuid(l?.order_item_id), qty: Number(l?.qty) }));
  }
  const d = (body.delivery ?? {}) as Row;
  if (action === 'set_delivery_info') p.delivery = { name: text(d.name, 80), phone: text(d.phone, 20), address: text(d.address, 300) };
  if (action === 'report_delivery_issue') p.note = text(body.note, 300);
  await call(client, 'pos_fulfilment_act', p);
  return view(client, id);
}
