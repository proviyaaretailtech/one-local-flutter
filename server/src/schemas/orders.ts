// Request shapes for the Orders tab: Live orders board and Hold orders (database: migrations 0530-0531, spec specs/orders-live-hold). A friendly
// first check of the shape; the organisation, outlet, role, state and version are checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const channel = z.enum(['all', 'dine_in', 'takeaway', 'delivery', 'zomato', 'swiggy'], { message: 'Unknown channel.' }).optional();
const q = z.string().max(60, 'Search is up to 60 characters.').optional();
const reason = z.string({ message: 'Say why the bill is on hold.' }).trim().max(200, 'Keep the hold reason under 200 characters.').nullish();
const lines = z.array(z.object({
  menu_item_id: id,
  qty: z.number({ message: 'Each item needs a quantity from 1 to 99.' }).int('Each item needs a quantity from 1 to 99.').min(1, 'Each item needs a quantity from 1 to 99.').max(99, 'Each item needs a quantity from 1 to 99.'),
  // kept so the database can refuse changing a bill with weighed packs (instead of the weight being dropped here)
  weight_g: z.number().int().min(1).max(99999).optional(),
}), { message: 'Add between 1 and 50 items.' }).min(1, 'Add between 1 and 50 items.').max(50, 'Add between 1 and 50 items.');

export const Board = z.object({
  location_id: id.nullish(), channel, q,
  status: z.enum(['new', 'preparing', 'ready', 'dispatched', 'completed'], { message: 'Unknown status.' }).optional(),
}).loose();
// The restaurant Orders tab's channel cards (0607): today's OneLocal, Swiggy, Zomato and on-call delivery orders.
export const ChannelOrders = z.object({ location_id: id.nullish() }).loose();
// Accept a new delivery order (0610), by hand or by auto-accept; and turn auto-accept on or off.
export const ChannelAccept = z.object({ location_id: id.nullish(), order_id: id, auto: z.boolean().optional() }).loose();
// 0619: a delivery update on an online order: ready, out for delivery (rider, number, minutes) or delivered / picked up.
export const ChannelDelivery = z.object({
  location_id: id.nullish(), order_id: id, step: z.enum(['ready', 'out', 'delivered'], { message: 'Unknown step.' }),
  rider_name: z.string().max(60).nullish(), rider_phone: z.string().max(20).nullish(), eta_minutes: z.number().int().min(1).max(240).nullish(),
  // 0620: how money due at the door was collected, on delivered
  payment_method: z.enum(['cash', 'upi', 'card'], { message: 'Paid by cash, UPI or card.' }).nullish(),
}).loose();
export const AutoAcceptSet = z.object({ location_id: id.nullish(), on: z.boolean({ message: 'on is true or false.' }) }).loose();
export const HoldList = z.object({ location_id: id.nullish(), channel, q }).loose();
export const HoldUpdate = z.object({
  order_id: id,
  expected_updated_at: z.string({ message: 'Refresh the held bill and try again.' }).min(10, 'Refresh the held bill and try again.').max(40),
  lines: lines.optional(),
  reason,
  // a held bill's customer, changed from its card (27 Oct 2026)
  customer_name: z.string().trim().max(80, 'Keep the customer name under 80 characters.').optional(),
  customer_phone: z.string().regex(/^\d{0,15}$/, 'The mobile number can only have digits.').optional(),
  idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional(),
}).loose();
