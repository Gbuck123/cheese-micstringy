import { Request, Response, NextFunction } from 'express';
import { analyticsService } from '../services/analytics.service';

export async function getEventAnalytics(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const { start_date, end_date } = req.query as Record<string, string>;

    const analytics = await analyticsService.getEventAnalytics(
      event_id,
      start_date,
      end_date
    );

    res.json({ analytics });
  } catch (error) {
    next(error);
  }
}

export async function getRealtimeDashboard(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const minutes = parseInt((req.query.minutes as string) || '60', 10);

    const data = await analyticsService.getRealtimeDashboard(event_id, minutes);

    res.json(data);
  } catch (error) {
    next(error);
  }
}

export async function getEngagement(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const metrics = await analyticsService.getEngagementMetrics(event_id);

    res.json({ engagement: metrics });
  } catch (error) {
    next(error);
  }
}

export async function getDemographics(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const data = await analyticsService.getGuestDemographics(event_id);

    res.json({ demographics: data });
  } catch (error) {
    next(error);
  }
}

export async function getShareBreakdown(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const data = await analyticsService.getShareBreakdown(event_id);

    res.json({ share_breakdown: data });
  } catch (error) {
    next(error);
  }
}

export async function getPeakHours(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const data = await analyticsService.getPeakHours(event_id);

    res.json({ peak_hours: data });
  } catch (error) {
    next(error);
  }
}

export async function trackEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const { action, event_id, session_id, booth_id, metadata } = req.body;

    await analyticsService.track({
      event_id,
      session_id,
      booth_id,
      action,
      metadata,
      ip_address: req.ip,
      user_agent: req.get('User-Agent'),
    });

    res.status(202).json({ message: 'Event tracked' });
  } catch (error) {
    next(error);
  }
}
