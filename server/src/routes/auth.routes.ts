import { Router } from 'express';
import { validate } from '../middleware/validate';
import { authenticate } from '../middleware/auth';
import { authLimiter } from '../middleware/rateLimiter';
import { registerSchema, loginSchema, refreshTokenSchema } from '../schemas';
import * as authCtrl from '../controllers/auth.controller';

const router = Router();

router.post('/register', authLimiter, validate(registerSchema), authCtrl.register);
router.post('/login', authLimiter, validate(loginSchema), authCtrl.login);
router.post('/refresh', validate(refreshTokenSchema), authCtrl.refreshToken);
router.post('/logout', validate(refreshTokenSchema), authCtrl.logout);
router.post('/logout-all', authenticate, authCtrl.logoutAll);
router.get('/me', authenticate, authCtrl.me);

export default router;
