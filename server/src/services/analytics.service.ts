import { query } from '../config/database';

export interface EventAnalytics {
  summary: EventSummary;
  share_breakdown: ShareBreakdown[];
  capture_types: CaptureTypeBreakdown[];
  peak_hours: PeakHour[];
  engagement: EngagementMetrics;
  timeline: TimelinePoint[];
}

interface EventSummary {
  event_id: string;
  name: string;
  status: string;
  total_sessions: number;
  total_captures: number;
  total_shares: number;
  avg_session_duration_ms: number;
  total_retakes: number;
  unique_guests: number;
}

interface ShareBreakdown {
  channel: string;
  share_count: number;
  opened_count: number;
  clicked_count: number;
  open_rate_pct: number;
  click_rate_pct: number;
}

interface CaptureTypeBreakdown {
  capture_type: string;
  count: number;
  percentage: number;
}

interface PeakHour {
  hour_of_day: number;
  capture_count: number;
  session_count: number;
}

interface EngagementMetrics {
  total_sessions: number;
  total_captures: number;
  total_shares: number;
  avg_session_duration_seconds: number;
  avg_captures_per_session: number;
  retake_rate: number;
  share_rate: number;
  avg_time_to_first_share_seconds: number;
  repeat_guest_rate: number;
}

interface TimelinePoint {
  hour: string;
  capture_type: string;
  capture_count: number;
}

export class AnalyticsService {
  /**
   * Get comprehensive analytics for an event.
   */
  async getEventAnalytics(
    eventId: string,
    startDate?: string,
    endDate?: string
  ): Promise<EventAnalytics> {
    const [summary, shareBreakdown, captureTypes, peakHours, engagement, timeline] =
      await Promise.all([
        this.getEventSummary(eventId),
        this.getShareBreakdown(eventId),
        this.getCaptureTypeBreakdown(eventId),
        this.getPeakHours(eventId),
        this.getEngagementMetrics(eventId),
        this.getTimeline(eventId, startDate, endDate),
      ]);

    return {
      summary,
      share_breakdown: shareBreakdown,
      capture_types: captureTypes,
      peak_hours: peakHours,
      engagement,
      timeline,
    };
  }

  async getEventSummary(eventId: string): Promise<EventSummary> {
    const result = await query<EventSummary>(
      'SELECT * FROM v_event_summary WHERE event_id = $1',
      [eventId]
    );
    return result.rows[0];
  }

  async getShareBreakdown(eventId: string): Promise<ShareBreakdown[]> {
    const result = await query<ShareBreakdown>(
      'SELECT * FROM v_share_breakdown WHERE event_id = $1',
      [eventId]
    );
    return result.rows;
  }

  async getCaptureTypeBreakdown(eventId: string): Promise<CaptureTypeBreakdown[]> {
    const result = await query<CaptureTypeBreakdown>(
      'SELECT * FROM fn_capture_type_breakdown($1)',
      [eventId]
    );
    return result.rows;
  }

  async getPeakHours(eventId: string, limit = 24): Promise<PeakHour[]> {
    const result = await query<PeakHour>(
      'SELECT * FROM fn_peak_hours($1, $2)',
      [eventId, limit]
    );
    return result.rows;
  }

  async getEngagementMetrics(eventId: string): Promise<EngagementMetrics> {
    const result = await query<EngagementMetrics>(
      'SELECT * FROM fn_engagement_metrics($1)',
      [eventId]
    );
    return (
      result.rows[0] || {
        total_sessions: 0,
        total_captures: 0,
        total_shares: 0,
        avg_session_duration_seconds: 0,
        avg_captures_per_session: 0,
        retake_rate: 0,
        share_rate: 0,
        avg_time_to_first_share_seconds: 0,
        repeat_guest_rate: 0,
      }
    );
  }

  async getTimeline(
    eventId: string,
    startDate?: string,
    endDate?: string,
    granularity = 'hour'
  ): Promise<TimelinePoint[]> {
    let dateFilter = '';
    const params: any[] = [eventId];

    if (startDate) {
      params.push(startDate);
      dateFilter += ` AND c.created_at >= $${params.length}`;
    }
    if (endDate) {
      params.push(endDate);
      dateFilter += ` AND c.created_at <= $${params.length}`;
    }

    const result = await query<TimelinePoint>(
      `SELECT
         date_trunc($${params.length + 1}, c.created_at) AS hour,
         c.capture_type,
         COUNT(*) AS capture_count
       FROM captures c
       WHERE c.event_id = $1 AND c.is_deleted = false ${dateFilter}
       GROUP BY 1, c.capture_type
       ORDER BY 1`,
      [...params, granularity]
    );

    return result.rows;
  }

