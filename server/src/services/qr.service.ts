import QRCode from 'qrcode';
import { env } from '../config/env';
import { query } from '../config/database';
import { generateShortCode } from '../utils/slug';
import { uploadToS3 } from '../config/s3';

interface QRCodeResult {
  qr_data_url: string;    // base64 data URL for immediate display
  qr_image_url: string;   // S3 URL for persistent storage
  target_url: string;      // the URL the QR code points to
  short_code: string;
}

export class QRService {
  /**
   * Generate a QR code that links to a session's photo gallery.
   */
  async generateSessionQR(
    sessionId: string,
    eventId: string,
    sessionCode: string
  ): Promise<QRCodeResult> {
    // The gallery URL for this session
    const targetUrl = `${env.FRONTEND_URL}/gallery/${sessionCode}`;

    // Generate short URL
    const shortCode = generateShortCode(7);
    const shortUrl = `${env.API_BASE_URL}/s/${shortCode}`;

    await query(
      `INSERT INTO short_urls (code, target_url, event_id, session_id)
       VALUES ($1, $2, $3, $4)`,
      [shortCode, targetUrl, eventId, sessionId]
    );

    // Generate QR code as data URL (for immediate display on iPad)
    const qrDataUrl = await QRCode.toDataURL(shortUrl, {
      width: 512,
      margin: 2,
      color: {
        dark: '#000000',
        light: '#FFFFFF',
      },
      errorCorrectionLevel: 'M',
    });

    // Generate QR code as PNG buffer (for S3 storage)
    const qrBuffer = await QRCode.toBuffer(shortUrl, {
      width: 1024,
      margin: 2,
      type: 'png',
      errorCorrectionLevel: 'M',
    });

    // Upload to S3
    const s3Key = `events/${eventId}/qr/${sessionCode}.png`;
    const qrImageUrl = await uploadToS3({
      key: s3Key,
      body: qrBuffer,
      contentType: 'image/png',
      metadata: {
        session_id: sessionId,
        target_url: shortUrl,
      },
    });

    return {
      qr_data_url: qrDataUrl,
      qr_image_url: qrImageUrl,
      target_url: shortUrl,
      short_code: shortCode,
    };
  }

  /**
   * Generate a QR code for an entire event gallery.
   */
  async generateEventQR(eventId: string, eventSlug: string): Promise<QRCodeResult> {
    const targetUrl = `${env.FRONTEND_URL}/event/${eventSlug}`;

    const shortCode = generateShortCode(7);
    const shortUrl = `${env.API_BASE_URL}/s/${shortCode}`;

    await query(
      `INSERT INTO short_urls (code, target_url, event_id)
       VALUES ($1, $2, $3)`,
      [shortCode, targetUrl, eventId]
    );

    const qrDataUrl = await QRCode.toDataURL(shortUrl, {
      width: 512,
      margin: 2,
      errorCorrectionLevel: 'H',
    });

    const qrBuffer = await QRCode.toBuffer(shortUrl, {
      width: 1024,
      margin: 2,
      type: 'png',
      errorCorrectionLevel: 'H',
    });

    const s3Key = `events/${eventId}/qr/event-gallery.png`;
    const qrImageUrl = await uploadToS3({
      key: s3Key,
      body: qrBuffer,
      contentType: 'image/png',
    });

    return {
      qr_data_url: qrDataUrl,
      qr_image_url: qrImageUrl,
      target_url: shortUrl,
      short_code: shortCode,
    };
  }

  /**
   * Resolve a short URL code and track the click.
   */
  async resolveShortUrl(code: string): Promise<string | null> {
    const result = await query<{ target_url: string; expires_at: Date | null }>(
      `UPDATE short_urls
       SET click_count = click_count + 1
       WHERE code = $1
       RETURNING target_url, expires_at`,
      [code]
    );

    if (result.rows.length === 0) return null;

    const { target_url, expires_at } = result.rows[0];
    if (expires_at && new Date(expires_at) < new Date()) return null;

    return target_url;
  }
}

export const qrService = new QRService();
