import twilio from 'twilio';
import { env } from '../config/env';
import { query } from '../config/database';
import { generateShortCode } from '../utils/slug';

const client = twilio(env.TWILIO_ACCOUNT_SID, env.TWILIO_AUTH_TOKEN);

interface SendSmsResult {
  message_id: string;
  status: string;
  short_url: string;
}

export class SmsService {
  /**
   * Send an SMS with a link to view/download the photo.
   */
  async sendPhotoSms(
    phoneNumber: string,
    options: {
      capture_id: string;
      session_id: string;
      event_id: string;
      event_name: string;
      photo_url: string;
      gallery_url: string;
      custom_message?: string;
    }
  ): Promise<SendSmsResult> {
    // Generate short URL
    const shortCode = generateShortCode(7);
    const shortUrl = `${env.API_BASE_URL}/s/${shortCode}`;

    // Store short URL
    await query(
      `INSERT INTO short_urls (code, target_url, event_id, session_id)
       VALUES ($1, $2, $3, $4)`,
      [shortCode, options.gallery_url, options.event_id, options.session_id]
    );

    const body = options.custom_message
      ? `${options.custom_message}\n\nView your photos: ${shortUrl}`
      : `Your photos from ${options.event_name} are ready! View and download here: ${shortUrl}`;

    const messageOptions: any = {
      to: phoneNumber,
      body,
    };

    // Use messaging service SID if available, otherwise use phone number
    if (env.TWILIO_MESSAGING_SERVICE_SID) {
      messageOptions.messagingServiceSid = env.TWILIO_MESSAGING_SERVICE_SID;
    } else {
      messageOptions.from = env.TWILIO_PHONE_NUMBER;
    }

    const message = await client.messages.create(messageOptions);

    return {
      message_id: message.sid,
      status: message.status,
      short_url: shortUrl,
    };
  }

  /**
   * Send an MMS with a photo thumbnail and link.
   */
  async sendPhotoMms(
    phoneNumber: string,
    options: {
      capture_id: string;
      session_id: string;
      event_id: string;
      event_name: string;
      thumbnail_url: string;
      gallery_url: string;
    }
  ): Promise<SendSmsResult> {
    const shortCode = generateShortCode(7);
    const shortUrl = `${env.API_BASE_URL}/s/${shortCode}`;

    await query(
      `INSERT INTO short_urls (code, target_url, event_id, session_id)
       VALUES ($1, $2, $3, $4)`,
      [shortCode, options.gallery_url, options.event_id, options.session_id]
    );

    const messageOptions: any = {
      to: phoneNumber,
      body: `Your photos from ${options.event_name}! View all: ${shortUrl}`,
      mediaUrl: [options.thumbnail_url],
    };

    if (env.TWILIO_MESSAGING_SERVICE_SID) {
      messageOptions.messagingServiceSid = env.TWILIO_MESSAGING_SERVICE_SID;
    } else {
      messageOptions.from = env.TWILIO_PHONE_NUMBER;
    }

    const message = await client.messages.create(messageOptions);

    return {
      message_id: message.sid,
      status: message.status,
      short_url: shortUrl,
    };
  }

  /**
   * Handle Twilio status callback for delivery tracking.
   */
  async processStatusCallback(data: {
    MessageSid: string;
    MessageStatus: string;
    ErrorCode?: string;
    ErrorMessage?: string;
  }): Promise<void> {
    const status = data.MessageStatus;
    if (['delivered', 'undelivered', 'failed'].includes(status)) {
      await query(
        `UPDATE shares SET status = $1, error_message = $2
         WHERE message_id = $3`,
        [
          status === 'delivered' ? 'delivered' : 'failed',
          data.ErrorMessage || null,
          data.MessageSid,
        ]
      );
    }
  }
}

export const smsService = new SmsService();
