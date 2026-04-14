import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate } from '../middleware/auth';
import { createSessionSchema, endSessionSchema, paginationSchema, uuidParam } from '../schemas';
import * as sessionsCtrl from '../controllers/sessions.controller';

const router = Router();

router.use(authenticate);

router.get('/', validate(paginationSchema, 'query'), sessionsCtrl.listSessions);
router.get('/:id', validate(uuidParam, 'params'), sessionsCtrl.getSession);
router.post('/', validate(createSessionSchema), sessionsCtrl.createSession);
router.post('/:id/end', validate(uuidParam, 'params'), validate(endSessionSchema), sessionsCtrl.endSession);

export default router;
