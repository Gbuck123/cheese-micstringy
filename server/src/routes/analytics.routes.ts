import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth';
import * as analyticsCtrl from '../controllers/analytics.controller';

const router = Router();

router.use(authenticate);
router.use(authorize('admin', 'operator'));

router.get('/events/:event_id', analyticsCtrl.getEventAnalytics);
router.get('/events/:event_id/realtime', analyticsCtrl.getRealtimeDashboard);
router.get('/events/:event_id/engagement', analyticsCtrl.getEngagement);
router.get('/events/:event_id/demographics', analyticsCtrl.getDemographics);
router.get('/events/:event_id/shares', analyticsCtrl.getShareBreakdown);
router.get('/events/:event_id/peak-hours', analyticsCtrl.getPeakHours);

// Track endpoint (less restricted for booth/guest use)
router.post('/track', authenticate, analyticsCtrl.trackEvent);

export default router;
