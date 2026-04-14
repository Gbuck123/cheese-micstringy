import { Router } from 'express';
import authRouter from './auth.routes';
import eventsRouter from './events.routes';
import sessionsRouter from './sessions.routes';
import capturesRouter from './captures.routes';
import sharesRouter from './shares.routes';
import boothsRouter from './booths.routes';
import analyticsRouter from './analytics.routes';
import syncRouter from './sync.routes';
import publicRouter from './public.routes';

const router = Router();

router.use('/auth', authRouter);
router.use('/events', eventsRouter);
router.use('/sessions', sessionsRouter);
router.use('/captures', capturesRouter);
router.use('/shares', sharesRouter);
router.use('/booths', boothsRouter);
router.use('/analytics', analyticsRouter);
router.use('/sync', syncRouter);
router.use('/public', publicRouter);

export default router;
