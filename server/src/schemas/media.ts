// Request shapes for the product media pool (database: hosted_media_pool_2026-10-30.sql). A friendly first check; the database checks the
// store, the role, ownership of the photo, the review state and platform-admin rights again.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const item = z.string({ message: 'Choose an item.' }).regex(UUID, 'Choose an item.');
const pool = z.string({ message: 'Choose a photo.' }).regex(UUID, 'Choose a photo.');
const q = z.string().max(80, 'Search is up to 80 characters.').optional();

export const StorePool = z.object({ q }).strict();
export const Offer = z.object({ menu_item_id: item }).strict();
export const Withdraw = z.object({ pool_id: pool }).strict();
export const Search = z.object({ q, menu_item_id: item.optional() }).strict();
export const Use = z.object({ pool_id: pool, menu_item_id: item }).strict();
export const Queue = z.object({
  status: z.enum(['submitted', 'approved', 'rejected'], { message: 'Unknown status.' }).optional(),
  store_category: z.string().max(60).optional(),
}).strict();
export const Decide = z.object({
  pool_id: pool,
  decision: z.enum(['approve', 'reject'], { message: 'Decide approve or reject.' }),
  note: z.string().trim().max(300, 'Keep the note under 300 characters.').optional(),
}).strict();
