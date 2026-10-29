// Ads with OneLocal coins (founder's sketch, 29 Oct 2026; C:onelocalhosted_ads_coins_2026-10-29.sql): the dashboard, a new ad
// (Banner / Reel / Pop-up, a 9:16 photo or video, From–To dates), stopping one, and topping up coins (1 coin = Rs 10).
// v2 (C:onelocalhosted_ads_v2_2026-10-29.sql): formats and approval-gated price rules, held vs spent coins, the campaign stages,
// accepting a price, pausing, change requests, disputes, reports and tracking.
import { z } from 'zod';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date again.');

export const None = z.object({}).loose();
const coins = z.number({ message: 'Enter the coins.' }).positive('Enter more than 0 coins.').max(1000000, 'That is too many coins.');
export const FORMATS = ['home_banner', 'reel', 'popup', 'category_banner', 'sponsored_product', 'sponsored_store', 'search', 'local_area', 'brand_awareness', 'lead_gen'] as const;
export const MODELS = ['per_day', 'per_week', 'fixed', 'cpc', 'cpm', 'cpl'] as const;
export const OBJECTIVES = ['awareness', 'product', 'service', 'store_visit', 'website', 'leads', 'launch', 'local', 'sales'] as const;
// a new campaign, or an edit of a draft / one OneLocal asked to change; draft: saved, not sent (the database checks the rest on send)
export const Save = z.object({
  id: id.optional(),
  draft: z.boolean().optional(),
  format_id: z.enum(FORMATS, { message: 'Choose where the ad shows.' }).optional(),
  ad_type: z.enum(['banner', 'reel', 'popup']).optional(),
  pricing_model: z.enum(MODELS, { message: 'Choose how you pay.' }).optional(),
  objective: z.enum(OBJECTIVES, { message: 'Choose what the ad is for.' }).optional(),
  media_kind: z.enum(['image', 'video'], { message: 'Upload a photo or a video.' }).optional(),
  media_path: z.string().trim().min(10, 'Upload the ad photo or video.').max(200).optional(),
  title: z.string().trim().max(40, 'The title can be up to 40 letters.').optional(),
  message: z.string().trim().max(60, 'The message can be up to 60 letters.').optional(),
  starts_on: day.optional(), ends_on: day.optional(),
  budget_coins: coins.optional(),
  target_area: z.string().trim().max(80, 'The area can be up to 80 letters.').optional(),
  website: z.string().trim().max(200, 'The link can be up to 200 letters.').optional(),
  accept_terms: z.boolean().optional(), ...key,
}).refine(b => b.format_id || b.ad_type, { message: 'Choose where the ad shows.', path: ['format_id'] });
export const Quote = z.object({ format_id: z.enum(FORMATS), pricing_model: z.enum(MODELS), starts_on: day.optional(), ends_on: day.optional(), budget_coins: coins.optional() });
export const Accept = z.object({ id, agree: z.boolean() });
export const Fund = z.object({ id });
export const Pause = z.object({ id, pause: z.boolean() });
export const ChangeRequest = z.object({ id, note: z.string().trim().min(3, 'Say what you want changed.').max(300, 'Keep it under 300 letters.') });
export const Dispute = z.object({
  ad_id: id,
  kind: z.enum(['billing', 'invalid_clicks', 'delivery', 'other'], { message: 'Choose what the problem is.' }),
  reason: z.string().trim().min(5, 'Tell OneLocal what went wrong.').max(500, 'Keep it under 500 letters.'),
  coins: coins.optional(),
});
export const Report = z.object({ id });
// the customer app: one impression, click, visit or lead with its own event id
export const Track = z.object({
  event_id: id, ad_id: id, kind: z.enum(['impression', 'click', 'visit', 'lead']),
});
export const Stop = z.object({ id });
export const TopUp = z.object({
  coins: z.number({ message: 'Choose how many coins.' }).int().min(10, 'Top up at least 10 coins.').max(100000, 'Top up at most 1,00,000 coins.'),
  method: z.enum(['gpay', 'phonepe', 'upi', 'card', 'netbanking'], { message: 'Choose how to pay.' }), ...key,
});

export const MEDIA_EXT: Record<string, string> = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm',
};
export const IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const VIDEO_MAX_BYTES = 50 * 1024 * 1024;
export const MediaAsk = z.object({
  content_type: z.string({ message: 'Upload a JPG, PNG or WEBP photo, or an MP4 video.' }).refine(t => t in MEDIA_EXT, 'Upload a JPG, PNG or WEBP photo, or an MP4 video.'),
  size: z.number().int().min(1, 'That file is empty.').max(VIDEO_MAX_BYTES, 'A video can be up to 50 MB.'),
}).refine(b => b.content_type.startsWith('video/') || b.size <= IMAGE_MAX_BYTES, { message: 'A photo can be up to 5 MB.', path: ['size'] });
export const MediaLink = z.object({ id });

// Advertising-only partners (C:onelocalhosted_advertisers_2026-10-29.sql): the sign-up, and the brand profile of any business.
const list = (max: number, len: number) => z.array(z.string().trim().max(len)).max(max).optional();
const brand = {
  brand_name: z.string().trim().max(80, 'The brand name can be up to 80 letters.').optional(),
  business_category: z.string().trim().max(60).optional(),
  website: z.string().trim().max(200, 'The link can be up to 200 letters.').optional(),
  representative_name: z.string().trim().max(80).optional(),
  representative_role: z.string().trim().max(60).optional(),
  target_locations: list(20, 60),
  objectives: z.array(z.enum(OBJECTIVES, { message: 'Choose your goals again.' })).max(9).optional(),
};
export const AdvSave = z.object({
  ...brand,
  gstin: z.string().trim().max(15).optional(),
  phone: z.string().trim().max(15).optional(),
  email: z.string().trim().max(200).optional(),
  formats: z.array(z.enum(FORMATS, { message: 'Choose the ad types again.' })).max(10).optional(),
});
export const AdvSubmit = z.object({ agree: z.boolean() });
export const ProfileSave = z.object({ ...brand, brand_name: z.string().trim().min(2, 'Enter your brand name.').max(80) });
