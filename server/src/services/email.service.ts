import sgMail from '@sendgrid/mail';
import Handlebars from 'handlebars';
import fs from 'fs';
import path from 'path';
import { env } from '../config/env';
import { query } from '../config/database';

sgMail.setApiKey(env.SENDGRID_API_KEY);

interface EmailContext {
  guest_name?: string;
  event_name: string;
  photo_url: string;
  thumbnail_url?: string;
  gallery_url: string;
  download_url: string;
  branding: {
    logo_url?: string;
    primary_color: string;
    secondary_color: string;
    company_name?: string;
  };
  custom_message?: string;
  year: number;
}

interface SendEmailResult {
  message_id: string;
  status: string;
}

export class EmailService {
  private templates: Map<string, Handlebars.TemplateDelegate> = new Map();

  constructor() {
    this.loadTemplates();
    this.registerHelpers();
  }

  private loadTemplates(): void {
    const templatesDir = path.join(__dirname, '..', 'templates', 'email');
    try {
      const files = fs.readdirSync(templatesDir).filter((f) => f.endsWith('.hbs'));
      for (const file of files) {
        const name = path.basename(file, '.hbs');
        const source = fs.readFileSync(path.join(templatesDir, file), 'utf8');
        this.templates.set(name, Handlebars.compile(source));
      }
      console.log(`[Email] Loaded ${this.templates.size} templates`);
    } catch (err) {
      console.warn('[Email] Could not load templates:', (err as Error).message);
    }
  }

  private registerHelpers(): void {
    Handlebars.registerHelper('ifEquals', function (this: any, a: any, b: any, options: any) {
      return a === b ? options.fn(this) : options.inverse(this);
    });
    Handlebars.registerHelper('uppercase', (str: string) => str?.toUpperCase());
  }

  /**
   * Send a branded photo email to a guest.
   */
  async sendPhotoEmail(
    recipientEmail: string,
    context: EmailContext,
    templateName = 'photo-share'
  ): Promise<SendEmailResult> {
    const template = this.templates.get(templateName);
    if (!template) {
      throw new Error(`Email template '${templateName}' not found`);
    }

    const html = template({
      ...context,
      year: new Date().getFullYear(),
    });

    const msg = {
      to: recipientEmail,
      from: {
        email: env.SENDGRID_FROM_EMAIL,
        name: context.branding?.company_name || env.SENDGRID_FROM_NAME,
      },
      subject: `Your photos from ${context.event_name}!`,
      html,
      trackingSettings: {
        clickTracking: { enable: true, enableText: false },
        openTracking: { enable: true },
      },
      customArgs: {
        event_name: context.event_name,
      },
    };

    const [response] = await sgMail.send(msg);
    const messageId = response.headers['x-message-id'] || '';

    return {
      message_id: messageId,
      status: response.statusCode === 202 ? 'sent' : 'failed',
    };
  }

  /**
   * Process SendGrid webhook events for email analytics.
   */
  async processWebhookEvent(events: Array<{
    event: string;
    sg_message_id: string;
    timestamp: number;
    email: string;
    url?: string;
  }>): Promise<void> {
    for (const event of events) {
      const msgId = event.sg_message_id?.split('.')[0];
      if (!msgId) continue;

      switch (event.event) {
        case 'open':
          await query(
            `UPDATE shares SET opened_at = COALESCE(opened_at, to_timestamp($1))
             WHERE message_id LIKE $2 AND opened_at IS NULL`,
            [event.timestamp, `${msgId}%`]
          );
          break;
        case 'click':
          await query(
            `UPDATE shares SET clicked_at = COALESCE(clicked_at, to_timestamp($1))
             WHERE message_id LIKE $2 AND clicked_at IS NULL`,
            [event.timestamp, `${msgId}%`]
          );
          break;
      }
    }
  }
}

export const emailService = new EmailService();
