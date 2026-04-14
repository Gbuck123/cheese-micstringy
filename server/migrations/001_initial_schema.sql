-- Migration 001: Initial Schema
-- Photo Booth Platform (Snappic Clone)

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- ENUM TYPES
-- ============================================================

CREATE TYPE user_role AS ENUM ('admin', 'operator', 'guest');
CREATE TYPE event_status AS ENUM ('draft', 'scheduled', 'active', 'paused', 'completed', 'archived');
CREATE TYPE capture_type AS ENUM ('photo', 'gif', 'boomerang', 'video', 'photo_strip');
CREATE TYPE share_channel AS ENUM ('email', 'sms', 'qr', 'airdrop', 'social', 'download');
CREATE TYPE booth_status AS ENUM ('online', 'offline', 'capturing', 'idle', 'error', 'maintenance');
CREATE TYPE sync_status AS ENUM ('pending', 'uploading', 'uploaded', 'confirmed', 'failed');
CREATE TYPE template_type AS ENUM ('overlay', 'frame', 'background', 'strip_layout', 'email', 'landing');

-- ============================================================
-- USERS
-- ============================================================

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email           VARCHAR(255) UNIQUE NOT NULL,
    password_hash   VARCHAR(255) NOT NULL,
    role            user_role NOT NULL DEFAULT 'operator',
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    company         VARCHAR(200),
    phone           VARCHAR(30),
    avatar_url      TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    email_verified  BOOLEAN NOT NULL DEFAULT false,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_role ON users(role);

-- ============================================================
-- REFRESH TOKENS
-- ============================================================

