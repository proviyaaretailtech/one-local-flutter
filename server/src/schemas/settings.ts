// Request shapes for the settings and store-profile functions (database: migration 0470, section P). A friendly first check of the
// shape; every rule (phone digits, time order, roles, organisation) is checked again in the database, which answers with the sentence.
import { z } from 'zod';
import { hhmm, UUID } from '../validate.ts';

const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const str = (max: number, msg: string) => z.string({ message: msg }).max(max, msg);

export const Empty = obj({});
export const Hours = obj({ opens_at: hhmm('Choose an opening time.'), closes_at: hhmm('Choose a closing time.') });
export const Readiness = obj({ prep_minutes: z.union([z.number().int(), z.string().regex(/^[0-9]{1,4}$/).transform(Number)], { message: 'Enter the preparation time in minutes.' }) });
export const Help = obj({ name: str(120, 'Enter the contact name.'), phone: str(20, 'Enter a 10-digit mobile number.'), info: str(500, 'Help instructions can be up to 500 characters.').optional() });
export const Owner = obj({ name: str(120, 'Enter the owner name.'), phone: str(20, 'Enter a 10-digit mobile number.') });
export const StaffPhone = obj({ phone: str(20, 'Enter a 10-digit mobile number.') });
export const Switch = obj({ enabled: z.boolean({ message: 'Choose on or off.' }) });
export const Location = obj({ address: str(400, 'Enter the full store address.') });
export const Language = obj({ language: str(5, 'Choose a language.') });
export const DocumentRemove = obj({ id: z.string({ message: 'Choose a document.' }).regex(UUID, 'Choose a document.') });

export const FILE_KINDS = ['store_qr', 'document', 'feedback'] as const;
export const FILE_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
export const FILE_MAX_BYTES = 5 * 1024 * 1024;
export const FileAsk = z.object({
  kind: z.enum(FILE_KINDS, { message: 'Unknown file type.' }),
  content_type: z.string({ message: 'Upload a JPG, PNG or PDF.' }).refine(t => t in FILE_EXT, 'Upload a JPG, PNG or PDF.'),
  size: z.number().int().min(1, 'That file is empty.').max(FILE_MAX_BYTES, 'Each file can be up to 5 MB.'),
});
// Document details ride along with the attach call (they only matter for kind "document").
export const FileAttach = FileAsk.extend({
  path: z.string().min(5).max(300),
  name: str(120, 'Name the document.').optional(),
  doc_type: z.enum(['tax', 'food_safety', 'business', 'safety', 'liquor', 'environment', 'other'], { message: 'Choose a document type.' }).optional(),
  doc_no: str(60, 'The document number is too long.').optional(),
  expiry_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use the date format YYYY-MM-DD.').optional(),
});
export const FileLink = z.object({ kind: z.enum(['store_qr', 'document'], { message: 'Unknown file type.' }), id: z.string().regex(UUID, 'Not a valid id.').optional() });

export const SupportCreate = obj({
  kind: z.enum(['support', 'feedback'], { message: 'Unknown request type.' }).optional(),
  topic: z.enum(['orders', 'payments', 'inventory', 'account', 'other', 'feedback'], { message: 'Choose a topic.' }).optional(),
  message: z.string({ message: 'Tell us in 5 to 2000 characters.' }).trim().min(5, 'Tell us in 5 to 2000 characters.').max(2000, 'Tell us in 5 to 2000 characters.'),
  attachment_path: z.string().max(300).optional(),
  idempotency_key: z.string().trim().max(80).optional(),
});
