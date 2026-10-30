// Restaurant reports V1 (0636): the period (from/to, YYYY-MM-DD, at most a year; the database checks again), the outlet, and for the
// item report one dish whose bills to list. Every figure, rule and permission is the database's.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the dates again.');

export const Range = z.object({ from: day.optional(), to: day.optional(), location_id: id.nullish() })
  .refine(r => !r.from || !r.to || r.from <= r.to, { message: 'The end date is before the start date.', path: ['to'] });
export const Items = z.object({ from: day.optional(), to: day.optional(), location_id: id.nullish(), menu_item_id: id.nullish() })
  .refine(r => !r.from || !r.to || r.from <= r.to, { message: 'The end date is before the start date.', path: ['to'] });
