import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate, authorize } from '../middleware/auth';
import { registerBoothSchema, boothHeartbeatSchema, uuidParam } from '../schemas';
import * as boothsCtrl from '../controllers/booths.controller';

const router = Router();

router.use(authenticate);

router.get('/', boothsCtrl.listBooths);
router.get('/:id', validate(uuidParam, 'params'), boothsCtrl.getBooth);
router.post('/register', authorize('admin', 'operator'), validate(registerBoothSchema), boothsCtrl.registerBooth);
router.post('/:id/heartbeat', validate(uuidParam, 'params'), validate(boothHeartbeatSchema), boothsCtrl.heartbeat);
router.post('/:id/assign-event', authorize('admin', 'operator'), validate(uuidParam, 'params'), boothsCtrl.assignEvent);

export default router;