  /**
   * Get real-time dashboard data (last N minutes).
   */
  async getRealtimeDashboard(eventId: string, minutesBack = 60): Promise<{
    recent_captures: number;
    recent_shares: number;
    active_booths: number;
    latest_captures: Array<{
      id: string;
      thumbnail_url: string;
      capture_type: string;
      created_at: string;
    }>;
  }> {
    const cutoff = new Date(Date.now() - minutesBack * 60 * 1000).toISOString();

    const [captures, shares, booths, latest] = await Promise.all([
      query<{ count: string }>(
        `SELECT COUNT(*) FROM captures
         WHERE event_id = $1 AND created_at >= $2 AND is_deleted = false`,
        [eventId, cutoff]
      ),
      query<{ count: string }>(
        `SELECT COUNT(*) FROM shares
         WHERE event_id = $1 AND created_at >= $2`,
        [eventId, cutoff]
      ),
      query<{ count: string }>(
        `SELECT COUNT(*) FROM booths
         WHERE current_event_id = $1 AND status IN ('online', 'capturing', 'idle')
           AND last_heartbeat >= NOW() - INTERVAL '5 minutes'`,
        [eventId]
      ),
      query<{ id: string; thumbnail_url: string; capture_type: string; created_at: string }>(
        `SELECT id, thumbnail_url, capture_type, created_at
         FROM captures
         WHERE event_id = $1 AND is_deleted = false
         ORDER BY created_at DESC
         LIMIT 20`,
        [eventId]
      ),
    ]);

    return {
      recent_captures: parseInt(captures.rows[0].count, 10),
      recent_shares: parseInt(shares.rows[0].count, 10),
      active_booths: parseInt(booths.rows[0].count, 10),
      latest_captures: latest.rows,
    };
  }

  /**
   * Track an analytics event.
   */
  async track(data: {
    event_id?: string;
    session_id?: string;
    booth_id?: string;
    action: string;
    metadata?: Record<string, any>;
    ip_address?: string;
    user_agent?: string;
  }): Promise<void> {
    await query(
      `INSERT INTO analytics_events (event_id, session_id, booth_id, action, metadata, ip_address, user_agent)
       VALUES ($1, $2, $3, $4, $5, $6::inet, $7)`,
      [
        data.event_id || null,
        data.session_id || null,
        data.booth_id || null,
        data.action,
        JSON.stringify(data.metadata || {}),
        data.ip_address || null,
        data.user_agent || null,
      ]
    );
  }

  /**
   * Get guest demographics summary if survey data exists.
   */
  async getGuestDemographics(eventId: string): Promise<{
    total_guests: number;
    with_email: number;
    with_phone: number;
    survey_responses: Record<string, Record<string, number>>;
  }> {
    const totals = await query<{
      total: string;
      with_email: string;
      with_phone: string;
    }>(
      `SELECT
         COUNT(DISTINCT id) AS total,
         COUNT(DISTINCT guest_email) AS with_email,
         COUNT(DISTINCT guest_phone) AS with_phone
       FROM sessions
       WHERE event_id = $1`,
      [eventId]
    );

    // Aggregate survey data from guest_data JSONB
    const surveyData = await query<{ key: string; value: string; count: string }>(
      `SELECT
         kv.key,
         kv.value::text AS value,
         COUNT(*) AS count
       FROM sessions s,
       LATERAL jsonb_each(COALESCE(s.guest_data, '{}')) AS kv(key, value)
       WHERE s.event_id = $1 AND s.guest_data IS NOT NULL
       GROUP BY kv.key, kv.value
       ORDER BY kv.key, count DESC`,
      [eventId]
    );

    // Group by key
    const surveyResponses: Record<string, Record<string, number>> = {};
    for (const row of surveyData.rows) {
      if (!surveyResponses[row.key]) {
        surveyResponses[row.key] = {};
      }
      surveyResponses[row.key][row.value] = parseInt(row.count, 10);
    }

    const row = totals.rows[0];
    return {
      total_guests: parseInt(row.total, 10),
      with_email: parseInt(row.with_email, 10),
      with_phone: parseInt(row.with_phone, 10),
      survey_responses: surveyResponses,
    };
  }
}

export const analyticsService = new AnalyticsService();
