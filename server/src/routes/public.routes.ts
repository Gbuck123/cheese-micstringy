import { Router } from 'express';
import { validate } from '../middleware/validate';
import { paginationSchema } from '../schemas';
import { getEventBySlug } from '../controllers/events.controller';
import { getSessionByCode } from '../controllers/sessions.controller';
import { listGalleryCaptures } from '../controllers/captures.controller';
import { qrService } from '../services/qr.service';

const router = Router();

// Public event gallery
router.get('/events/:slug', getEventBySlug);

// Public session by code (QR scan landing)
router.get('/sessions/:code', getSessionByCode);

// Public gallery captures
router.get('/gallery/:event_id/captures', validate(paginationSchema, 'query'), listGalleryCaptures);

// Short URL redirect
router.get('/s/:code', async (req, res) => {
  const targetUrl = await qrService.resolveShortUrl(req.params.code);
  if (!targetUrl) {
    return res.status(404).json({ error: { message: 'Link not found or expired' } });
  }
  res.redirect(302, targetUrl);
});

export default router;
