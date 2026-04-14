import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate } from '../middleware/auth';
import { upload } from '../middleware/upload';
import { uploadLimiter } from '../middleware/rateLimiter';
import { paginationSchema, uuidParam } from '../schemas';
import * as capturesCtrl from '../controllers/captures.controller';

const router = Router();

router.use(authenticate);

router.get('/', validate(paginationSchema, 'query'), capturesCtrl.listCaptures);
router.get('/:id', validate(uuidParam, 'params'), capturesCtrl.getCapture);
router.get('/:id/download', validate(uuidParam, 'params'), capturesCtrl.getDownloadUrl);
router.post('/', uploadLimiter, upload.single('file'), capturesCtrl.uploadCapture);
router.delete('/:id', validate(uuidParam, 'params'), capturesCtrl.deleteCapture);

export default router;
