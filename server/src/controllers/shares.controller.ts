import { Request, Response, NextFunction } from 'express';
import { query } from '../config/database';
import { emailService } from '../services/email.service';
import { smsService } from '../services/sms.service';
import { analyticsService } from '../services/analytics.service';
import { NotFoundError } from '../utils/errors';
import type { ShareEmailInput, ShareSmsInput } from '../schemas';

export async function shareViaEmail(req: Request, res: Response, next: NextFunction) {
  try {
    const input: ShareEmailInput = req.body;

    // Fetch capture and event data
    const captureResult = await query(
      `SELECT c.*, e.name AS event_name, e.branding, e.slug AS event_slug,
              s.session_code, s.id AS session_id
       FROM captures c
       JOIN events e ON c.event_id = e.id
       JOIN sessions s ON c.session_id = s.id
       WHERE c.id = $1 AND c.is_deleted = false`,
      [input.capture_id]
    );

    if (captureResult.rows.length === 0) {
      throw new NotFoundError('Capture', input.capture_id);
    }

    const capture = captureResult.rows[0];
    const branding = capture.branding || {};

    const result = await emailService.sendPhotoEmail(input.recipient_email, {
      guest_name: input.recipient_name,
      event_name: capture.event_name,
      photo_url: capture.processed_url || capture.original_url,
      thumbnail_url: capture.thumbnail_url,
      gallery_url: `${process.env.FRONTEND_URL}/gallery/${capture.session_code}`,
      download_url: `${process.env.API_BASE_URL}/api/captures/${capture.id}/download`,
      branding: {
        logo_url: branding.logo_url,
        primary_color: branding.primary_color || '#6366f1',
        secondary_color: branding.secondary_color || '#8b5cf6',
        company_name: branding.company_name,
      },
      custom_message: input.message,
      year: new Date().getFullYear(),
    });

    // Record share
    await query(
      `INSERT INTO shares (capture_id, session_id, event_id, channel, recipient, message_id, status)
       VALUES ($1, $2, $3, 'email', $4, $5, $6)`,
      [
        input.capture_id,
        capture.session_id,
        capture.event_id,
        input.recipient_email,
        result.message_id,
        result.status,
      ]
    );

    // Update session shared flag
    await query(
      `UPDATE sessions
       SET shared = true,
           share_channels = array_append(
             CASE WHEN 'email' = ANY(share_channels) THEN share_channels
             ELSE share_channels END, 'email'
           )
       WHERE id = $1 AND NOT ('email' = ANY(share_channels))`,
      [capture.session_id]
    );

    // Track analytics
    await analyticsService.track({
      event_id: capture.event_id,
      session_id: capture.session_id,
      action: 'share',
      metadata: { channel: 'email', capture_id: input.capture_id },
    });

    res.json({ message: 'Email sent', message_id: result.message_id });
  } catch (error) {
    next(error);
  }
}

export async function shareViaSms(req: Request, res: Response, next: NextFunction) {
  try {
    const input: ShareSmsInput = req.body;

    const captureResult = await query(
      `SELECT c.*, e.name AS event_name, e.slug AS event_slug,
              s.session_code, s.id AS session_id
       FROM captures c
       JOIN events e ON c.event_id = e.id
       JOIN sessions s ON c.session_id = s.id
       WHERE c.id = $1 AND c.is_deleted = false`,
      [input.capture_id]
    );

    if (captureResult.rows.length === 0) {
      throw new NotFoundError('Capture', input.capture_id);
    }

    const capture = captureResult.rows[0];

    // Send MMS if thumbnail available, otherwise SMS
    const sendFn = capture.thumbnail_url
      ? smsService.sendPhotoMms.bind(smsService)
      : smsService.sendPhotoSms.bind(smsService);

    const result = await smsService.sendPhotoSms(input.phone_number, {
      capture_id: input.capture_id,
      session_id: capture.session_id,
      event_id: capture.event_id,
      event_name: capture.event_name,
      photo_url: capture.processed_url || capture.original_url,
      gallery_url: `${process.env.FRONTEND_URL}/gallery/${capture.session_code}`,
      custom_message: input.message,
    });

    // Record share
    await query(
      `INSERT INTO shares (capture_id, session_id, event_id, channel, recipient, short_url, message_id, status)
       VALUES ($1, $2, $3, 'sms', $4, $5, $6, $7)`,
      [
        input.capture_id,
        capture.session_id,
        capture.event_id,
        input.phone_number,
        result.short_url,
        result.message_id,
        result.status,
      ]
    );

    // Update session
    await query(
      `UPDATE sessions
       SET shared = true,
           share_channels = array_append(
             CASE WHEN 'sms' = ANY(share_channels) THEN share_channels
             ELSE share_channels END, 'sms'
           )
       WHERE id = $1 AND NOT ('sms' = ANY(share_channels))`,
      [capture.session_id]
    );

    await analyticsService.track({
      event_id: capture.event_id,
      session_id: capture.session_id,
      action: 'share',
      metadata: { channel: 'sms', capture_id: input.capture_id },
    });

    res.json({
      message: 'SMS sent',
      message_id: result.message_id,
      short_url: result.short_url,
    });
  } catch (error) {
    next(error);
  }
}

/** SendGrid webhook handler. */
export async function emailWebhook(req: Request, res: Response, next: NextFunction) {
  try {
    const events = req.body;
    if (Array.isArray(events)) {
      await emailService.processWebhookEvent(events);
    }
    res.status(200).end();
  } catch (error) {
    // Always return 200 to SendGrid to avoid retries
    console.error('[Webhook] Email webhook error:', error);
    res.status(200).end();
  }
}

/** Twilio status callback. */
export async function smsStatusCallback(req: Request, res: Response, next: NextFunction) {
  try {
    await smsService.processStatusCallback(req.body);
    res.status(200).end();
  } catch (error) {
    console.error('[Webhook] SMS callback error:', error);
    res.status(200).end();
  }
}
