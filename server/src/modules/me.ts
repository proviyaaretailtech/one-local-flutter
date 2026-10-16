// GET /api/partner/me: who the signed-in person is and which business they work for (the app's sign-in check).
import { db, fromDbError } from '../db.ts';
import type { Staff } from '../staff.ts';

async function getOutlet(staff: Staff) {
  const { data, error } = await db().from('ol_merchant_channels').select('*').eq('organization_id', staff.organizationId).maybeSingle();
  if (error) fromDbError(error);
  return data
    ? { accepting: data.accepting, back_at: data.back_at, default_prep_minutes: data.default_prep_minutes, accept_window_seconds: data.accept_window_seconds, missed_in_a_row: data.missed_in_a_row, address: data.address, set_up: true }
    : { accepting: false, back_at: null, default_prep_minutes: 20, accept_window_seconds: 60, missed_in_a_row: 0, address: null, set_up: false };
}

export async function me(staff: Staff) {
  const outlet = await getOutlet(staff);
  return {
    person: { id: staff.userId, email: staff.email, name: staff.name, role: staff.role, organization_id: staff.organizationId },
    restaurant: { id: staff.organizationId, name: staff.organizationName, ...outlet },
  };
}
