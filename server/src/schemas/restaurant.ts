// Request shape for the restaurant dashboard (database: migration 0491). A friendly first check; the organisation, outlet and role
// are checked again in the database.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
export const Dashboard = z.object({ location_id: id.nullish() }).loose();
// 0524: the restaurant home for one outlet or 'all' (summed over the outlets the person may see)
export const DashboardScope = z.object({ location_id: z.union([id, z.literal('all')]).nullish() }).loose();
