// Request shapes for the notification centre, announcement centre and customer messages (database: migration 0460, section N).
// A friendly first check; every rule (organisation, role, consent, state) is checked again in the database. Extra keys are kept.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const category = z.enum(['orders', 'payments', 'inventory', 'account'], { message: 'Unknown category.' });
const channel = z.enum(['whatsapp', 'sms', 'email', 'push'], { message: 'Unknown channel.' });
const segment = z.union([z.literal('all'), id]);
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();

export const NoticeList = obj({ category: category.optional(), limit: z.number().int().min(1).max(100).optional(), before: z.string().max(40).optional(), location_id: id.nullish() });
export const NoticeMarkRead = obj({ ids: z.array(id).min(1).max(200).optional(), all: z.boolean().optional(), category: category.optional() });
export const AnnounceList = obj({});
export const AnnounceMarkRead = obj({ id: id.optional(), all: z.boolean().optional() });
export const CommOptions = obj({});
export const CommAudience = obj({ segment: segment.optional(), channel });
export const CommQueue = obj({
  channel, segment: segment.optional(), title: z.string().max(120, 'The title is too long.').optional(),
  message: z.string().trim().min(1, 'Write a message.').max(1000, 'The message is too long.'), name: z.string().max(60).optional(),
  schedule_at: z.string().max(40).nullish(), idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional(),
});
export const CommList = obj({ limit: z.number().int().min(1).max(100).optional() });
export const CommCancel = obj({ id });
export const FeedbackList = obj({ status: z.enum(['new', 'acknowledged', 'resolved'], { message: 'Unknown status.' }).optional(), limit: z.number().int().min(1).max(100).optional() });
export const FeedbackRespond = obj({ id, status: z.enum(['acknowledged', 'resolved'], { message: 'Choose acknowledged or resolved.' }), response: z.string().max(1000, 'The reply is too long.').optional() });
