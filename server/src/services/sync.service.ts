import { query, withTransaction } from '../config/database';
import type { PoolClient } from 'pg';
import type { SyncBatchInput } from '../schemas';

interface SyncResult {
  accepted: string[];    // client_ids that were accepted
  duplicates: string[];  // client_ids that already exist
  failed: Array<{ client_id: string; error: string }>;
}

interface SyncStatus {
  pending: number;
  uploading: number;
  uploaded: number;
  confirmed: number;
  failed: number;
}

export class SyncService {
  /**
   * Process a batch of sync items from a booth.
   * Implements idempotent upsert using client_id for deduplication.
   */
  async processBatch(input: SyncBatchInput): Promise<SyncResult> {
    const result: SyncResult = {
      accepted: [],
      duplicates: [],
      failed: [],
    };

    for (const item of input.items) {
      try {
        // Check for duplicate
        const existing = await query(
          `SELECT id, status FROM sync_queue
           WHERE booth_id = $1 AND client_id = $2`,
          [input.booth_id, item.client_id]
        );

        if (existing.rows.length > 0) {
          const row = existing.rows[0];
          if (row.status === 'confirmed') {
            result.duplicates.push(item.client_id);
            continue;
          }
          // Re-queue if previously failed
          await query(
            `UPDATE sync_queue
             SET payload = $1, status = 'pending', attempts = 0, last_error = NULL, updated_at = NOW()
             WHERE booth_id = $2 AND client_id = $3`,
            [JSON.stringify(item.payload), input.booth_id, item.client_id]
          );
          result.accepted.push(item.client_id);
          continue;
        }

        // Insert new sync item
        await query(
          `INSERT INTO sync_queue (booth_id, client_id, payload_type, payload, status)
           VALUES ($1, $2, $3, $4, 'pending')`,
          [input.booth_id, item.client_id, item.payload_type, JSON.stringify(item.payload)]
        );

        result.accepted.push(item.client_id);
      } catch (error: any) {
        result.failed.push({
          client_id: item.client_id,
          error: error.message,
        });
      }
    }

    // Process pending items asynchronously
    this.processQueue(input.booth_id).catch((err) =>
      console.error('[Sync] Queue processing error:', err.message)
    );

    return result;
  }

  /**
   * Process pending items in the sync queue for a booth.
   */
  async processQueue(boothId: string): Promise<void> {
    const pending = await query(
      `SELECT id, client_id, payload_type, payload
       FROM sync_queue
       WHERE booth_id = $1 AND status IN ('pending', 'failed')
         AND (next_retry_at IS NULL OR next_retry_at <= NOW())
         AND attempts < max_attempts
       ORDER BY created_at ASC
       LIMIT 50`,
      [boothId]
    );

    for (const item of pending.rows) {
      try {
        await query(
          `UPDATE sync_queue SET status = 'uploading', attempts = attempts + 1, updated_at = NOW()
           WHERE id = $1`,
          [item.id]
        );

        // Process based on payload type
        switch (item.payload_type) {
          case 'capture':
            await this.processCaptureSync(item.payload, item.client_id);
            break;
          case 'session':
            await this.processSessionSync(item.payload, item.client_id);
            break;
          case 'analytics':
            await this.processAnalyticsSync(item.payload);
            break;
        }

        // Mark as confirmed
        await query(
          `UPDATE sync_queue SET status = 'confirmed', updated_at = NOW()
           WHERE id = $1`,
          [item.id]
        );
      } catch (error: any) {
        const attempts = (item.attempts || 0) + 1;
        const backoffSeconds = Math.min(Math.pow(2, attempts) * 10, 3600); // max 1 hour
        const nextRetry = new Date(Date.now() + backoffSeconds * 1000);

        await query(
          `UPDATE sync_queue
           SET status = 'failed',
               last_error = $1,
               next_retry_at = $2,
               updated_at = NOW()
           WHERE id = $3`,
          [error.message, nextRetry, item.id]
        );
      }
    }
  }

