-- Migration 002: Analytics materialized views and helper functions

-- ============================================================
-- EVENT SUMMARY VIEW (for dashboard)
-- ============================================================

CREATE OR REPLACE VIEW v_event_summary AS
SELECT
    e.id AS event_id,
    e.name,
    e.slug,
    e.status,
    e.start_date,
    e.end_date,
    COALESCE(cs.total_sessions, 0) AS total_sessions,
    COALESCE(cs.total_captures, 0) AS total_captures,
    COALESCE(cs.total_shares, 0) AS total_shares,
    COALESCE(cs.avg_duration_ms, 0) AS avg_session_duration_ms,
    COALESCE(cs.total_retakes, 0) AS total_retakes,
    COALESCE(cs.unique_guests, 0) AS unique_guests
FROM events e
LEFT JOIN LATERAL (
    SELECT
        COUNT(DISTINCT s.id) AS total_sessions,
        SUM(s.capture_count) AS total_captures,
        COUNT(DISTINCT CASE WHEN s.shared THEN s.id END) AS total_shares,
        AVG(s.duration_ms) FILTER (WHERE s.duration_ms IS NOT NULL) AS avg_duration_ms,
        SUM(s.retake_count) AS total_retakes,
        COUNT(DISTINCT s.guest_email) FILTER (WHERE s.guest_email IS NOT NULL) AS unique_guests
    FROM sessions s
    WHERE s.event_id = e.id
) cs ON true;

-- ============================================================
-- SHARE BREAKDOWN VIEW
-- ============================================================

CREATE OR REPLACE VIEW v_share_breakdown AS
SELECT
    sh.event_id,
    sh.channel,
    COUNT(*) AS share_count,
    COUNT(sh.opened_at) AS opened_count,
    COUNT(sh.clicked_at) AS clicked_count,
    ROUND(
        COUNT(sh.opened_at)::numeric / NULLIF(COUNT(*), 0) * 100, 2
    ) AS open_rate_pct,
    ROUND(
        COUNT(sh.clicked_at)::numeric / NULLIF(COUNT(*), 0) * 100, 2
    ) AS click_rate_pct
FROM shares sh
GROUP BY sh.event_id, sh.channel;

-- ============================================================
-- HOURLY CAPTURE ACTIVITY (for time-series charts)
-- ============================================================

CREATE OR REPLACE VIEW v_hourly_captures AS
SELECT
    c.event_id,
    date_trunc('hour', c.created_at) AS hour,
    c.capture_type,
    COUNT(*) AS capture_count
FROM captures c
WHERE c.is_deleted = false
GROUP BY c.event_id, date_trunc('hour', c.created_at), c.capture_type
ORDER BY hour;

-- ============================================================
-- PEAK HOURS FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_peak_hours(p_event_id UUID, p_limit INTEGER DEFAULT 5)
RETURNS TABLE (
    hour_of_day INTEGER,
    capture_count BIGINT,
    session_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        EXTRACT(HOUR FROM c.created_at)::INTEGER AS hour_of_day,
        COUNT(DISTINCT c.id) AS capture_count,
        COUNT(DISTINCT c.session_id) AS session_count
    FROM captures c
    WHERE c.event_id = p_event_id AND c.is_deleted = false
    GROUP BY EXTRACT(HOUR FROM c.created_at)
    ORDER BY capture_count DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- CAPTURE TYPE BREAKDOWN FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_capture_type_breakdown(p_event_id UUID)
RETURNS TABLE (
    capture_type capture_type,
    count BIGINT,
    percentage NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH totals AS (
        SELECT c.capture_type AS ct, COUNT(*) AS cnt
        FROM captures c
        WHERE c.event_id = p_event_id AND c.is_deleted = false
        GROUP BY c.capture_type
    ),
    grand_total AS (
        SELECT SUM(cnt) AS total FROM totals
    )
    SELECT
        t.ct,
        t.cnt,
        ROUND(t.cnt::numeric / NULLIF(gt.total, 0) * 100, 2)
    FROM totals t, grand_total gt
    ORDER BY t.cnt DESC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- BOOTH UTILIZATION FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_booth_utilization(
    p_event_id UUID,
    p_interval_minutes INTEGER DEFAULT 30
)
RETURNS TABLE (
    time_bucket TIMESTAMPTZ,
    booth_id UUID,
    booth_name VARCHAR,
    session_count BIGINT,
    capture_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        date_trunc('hour', s.started_at) +
            (EXTRACT(MINUTE FROM s.started_at)::INTEGER / p_interval_minutes)
            * (p_interval_minutes || ' minutes')::INTERVAL AS time_bucket,
        b.id AS booth_id,
        b.name AS booth_name,
        COUNT(DISTINCT s.id) AS session_count,
        SUM(s.capture_count) AS capture_count
    FROM sessions s
    JOIN booths b ON s.booth_id = b.id
    WHERE s.event_id = p_event_id
    GROUP BY 1, b.id, b.name
    ORDER BY 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- ENGAGEMENT METRICS FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_engagement_metrics(p_event_id UUID)
RETURNS TABLE (
    total_sessions BIGINT,
    total_captures BIGINT,
    total_shares BIGINT,
    avg_session_duration_seconds NUMERIC,
    avg_captures_per_session NUMERIC,
    retake_rate NUMERIC,
    share_rate NUMERIC,
    avg_time_to_first_share_seconds NUMERIC,
    repeat_guest_rate NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH session_stats AS (
        SELECT
            COUNT(*) AS total_sess,
            SUM(s.capture_count) AS total_cap,
            COUNT(*) FILTER (WHERE s.shared) AS total_sh,
            AVG(s.duration_ms) FILTER (WHERE s.duration_ms > 0) AS avg_dur,
            AVG(s.capture_count) AS avg_cap,
            SUM(s.retake_count)::numeric / NULLIF(SUM(s.capture_count), 0) AS retake_r,
            COUNT(*) FILTER (WHERE s.shared)::numeric / NULLIF(COUNT(*), 0) AS share_r
        FROM sessions s
        WHERE s.event_id = p_event_id
    ),
    first_share AS (
        SELECT AVG(
            EXTRACT(EPOCH FROM (sh.created_at - s.started_at))
        ) AS avg_first_share_sec
        FROM shares sh
        JOIN sessions s ON sh.session_id = s.id
        WHERE sh.event_id = p_event_id
          AND sh.id = (
              SELECT sh2.id FROM shares sh2
              WHERE sh2.session_id = sh.session_id
              ORDER BY sh2.created_at LIMIT 1
          )
    ),
    repeat_guests AS (
        SELECT
            COUNT(*) FILTER (WHERE guest_sessions > 1)::numeric /
            NULLIF(COUNT(*), 0) AS repeat_rate
        FROM (
            SELECT guest_email, COUNT(*) AS guest_sessions
            FROM sessions
            WHERE event_id = p_event_id AND guest_email IS NOT NULL
            GROUP BY guest_email
        ) g
    )
    SELECT
        ss.total_sess,
        ss.total_cap,
        ss.total_sh,
        ROUND(ss.avg_dur / 1000.0, 1),
        ROUND(ss.avg_cap, 1),
        ROUND(ss.retake_r * 100, 2),
        ROUND(ss.share_r * 100, 2),
        ROUND(fs.avg_first_share_sec, 1),
        ROUND(rg.repeat_rate * 100, 2)
    FROM session_stats ss, first_share fs, repeat_guests rg;
END;
$$ LANGUAGE plpgsql STABLE;
