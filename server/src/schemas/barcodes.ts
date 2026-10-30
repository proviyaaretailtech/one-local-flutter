// Request shapes for store barcodes and loose (weighed) items (database: hosted_barcodes_weight_2026-10-30.sql). A friendly first check; the
// database checks the store, the role, duplicates and the weigh-label rules again.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Choose an item.' }).regex(UUID, 'Choose an item.');
const code = z.string({ message: 'Enter the code.' }).trim().min(1, 'Enter the code.').max(48, 'A barcode is up to 48 characters.');

export const List = z.object({ tab: z.enum(['missing', 'all', 'loose'], { message: 'Unknown tab.' }).optional(), q: z.string().max(60, 'Search is up to 60 characters.').optional() }).strict();
export const Make = z.object({ menu_item_id: id, replace: z.boolean().optional() }).strict();
export const MakeAll = z.object({}).strict();
export const Link = z.object({ menu_item_id: id, code, replace: z.boolean().optional() }).strict();
export const Custom = z.object({ code: code.optional(), menu_item_id: id.optional(), replace: z.boolean().optional() }).strict();
export const SetLoose = z.object({ menu_item_id: id, loose: z.boolean({ message: 'Say whether it is sold loose.' }) }).strict();
export const WeighLabel = z.object({
  menu_item_id: id,
  weight_g: z.number({ message: 'Enter the weight.' }).int('Enter the weight in whole grams.').min(1, 'Enter the weight.').max(99999, 'A pack is at most 99.999 kg.'),
}).strict();
export const Resolve = z.object({ code }).strict();