  /**
   * Confirm receipt of specific items (called by booth after server confirms).
   */
  async confirmItems(boothId: string, clientIds: string[]): Promise<number> {
    const result = await query(
      `UPDATE sync_queue
       SET status = 'confirmed', updated_at = NOW()
       WHERE booth_id = $1 AND client_id = ANY($2) AND status != 'confirmed'`,
      [boothId, clientIds]
    );
    return result.rowCount || 0;
  }

  /**
   * Get sync status for a booth.
   */
  async getBoothSyncStatus(boothId: string): Promise<SyncStatus> {
    const result = await query<{ status: string; count: string }>(
      `SELECT status, COUNT(*) AS count
       FROM sync_queue
       WHERE booth_id = $1
       GROUP BY status`,
      [boothId]
    );

    const status: SyncStatus = {
      pending: 0,
      uploading: 0,
      uploaded: 0,
      confirmed: 0,
      failed: 0,
    };

    for (const row of result.rows) {
      (status as any)[row.status] = parseInt(row.count, 10);
    }

    return status;
  }

  /**
   * Get pending items that need to be re-synced (for booth pull).
   */
  async getPendingForBooth(boothId: string): Promise<Array<{
    client_id: string;
    status: string;
    attempts: number;
    last_error: string | null;
  }>> {
    const result = await query(
      `SELECT client_id, status, attempts, last_error
       FROM sync_queue
       WHERE booth_id = $1 AND status IN ('pending', 'failed')
       ORDER BY created_at ASC`,
      [boothId]
    );
    return result.rows;
  }

  // ------ Private processors ------

  private async processCaptureSync(payload: any, clientId: string): Promise<void> {
    // Check if capture already exists (idempotent)
    const existing = await query(
      'SELECT id FROM captures WHERE client_id = $1',
      [clientId]
    );
    if (existing.rows.length > 0) return;

    await query(
      `INSERT INTO captures (
         session_id, event_id, booth_id, capture_type, client_id,
         original_key, original_url, thumbnail_key, thumbnail_url,
         width, height, file_size_bytes, duration_ms, mime_type,
         filter_applied, sync_status, synced_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,'confirmed',NOW())`,
      [
        payload.session_id,
        payload.event_id,
        payload.booth_id,
        payload.capture_type || 'photo',
        clientId,
        payload.original_key,
        payload.original_url,
        payload.thumbnail_key,
        payload.thumbnail_url,
        payload.width,
        payload.height,
        payload.file_size_bytes,
        payload.duration_ms,
        payload.mime_type,
        payload.filter_applied,
      ]
    );
  }

  private async processSessionSync(payload: any, clientId: string): Promise<void> {
    // Upsert session
    await query(
      `INSERT INTO sessions (
         id, event_id, booth_id, session_code, guest_name, guest_email,
         guest_phone, guest_data, started_at, ended_at, duration_ms
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT (id) DO UPDATE SET
         ended_at = EXCLUDED.ended_at,
         duration_ms = EXCLUDED.duration_ms,
         guest_name = COALESCE(EXCLUDED.guest_name, sessions.guest_name),
         guest_email = COALESCE(EXCLUDED.guest_email, sessions.guest_email)`,
      [
        payload.id,
        payload.event_id,
        payload.booth_id,
        payload.session_code,
        payload.guest_name,
        payload.guest_email,
        payload.guest_phone,
        JSON.stringify(payload.guest_data || {}),
        payload.started_at,
        payload.ended_at,
        payload.duration_ms,
      ]
    );
  }

  private async processAnalyticsSync(payload: any): Promise<void> {
    await query(
      `INSERT INTO analytics_events (event_id, session_id, booth_id, action, metadata)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        payload.event_id,
        payload.session_id,
        payload.booth_id,
        payload.action,
        JSON.stringify(payload.metadata || {}),
      ]
    );
  }
}

export const syncService = new SyncService();
