// Request shapes for the store's Device manager (database: hosted_store_devices_2026-10-31.sql). A friendly first check; the database
// checks the store, the role, the address and the sizes again.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Choose a printer.' }).regex(UUID, 'Choose a printer.');

export const List = z.object({}).strict();
export const Save = z.object({
  id: id.nullish(),
  name: z.string().trim().min(1, 'Give the printer a name.').max(40, 'The name is up to 40 letters.'),
  printer_type: z.enum(['receipt', 'kot', 'label'], { message: 'Choose what the printer prints.' }),
  connection: z.enum(['lan', 'usb', 'bluetooth', 'system'], { message: 'Choose how the printer connects.' }),
  address: z.string().trim().max(80).optional(),
  paper_mm: z.union([z.literal(58), z.literal(80)]).optional(),
  label_size: z.enum(['', '38x25', '50x25', '50x30', '75x50', '100x50']).optional(),
  copies: z.number().int().min(1, 'Copies are 1 to 5.').max(5, 'Copies are 1 to 5.').optional(),
  auto_cut: z.boolean().optional(),
  is_default: z.boolean().optional(),
  model: z.string().trim().max(40).optional(),
}).strict();
export const Remove = z.object({ id }).strict();
export const Tested = z.object({ id, ok: z.boolean(), note: z.string().trim().max(120).optional() }).strict();
