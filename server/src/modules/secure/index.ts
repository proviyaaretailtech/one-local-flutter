// The secret-bearing handlers. The gateway calls one of these instead of a database function ONLY when the work needs a secret
// (PARTNER_PII_KEY), the storage service or a third party. Each receives the user id from the verified token and the checked body;
// it must never trust the client for who the user is. They may use the service-role key; nothing else on the gateway does.
import type { Handler } from '../../http.ts';
import * as pii from './pii.ts';
import * as storage from './storage.ts';
import * as settingsFiles from './settings_files.ts';
import { me } from './me.ts';
import { webhook } from './payments.ts';

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
  partner_setup_image_slot: storage.imageSlot,
  partner_setup_image_attach: storage.imageAttach,
  pos_settings_file_slot: settingsFiles.fileSlot,
  pos_settings_file_attach: settingsFiles.fileAttach,
  pos_settings_file_link: settingsFiles.fileLink,
} satisfies Record<string, SecureHandler>;

/** Real HTTP endpoints (no user token): provider webhooks. */
export const webhookRoutes: { path: string; handler: Handler }[] = [
  { path: '/webhooks/razorpay', handler: webhook('razorpay') },
  { path: '/webhooks/cashfree', handler: webhook('cashfree') },
];

export { withImageLinks } from './storage.ts';
export { dropRemovedFile } from './settings_files.ts';
