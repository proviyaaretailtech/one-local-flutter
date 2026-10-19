// Secret-bearing only in the sense that it reads with the service role: who the signed-in person is and which business they work for.
// The person comes from the verified token; the membership is read from org_users (an earliest active membership wins).
import { db, fromDbError } from '../../db.ts';
import { HttpError } from '../../http.ts';
import type { SecureCtx } from './index.ts';
import { kindOf } from '../home.ts';

export async function me({ userId }: SecureCtx) {
  const { data, error } = await db().from('org_users')
    .select('user_id, email, full_name, role:roles(slug), organization:organizations(id, name, business_domain)')
    .eq('user_id', userId).eq('status', 'active').order('created_at', { ascending: true }).limit(1).maybeSingle();
  if (error) fromDbError(error);
  if (!data) throw new HttpError(403, 'You are not a staff member of any restaurant on One Local.');
  const org = data.organization as { id?: string; name?: string; business_domain?: string | null } | null;
  if (!org?.id) throw new HttpError(403, 'Restaurant not found.');
  const { data: ch, error: e2 } = await db().from('ol_merchant_channels').select('*').eq('organization_id', org.id).maybeSingle();
  if (e2) fromDbError(e2);
  const outlet = ch
    ? { accepting: ch.accepting, back_at: ch.back_at, default_prep_minutes: ch.default_prep_minutes, accept_window_seconds: ch.accept_window_seconds, missed_in_a_row: ch.missed_in_a_row, address: ch.address, set_up: true }
    : { accepting: false, back_at: null, default_prep_minutes: 20, accept_window_seconds: 60, missed_in_a_row: 0, address: null, set_up: false };
  return {
    person: { id: userId, email: data.email ?? '', name: data.full_name ?? '', role: (data.role as { slug?: string } | null)?.slug ?? '', organization_id: org.id },
    restaurant: { id: org.id, name: org.name ?? '', ...outlet },
    // store | restaurant | service: decides the wording on the sign-in screens and which home opens.
    business_kind: kindOf(org.business_domain, null),
  };
}
