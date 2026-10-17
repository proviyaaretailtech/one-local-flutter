// Shared by the gateway and the secret-bearing handlers: a zod parse that answers with the first message the app can show.
import { z } from 'zod';
import { HttpError } from './http.ts';

export function parse<T extends z.ZodTypeAny>(schema: T, raw: unknown): z.infer<T> {
  const r = schema.safeParse(raw);
  if (!r.success) {
    const first = r.error.issues[0];
    throw new HttpError(400, first?.message && first.message !== 'Required' ? first.message : `${first?.path.join('.') || 'request'}: please check this`, undefined, 'validation');
  }
  return r.data;
}

export const clean = (s: string) => s.replace(/\s+/g, ' ').trim();
export const text = (max: number, msg: string, min = 1) => z.string({ message: msg }).transform(clean).pipe(z.string().min(min, msg).max(max, msg));
export const hhmm = (msg: string) => z.string({ message: msg }).regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, msg);
export const amount = (msg: string) =>
  z.union([z.number(), z.string().trim().regex(/^(\d+(\.\d{1,2})?)?$/, msg).transform(s => (s === '' ? null : Number(s)))]).nullish();
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
