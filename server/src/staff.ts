// Staff identity for the POS: membership and role come from org_users and roles (the OS tables).
import { signedInUserId } from './auth.ts';
import { db, fromDbError } from './db.ts';
import { HttpError, limit } from './http.ts';

export type Staff = { userId: string; email: string; name: string; role: string; organizationId: string; organizationName: string };

/** A signed-in person with an active staff membership. A person on staff at several businesses gets their earliest membership. */
export async function requireStaff(request: Request): Promise<Staff> {
  const userId = await signedInUserId(request);
  if (!userId) throw new HttpError(401, 'Sign in to continue.');
  limit(userId, 'staff', 300, 60_000);
  const { data, error } = await db().from('org_users')
    .select('user_id, email, full_name, role:roles(slug), organization:organizations(id, name)')
    .eq('user_id', userId)
    .eq('status', 'active')
    .order('created_at', { ascending: true })
    .limit(1)
    .maybeSingle();
  if (error) fromDbError(error);
  if (!data) throw new HttpError(403, 'You are not a staff member of any restaurant on One Local.');
  const role = (data.role as { slug?: string } | null)?.slug ?? '';
  const org = data.organization as { id?: string; name?: string } | null;
  if (!org?.id) throw new HttpError(403, 'Restaurant not found.');
  return { userId, email: data.email ?? '', name: data.full_name ?? '', role, organizationId: org.id, organizationName: org.name ?? '' };
}

/** A signed-in person, nothing more: for routes that run entirely AS the caller, where the database (row-level security and the function's own checks) decides what they may see or do. */
export async function requireSignedIn(request: Request, bucket: string, max = 600): Promise<string> {
  const id = await signedInUserId(request);
  if (!id) throw new HttpError(401, 'Sign in to continue.');
  limit(id, bucket, max, 60_000);
  return id;
}
