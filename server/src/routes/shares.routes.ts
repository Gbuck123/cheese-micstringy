import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate } from '../middleware/auth';
import { shareEmailSchema, shareSmsSchema } from '../schemas';
import * as sharesCtrl from '../controllers/shares.controller';

const router = Router();

// Authenticated share endpoints
router.post('/email', authenticate, validate(shareEmailSchema), sharesCtrl.shareViaEmail);
router.post('/sms', authenticate, validate(shareSmsSchema), sharesCtrl.shareViaSms);

// Webhooks (no auth - verified by service signatures)
router.post('/webhooks/sendgrid', sharesCtrl.emailWebhook);
router.post('/webhooks/twilio', sharesCtrl.smsStatusCallback);

export default router;
