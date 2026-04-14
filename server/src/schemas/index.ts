import { z } from 'zod';

// ============================================================
// Common
// ============================================================

export const paginationSchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  sort_by: z.string().optional(),
  sort_order: z.enum(['asc', 'desc']).default('desc'),
});

export const uuidParam = z.object({
  id: z.string().uuid(),
});

// ============================================================
// Auth
// ============================================================

export const registerSchema = z.object({
  email: z.string().email().max(255),
  password: z.string().min(8).max(128),
  first_name: z.string().min(1).max(100),
  last_name: z.string().min(1).max(100),
  company: z.string().max(200).optional(),
  phone: z.string().max(30).optional(),
});

export const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
  device_info: z
    .object({
      name: z.string().optional(),
      type: z.string().optional(),
      os: z.string().optional(),
    })
    .optional(),
});

export const refreshTokenSchema = z.object({
  refresh_token: z.string().min(1),
});

// ============================================================
// Events
// ============================================================

export const createEventSchema = z.object({
  name: z.string().min(1).max(300),
  description: z.string().max(5000).optional(),
  venue: z.string().max(500).optional(),
  location: z
    .object({
      lat: z.number().optional(),
      lng: z.number().optional(),
      address: z.string().optional(),
      city: z.string().optional(),
      state: z.string().optional(),
      country: z.string().optional(),
    })
    .optional(),
  start_date: z.string().datetime(),
  end_date: z.string().datetime(),
  timezone: z.string().default('UTC'),
  branding: z
    .object({
      logo_url: z.string().url().optional(),
      primary_color: z.string().optional(),
      secondary_color: z.string().optional(),
      background_url: z.string().url().optional(),
      font: z.string().optional(),
    })
    .optional(),
  settings: z
    .object({
      capture_types: z.array(z.enum(['photo', 'gif', 'boomerang', 'video', 'photo_strip'])).optional(),
      filters_enabled: z.boolean().optional(),
      sharing_channels: z.array(z.enum(['email', 'sms', 'qr', 'airdrop', 'social', 'download'])).optional(),
      watermark: z.boolean().optional(),
      max_retakes: z.number().int().min(0).optional(),
      countdown_seconds: z.number().int().min(0).max(10).optional(),
    })
    .optional(),
  guest_count_est: z.number().int().min(0).optional(),
  is_public: z.boolean().default(false),
  gallery_enabled: z.boolean().default(true),
  password: z.string().max(100).optional(),
});

export const updateEventSchema = createEventSchema.partial().extend({
  status: z.enum(['draft', 'scheduled', 'active', 'paused', 'completed', 'archived']).optional(),
});

// ============================================================
// Sessions
// ============================================================

export const createSessionSchema = z.object({
  event_id: z.string().uuid(),
  booth_id: z.string().uuid().optional(),
  guest_name: z.string().max(200).optional(),
  guest_email: z.string().email().max(255).optional(),
  guest_phone: z.string().max(30).optional(),
  guest_data: z.record(z.any()).optional(),
});

export const endSessionSchema = z.object({
  duration_ms: z.number().int().min(0).optional(),
  retake_count: z.number().int().min(0).optional(),
});

// ============================================================
// Captures
// ============================================================

export const createCaptureSchema = z.object({
  session_id: z.string().uuid(),
  event_id: z.string().uuid(),
  booth_id: z.string().uuid().optional(),
  capture_type: z.enum(['photo', 'gif', 'boomerang', 'video', 'photo_strip']).default('photo'),
  client_id: z.string().max(100).optional(),
  filter_applied: z.string().max(100).optional(),
  template_id: z.string().uuid().optional(),
  width: z.number().int().optional(),
  height: z.number().int().optional(),
  duration_ms: z.number().int().optional(),
});

// ============================================================
// Shares
// ============================================================

export const shareEmailSchema = z.object({
  capture_id: z.string().uuid(),
  recipient_email: z.string().email(),
  recipient_name: z.string().max(200).optional(),
  message: z.string().max(1000).optional(),
});

export const shareSmsSchema = z.object({
  capture_id: z.string().uuid(),
  phone_number: z.string().regex(/^\+?[1-9]\d{1,14}$/),
  message: z.string().max(320).optional(),
});

// ============================================================
// Booths
// ============================================================

export const registerBoothSchema = z.object({
  name: z.string().min(1).max(200),
  device_id: z.string().min(1).max(255),
  hardware_info: z
    .object({
      model: z.string().optional(),
      os_version: z.string().optional(),
      storage_total_gb: z.number().optional(),
    })
    .optional(),
  app_version: z.string().max(50).optional(),
});

export const boothHeartbeatSchema = z.object({
  battery_level: z.number().int().min(0).max(100),
  storage_free_mb: z.number().int().min(0),
  current_event_id: z.string().uuid().nullable().optional(),
  status: z.enum(['online', 'offline', 'capturing', 'idle', 'error', 'maintenance']).optional(),
  ip_address: z.string().optional(),
  app_version: z.string().max(50).optional(),
});

// ============================================================
// Sync
// ============================================================

export const syncBatchSchema = z.object({
  booth_id: z.string().uuid(),
  items: z.array(
    z.object({
      client_id: z.string().max(100),
      payload_type: z.enum(['capture', 'session', 'analytics']),
      payload: z.record(z.any()),
      created_at: z.string().datetime().optional(),
    })
  ),
});

export const syncConfirmSchema = z.object({
  client_ids: z.array(z.string().max(100)),
});

// ============================================================
// Templates
// ============================================================

export const createTemplateSchema = z.object({
  name: z.string().min(1).max(200),
  type: z.enum(['overlay', 'frame', 'background', 'strip_layout', 'email', 'landing']),
  category: z.string().max(100).optional(),
  config: z.record(z.any()).optional(),
});

// ============================================================
// Analytics Query
// ============================================================

export const analyticsQuerySchema = z.object({
  event_id: z.string().uuid(),
  start_date: z.string().datetime().optional(),
  end_date: z.string().datetime().optional(),
  granularity: z.enum(['hour', 'day', 'week', 'month']).default('hour'),
});

// Type exports
export type PaginationInput = z.infer<typeof paginationSchema>;
export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
export type CreateEventInput = z.infer<typeof createEventSchema>;
export type UpdateEventInput = z.infer<typeof updateEventSchema>;
export type CreateSessionInput = z.infer<typeof createSessionSchema>;
export type CreateCaptureInput = z.infer<typeof createCaptureSchema>;
export type ShareEmailInput = z.infer<typeof shareEmailSchema>;
export type ShareSmsInput = z.infer<typeof shareSmsSchema>;
export type RegisterBoothInput = z.infer<typeof registerBoothSchema>;
export type BoothHeartbeatInput = z.infer<typeof boothHeartbeatSchema>;
export type SyncBatchInput = z.infer<typeof syncBatchSchema>;
export type CreateTemplateInput = z.infer<typeof createTemplateSchema>;
export type AnalyticsQueryInput = z.infer<typeof analyticsQuerySchema>;
