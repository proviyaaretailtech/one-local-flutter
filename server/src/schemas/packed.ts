// Packed-order photo (founder, 29 Oct 2026; C:onelocalhosted_packed_photo_2026-10-29.sql): before an order leaves the store, the seller
// takes a photo of the packed bag, or says why there is none. A friendly first check; the database checks the order and the path again.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const order_id = z.string({ message: 'Order not found.' }).regex(UUID, 'Order not found.');

export const PHOTO_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
export const PHOTO_MAX_BYTES = 5 * 1024 * 1024;
export const PhotoAsk = z.object({
  order_id,
  content_type: z.string({ message: 'Take the photo again.' }).refine(t => t in PHOTO_EXT, 'Take the photo again.'),
  size: z.number().int().min(1, 'That photo is empty.').max(PHOTO_MAX_BYTES, 'The photo can be up to 5 MB.'),
});
export const PhotoSave = z.object({
  order_id,
  path: z.string().trim().max(200).optional(),
  skip_reason: z.string().trim().min(3, 'Say why there is no photo.').max(200, 'Keep the reason under 200 letters.').optional(),
}).refine(b => !!b.path !== !!b.skip_reason, { message: 'Add a photo of the packed order, or say why there is none.' });
export const PhotoLink = z.object({ order_id });
