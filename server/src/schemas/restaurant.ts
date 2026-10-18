// Request shape for the restaurant dashboard (database: migration 0491). A friendly first check; the organisation, outlet and role
// are checked again in the database.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
export const Dashboard = z.object({ location_id: id.nullish() }).loose();
