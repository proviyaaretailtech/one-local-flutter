// The secret-bearing handlers. The gateway calls one of these instead of a database function ONLY when the work needs a secret
// (PARTNER_PII_KEY, ANTHROPIC_API_KEY, REMOVE_BG_API_KEY), the storage service or a third party. Each receives the user id from the verified token and the checked body;
// it must never trust the client for who the user is. They may use the service-role key; nothing else on the gateway does.
import type { Handler } from '../../http.ts';
import * as pii from './pii.ts';
import * as storage from './storage.ts';
import * as storefront from './storefront.ts';
import * as settingsFiles from './settings_files.ts';
import * as itemPhotos from './itemPhotos.ts';
import * as moneyProofs from './moneyProofs.ts';
import * as adMedia from './adMedia.ts';
import * as packedPhotos from './packedPhotos.ts';
import { me } from './me.ts';
import { webhook } from './payments.ts';
import { describeDish } from './menuAi.ts';
import { removeBackground } from './removeBg.ts';
import { smsHook } from './smsHook.ts';

export type SecureCtx = { request: Request; userId: string; args: Record<string, unknown> };
export type SecureHandler = (ctx: SecureCtx) => Promise<unknown>;

export const secureHandlers = {
  me,
  partner_app_save_tax: pii.saveTax,
  partner_app_save_bank: pii.saveBank,
  partner_setup_save_payment: pii.savePayment,
  partner_app_document_slot: storage.documentSlot,
  partner_app_document_attach: storage.documentAttach,
  partner_app_document_preview: storage.documentPreview,
  partner_app_document_remove: storage.documentRemove,
  partner_setup_image_slot: storage.imageSlot,
  partner_setup_image_attach: storage.imageAttach,
  storefront_image_slot: storefront.imageSlot,
  storefront_image_attach: storefront.imageAttach,
  pos_settings_file_slot: settingsFiles.fileSlot,
  pos_settings_file_attach: settingsFiles.fileAttach,
  pos_settings_file_link: settingsFiles.fileLink,
  menu_ai_describe: ctx => describeDish(ctx),
  cat_image_remove_bg: ctx => removeBackground(ctx),
  cat_item_photo_slot: itemPhotos.photoSlot,
  cat_item_photo_attach: itemPhotos.photoAttach,
  cat_item_photo_remove: itemPhotos.photoRemove,
  smoney_proof_slot: moneyProofs.proofSlot,
  smoney_proof_link: moneyProofs.proofLink,
  ads_media_slot: adMedia.mediaSlot,
  ads_media_link: adMedia.mediaLink,
  pos_packed_photo_slot: packedPhotos.photoSlot,
  pos_packed_photo_link: packedPhotos.photoLink,
} satisfies Record<string, SecureHandler>;

/** Real HTTP endpoints (no user token): provider webhooks. */
export const webhookRoutes: { path: string; handler: Handler }[] = [
  { path: '/webhooks/razorpay', handler: webhook('razorpay') },
  { path: '/webhooks/cashfree', handler: webhook('cashfree') },
  // Supabase Auth "Send SMS" hook: sign-in codes for both apps, delivered by apitxt.com (signed by Supabase; see smsHook.ts)
  { path: '/hooks/send-sms', handler: smsHook() },
];

export { withImageLinks } from './storage.ts';
export { withStorefrontLinks } from './storefront.ts';
export { dropRemovedFile } from './settings_files.ts';
