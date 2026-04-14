import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate, authorize } from '../middleware/auth';
import { createEventSchema, updateEventSchema, paginationSchema, uuidParam } from '../schemas';
import * as eventsCtrl from '../controllers/events.controller';

const router = Router();

router.use(authenticate);

router.get('/', validate(paginationSchema, 'query'), eventsCtrl.listEvents);
router.get('/:id', validate(uuidParam, 'params'), eventsCtrl.getEvent);
router.post('/', authorize('admin', 'operator'), validate(createEventSchema), eventsCtrl.createEvent);
router.put('/:id', authorize('admin', 'operator'), validate(uuidParam, 'params'), validate(updateEventSchema), eventsCtrl.updateEvent);
router.delete('/:id', authorize('admin', 'operator'), validate(uuidParam, 'params'), eventsCtrl.deleteEvent);

export default router;
