// Request shapes for the storefront functions (database: migrations 0450-0451, section M). A friendly first check of the shape; every rule
// (organisation, role, lengths, colours, references, versions) is checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();

export const None = obj({});
export const Products = obj({ filter: z.enum(['all', 'best_sellers', 'on_offer'], { message: 'Unknown filter.' }).optional(), q: z.string().max(100).optional(),
  limit: z.number().int().min(1).max(50).optional(), offset: z.number().int().min(0).max(100_000).optional() });
export const ProductSave = obj({ id });
export const DraftSave = obj({ expected_draft_version: z.number().int({ message: 'Reload the page builder and try again.' }), definition: z.record(z.string(), z.unknown()) });
export const DraftDiscard = obj({ expected_draft_version: z.number().int().optional() });
export const Publish = obj({ expected_version: z.number().int({ message: 'Reload the page builder and try again.' }), expected_draft_version: z.number().int().optional() });
export const Preview = obj({ source: z.enum(['draft', 'published'], { message: 'Source is draft or published.' }).optional() });
export const ImageLibrary = obj({ kind: z.enum(['banner', 'category', 'product', 'card', 'ad']).optional() });
export const OfferAct = obj({ id: z.string().min(1).max(80), action: z.enum(['pause', 'resume', 'end', 'delete'], { message: 'Unknown action.' }) });
export const AdAct = obj({ id, action: z.enum(['enable', 'disable', 'end', 'delete'], { message: 'Unknown action.' }) });

export const IMAGE_KINDS = ['banner', 'category', 'product', 'card', 'ad'] as const;
export const IMAGE_EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
export const IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const ImageAsk = z.object({
  kind: z.enum(IMAGE_KINDS, { message: 'Unknown picture type.' }),
  content_type: z.string().refine(t => t in IMAGE_EXT, 'Upload a JPG, PNG or WebP.'),
  size: z.number().int().min(1, 'That file is empty.').max(IMAGE_MAX_BYTES, 'Each image can be up to 5 MB.'),
});
export const ImageAttach = ImageAsk.extend({ path: z.string().min(5).max(300) });
