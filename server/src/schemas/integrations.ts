// Request shapes for Settings -> Integrations (Petpooja, GoFrugal; database: db/migrations/pos_integrations.sql). A friendly first check;
// the database checks the provider, the caller's business and role again. Connect bodies are strict: no field the handler does not name
// can reach the database.
import { z } from 'zod';

export const PROVIDERS = ['petpooja', 'gofrugal'] as const;
export type Provider = (typeof PROVIDERS)[number];
export const PROVIDER_NAME: Record<Provider, string> = { petpooja: 'Petpooja', gofrugal: 'GoFrugal' };

const provider = z.enum(PROVIDERS, { message: 'Choose Petpooja or GoFrugal.' });

/** A key as the provider hands it out: printable, no spaces, 4 to 256 characters. */
const key = (label: string) =>
  z.string({ message: `Enter the ${label}.` }).trim()
    .min(1, `Enter the ${label}.`)
    .min(4, `The ${label} looks too short. Paste it again.`)
    .max(256, `The ${label} is too long. Paste it again.`)
    .regex(/^[\x21-\x7e]+$/, `The ${label} has spaces or characters a key never has. Paste it again.`);

const ident = (msg: string) => z.string({ message: msg }).trim().min(1, msg).max(64, msg).regex(/^[A-Za-z0-9_-]+$/, msg);

export const Empty = z.object({}).loose();
export const Which = z.object({ provider }).strict();
export const AnyProvider = z.object({ provider }).loose();

export const PetpoojaConnect = z.object({
  provider: z.literal('petpooja'),
  restaurant_id: ident('Enter the Petpooja restaurant ID exactly as Petpooja gave it.'),
  app_key: key('app key'),
  app_secret: key('app secret'),
  access_token: key('access token'),
}).strict();

/** "store.example.com/WebReporter" -> "http://store.example.com/WebReporter" (no trailing slash). Only http(s), no user:password@. */
export function storeUrl(raw: string): string | null {
  const s = raw.trim();
  let u: URL;
  try { u = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(s) ? s : `http://${s}`); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password || u.search || u.hash || !u.hostname) return null;
  return `${u.origin}${u.pathname}`.replace(/\/+$/, '');
}

const STORE_URL_MSG = 'Enter the GoFrugal store URL, for example http://yourstore.example.com/WebReporter.';
export const GofrugalConnect = z.object({
  provider: z.literal('gofrugal'),
  store_url: z.string({ message: STORE_URL_MSG }).max(300, STORE_URL_MSG).transform((s, ctx) => {
    const u = storeUrl(s);
    if (!u) { ctx.addIssue({ code: 'custom', message: STORE_URL_MSG }); return z.NEVER; }
    return u;
  }),
  api_key: key('API key'),
  outlet_id: z.union([ident('The outlet ID can have letters, digits, - and _ only.'), z.literal('')]).optional(),
}).strict();

export const Sync = z.object({ provider, menu: z.boolean().optional(), orders: z.boolean().optional(), stock: z.boolean().optional() })
  .strict()
  .refine(v => v.menu !== undefined || v.orders !== undefined || v.stock !== undefined, { message: 'Choose what to sync.' });
