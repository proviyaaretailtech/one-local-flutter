// Request shapes for the Team functions (database: migration 0440, section L). A friendly first check of the shape of the request; every rule
// (organisation, place, role, ceiling, state) is checked again in the database. Extra keys are kept (`loose`): the database reads its own fields.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const loc = { location_id: id.nullish() };
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();

export const Options = obj({});
export const Dashboard = obj({ ...loc });
export const UserList = obj({ ...loc, filter: z.enum(['all', 'active', 'invited', 'paused'], { message: 'Unknown filter.' }).optional(), q: z.string().max(100).optional(), limit: z.number().int().min(1).max(200).optional() });
export const UserView = obj({ id });
export const RoleView = obj({ slug: z.string({ message: 'Choose a role.' }).min(1).max(60) });
export const Activity = obj({ ...loc, range: z.enum(['today', '7d'], { message: 'Unknown range.' }).optional(), limit: z.number().int().min(1).max(50).optional(), before: z.string().max(40).optional() });
export const TaskList = obj({ ...loc, filter: z.enum(['all', 'in_progress', 'overdue', 'done'], { message: 'Unknown filter.' }).optional() });
export const TaskView = obj({ id });
export const Invite = obj({
  ...loc, full_name: z.string({ message: 'Enter the person\'s full name.' }).max(120), mobile: z.string({ message: 'Enter a valid 10-digit mobile number.' }).max(30),
  email: z.string({ message: 'Enter a valid email address.' }).max(200), role_slug: z.string({ message: 'Choose a role.' }).max(60), resend: z.boolean().optional(),
});
export const InviteAct = obj({ id, action: z.enum(['resend', 'revoke'], { message: 'Unknown action.' }) });
export const UserAct = obj({ id, action: z.enum(['set_role', 'set_locations', 'suspend', 'reactivate'], { message: 'Unknown action.' }), role_slug: z.string().max(60).optional(), location_ids: z.array(id).max(50).optional() });
export const TaskSave = obj({
  ...loc, ...key, id: id.optional(), version: z.number().int().optional(), title: z.string({ message: 'Give the task a short title.' }).max(120), description: z.string().max(1000).optional(),
  priority: z.enum(['low', 'medium', 'high'], { message: 'Priority must be low, medium or high.' }).optional(), assignee_staff_id: id.nullish(), due_at: z.string().max(40).nullish(),
  photo_required: z.boolean().optional(), approval_required: z.boolean().optional(), checklist: z.array(z.string().max(120)).max(30).optional(),
});
export const TaskAct = obj({ id, version: z.number().int({ message: 'version is required' }), action: z.enum(['start', 'submit', 'complete', 'fail', 'reassign', 'cancel'], { message: 'Unknown action.' }), note: z.string().max(500).nullish(), assignee_staff_id: id.nullish() });