CREATE TABLE refresh_tokens (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash      VARCHAR(255) NOT NULL,
    device_info     JSONB,
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_hash ON refresh_tokens(token_hash);
CREATE INDEX idx_refresh_tokens_expires ON refresh_tokens(expires_at) WHERE revoked_at IS NULL;

-- ============================================================
-- EVENTS
-- ============================================================

CREATE TABLE events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    name            VARCHAR(300) NOT NULL,
    slug            VARCHAR(300) UNIQUE NOT NULL,
    description     TEXT,
    venue           VARCHAR(500),
    location        JSONB,                          -- { lat, lng, address, city, state, country }
    start_date      TIMESTAMPTZ NOT NULL,
    end_date        TIMESTAMPTZ NOT NULL,
    timezone        VARCHAR(50) NOT NULL DEFAULT 'UTC',
    status          event_status NOT NULL DEFAULT 'draft',
    branding        JSONB NOT NULL DEFAULT '{}',    -- { logo_url, primary_color, secondary_color, background_url, font }
    settings        JSONB NOT NULL DEFAULT '{}',    -- { capture_types, filters_enabled, sharing_channels, watermark, etc. }
    guest_count_est INTEGER,
    is_public       BOOLEAN NOT NULL DEFAULT false,
    gallery_enabled BOOLEAN NOT NULL DEFAULT true,
    password        VARCHAR(100),                    -- optional gallery password
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_owner ON events(owner_id);
CREATE INDEX idx_events_slug ON events(slug);
CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_dates ON events(start_date, end_date);

-- ============================================================
-- BOOTHS (iPad devices)
-- ============================================================

CREATE TABLE booths (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    name            VARCHAR(200) NOT NULL,
    device_id       VARCHAR(255) UNIQUE NOT NULL,   -- iPad UDID or generated device ID
    hardware_info   JSONB,                          -- { model, os_version, storage_total_gb }
    current_event_id UUID REFERENCES events(id) ON DELETE SET NULL,
    status          booth_status NOT NULL DEFAULT 'offline',
    last_heartbeat  TIMESTAMPTZ,
    battery_level   SMALLINT,                       -- 0-100
    storage_free_mb INTEGER,
    ip_address      INET,
    app_version     VARCHAR(50),
    config          JSONB NOT NULL DEFAULT '{}',    -- booth-specific config overrides
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_booths_owner ON booths(owner_id);
CREATE INDEX idx_booths_device ON booths(device_id);
CREATE INDEX idx_booths_event ON booths(current_event_id);
CREATE INDEX idx_booths_status ON booths(status);

-- ============================================================
-- SESSIONS (a single booth usage by a guest)
-- ============================================================

CREATE TABLE sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id        UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    booth_id        UUID REFERENCES booths(id) ON DELETE SET NULL,
    session_code    VARCHAR(20) UNIQUE NOT NULL,     -- short code for QR/URL
    guest_name      VARCHAR(200),
    guest_email     VARCHAR(255),
    guest_phone     VARCHAR(30),
    guest_data      JSONB,                           -- survey responses, custom fields
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    duration_ms     INTEGER,
    capture_count   INTEGER NOT NULL DEFAULT 0,
    retake_count    INTEGER NOT NULL DEFAULT 0,
    shared          BOOLEAN NOT NULL DEFAULT false,
    share_channels  share_channel[] DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sessions_event ON sessions(event_id);
CREATE INDEX idx_sessions_booth ON sessions(booth_id);
CREATE INDEX idx_sessions_code ON sessions(session_code);
CREATE INDEX idx_sessions_started ON sessions(started_at);

-- ============================================================
-- CAPTURES (individual photos/gifs/videos)
-- ============================================================

CREATE TABLE captures (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id      UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    event_id        UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    booth_id        UUID REFERENCES booths(id) ON DELETE SET NULL,
    capture_type    capture_type NOT NULL DEFAULT 'photo',
    sequence_num    INTEGER NOT NULL DEFAULT 1,      -- order within session

    -- File storage
    original_key    VARCHAR(500) NOT NULL,           -- S3 key for original
    processed_key   VARCHAR(500),                    -- S3 key for processed (filters/overlays applied)
    thumbnail_key   VARCHAR(500),                    -- S3 key for thumbnail
    original_url    TEXT,
    processed_url   TEXT,
    thumbnail_url   TEXT,

    -- Metadata
    width           INTEGER,
    height          INTEGER,
    file_size_bytes BIGINT,
    duration_ms     INTEGER,                         -- for video/gif/boomerang
    mime_type       VARCHAR(100),
    exif_data       JSONB,
    filter_applied  VARCHAR(100),
    template_id     UUID,

    -- Sync tracking
    client_id       VARCHAR(100),                    -- client-generated ID for dedup
    sync_status     sync_status NOT NULL DEFAULT 'confirmed',
    synced_at       TIMESTAMPTZ,

    is_favorite     BOOLEAN NOT NULL DEFAULT false,
    is_deleted      BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_captures_client_id ON captures(client_id) WHERE client_id IS NOT NULL;
CREATE INDEX idx_captures_session ON captures(session_id);
CREATE INDEX idx_captures_event ON captures(event_id);
CREATE INDEX idx_captures_type ON captures(capture_type);
CREATE INDEX idx_captures_sync ON captures(sync_status) WHERE sync_status != 'confirmed';
CREATE INDEX idx_captures_created ON captures(created_at);

-- ============================================================
-- TEMPLATES
-- ============================================================

CREATE TABLE templates (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id        UUID REFERENCES users(id) ON DELETE SET NULL,
    name            VARCHAR(200) NOT NULL,
    type            template_type NOT NULL,
    category        VARCHAR(100),
    thumbnail_url   TEXT,
    config          JSONB NOT NULL DEFAULT '{}',     -- template-specific config (positions, sizes, colors)
    asset_keys      TEXT[] DEFAULT '{}',             -- S3 keys for template assets
    is_system       BOOLEAN NOT NULL DEFAULT false,  -- built-in templates
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_templates_owner ON templates(owner_id);
CREATE INDEX idx_templates_type ON templates(type);

-- Junction: which templates are assigned to which events
CREATE TABLE event_templates (
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    template_id UUID NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (event_id, template_id)
);

-- ============================================================
-- SHARES (tracking individual share actions)
-- ============================================================

CREATE TABLE shares (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    capture_id      UUID NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    session_id      UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    event_id        UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    channel         share_channel NOT NULL,
    recipient       VARCHAR(500),                    -- email or phone
    short_url       VARCHAR(200),
    message_id      VARCHAR(255),                    -- SendGrid/Twilio message ID
    status          VARCHAR(50) NOT NULL DEFAULT 'sent',
    opened_at       TIMESTAMPTZ,
    clicked_at      TIMESTAMPTZ,
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shares_capture ON shares(capture_id);
CREATE INDEX idx_shares_session ON shares(session_id);
CREATE INDEX idx_shares_event ON shares(event_id);
CREATE INDEX idx_shares_channel ON shares(channel);

-- ============================================================
-- SHORT URLS
-- ============================================================

CREATE TABLE short_urls (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code            VARCHAR(20) UNIQUE NOT NULL,
    target_url      TEXT NOT NULL,
    event_id        UUID REFERENCES events(id) ON DELETE SET NULL,
    session_id      UUID REFERENCES sessions(id) ON DELETE SET NULL,
    click_count     INTEGER NOT NULL DEFAULT 0,
    expires_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_short_urls_code ON short_urls(code);

-- ============================================================
-- ANALYTICS EVENTS (granular event tracking)
-- ============================================================

CREATE TABLE analytics_events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id        UUID REFERENCES events(id) ON DELETE CASCADE,
    session_id      UUID REFERENCES sessions(id) ON DELETE SET NULL,
    booth_id        UUID REFERENCES booths(id) ON DELETE SET NULL,
    action          VARCHAR(100) NOT NULL,           -- 'capture', 'share', 'view', 'download', 'qr_scan', etc.
    metadata        JSONB DEFAULT '{}',
    ip_address      INET,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_analytics_event ON analytics_events(event_id);
CREATE INDEX idx_analytics_action ON analytics_events(action);
CREATE INDEX idx_analytics_created ON analytics_events(created_at);

-- Hypertable-like partitioning hint (for large scale, use TimescaleDB)
-- CREATE INDEX idx_analytics_event_time ON analytics_events(event_id, created_at);

-- ============================================================
-- SYNC QUEUE (offline sync tracking)
-- ============================================================

CREATE TABLE sync_queue (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    booth_id        UUID NOT NULL REFERENCES booths(id) ON DELETE CASCADE,
    client_id       VARCHAR(100) NOT NULL,
    payload_type    VARCHAR(50) NOT NULL,            -- 'capture', 'session', 'analytics'
    payload         JSONB NOT NULL,
    status          sync_status NOT NULL DEFAULT 'pending',
    attempts        INTEGER NOT NULL DEFAULT 0,
    max_attempts    INTEGER NOT NULL DEFAULT 5,
    last_error      TEXT,
    next_retry_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_sync_queue_client ON sync_queue(booth_id, client_id);
CREATE INDEX idx_sync_queue_status ON sync_queue(status) WHERE status IN ('pending', 'failed');
CREATE INDEX idx_sync_queue_retry ON sync_queue(next_retry_at) WHERE status = 'failed';

-- ============================================================
-- FUNCTIONS & TRIGGERS
-- ============================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_events_updated_at
    BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_booths_updated_at
    BEFORE UPDATE ON booths
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_captures_updated_at
    BEFORE UPDATE ON captures
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_templates_updated_at
    BEFORE UPDATE ON templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_sync_queue_updated_at
    BEFORE UPDATE ON sync_queue
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Auto-increment capture_count on sessions when a capture is inserted
CREATE OR REPLACE FUNCTION increment_session_capture_count()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE sessions
    SET capture_count = capture_count + 1
    WHERE id = NEW.session_id;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER trg_increment_capture_count
    AFTER INSERT ON captures
    FOR EACH ROW EXECUTE FUNCTION increment_session_capture_count();
