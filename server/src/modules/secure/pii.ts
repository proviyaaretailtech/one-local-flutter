// Secret-bearing: PAN and bank account numbers are encrypted INSIDE the database with PARTNER_PII_KEY, which exists only on this server.
// The database function receives the key as an argument for the one call and never stores it. The caller is the verified token's user.
import { piiKey as configPiiKey } from '../../config.ts';
import { rpc } from '../../db.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { Bank, Tax } from '../../schemas/onboarding.ts';
import { Payment } from '../../schemas/setup.ts';
import { withImageLinks } from './storage.ts';
import type { SecureCtx } from './index.ts';

function piiKey(): string {
  const k = configPiiKey();
  if (!k) throw new HttpError(503, 'Saving these details is not available right now.', undefined, 'not_configured');
  return k;
}

export const saveTax = ({ userId, args }: SecureCtx) =>
  rpc('partner_app_save_tax', { p_user_id: userId, p: parse(Tax, args), p_key: piiKey() });

export function saveBank({ userId, args }: SecureCtx) {
  const { draft, ...fields } = parse(Bank, args);
  return rpc('partner_app_save_bank', { p_user_id: userId, p: fields, p_key: piiKey(), p_draft: draft === true });
}

// Same key as onboarding (0348): a settlement account copied from the application must decrypt with it.
export async function savePayment({ userId, args }: SecureCtx) {
  return withImageLinks(await rpc('partner_setup_save_payment', { p_user_id: userId, p: parse(Payment, args), p_key: piiKey() }));
}
