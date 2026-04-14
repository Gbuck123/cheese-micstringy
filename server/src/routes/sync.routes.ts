import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate, authorize } from '../middleware/auth';
import { syncBatchSchema, syncConfirmSchema } from '../schemas';
import * as syncCtrl from '../controllers/sync.controller';

const router = Router();

router.use(authenticate);

// Booth sync endpoints
router.post('/batch', validate(syncBatchSchema), syncCtrl.syncBatch);
router.post('/:booth_id/confirm', validate(syncConfirmSchema), syncCtrl.syncConfirm);
router.get('/:booth_id/status', syncCtrl.syncStatus);

// Presigned upload URLs for direct-to-S3 upload
router.post('/upload-urls', syncCtrl.getUploadUrls);

// Admin: force process queue
router.post('/:booth_id/force-process', authorize('admin', 'operator'), syncCtrl.forceProcessQueue);

export default router;
