import { Request, Response, NextFunction } from 'express';
import { syncService } from '../services/sync.service';
import { getPresignedUploadUrl } from '../config/s3';
import { v4 as uuidv4 } from 'uuid';
import type { SyncBatchInput } from '../schemas';

/**
 * Receive a batch of sync items from a booth.
 */
export async function syncBatch(req: Request, res: Response, next: NextFunction) {
  try {
    const input: SyncBatchInput = req.body;
    const result = await syncService.processBatch(input);

    res.json({
      accepted: result.accepted,
      duplicates: result.duplicates,
      failed: result.failed,
    });
  } catch (error) {
    next(error);
  }
}

/**
 * Confirm that booth has acknowledged server receipt.
 */
export async function syncConfirm(req: Request, res: Response, next: NextFunction) {
  try {
    const { booth_id } = req.params;
    const { client_ids } = req.body;

    const confirmed = await syncService.confirmItems(booth_id, client_ids);

    res.json({ confirmed_count: confirmed });
  } catch (error) {
    next(error);
  }
}

/**
 * Get sync status for a booth.
 */
export async function syncStatus(req: Request, res: Response, next: NextFunction) {
  try {
    const { booth_id } = req.params;
    const status = await syncService.getBoothSyncStatus(booth_id);
    const pending = await syncService.getPendingForBooth(booth_id);

    res.json({ status, pending_items: pending });
  } catch (error) {
    next(error);
  }
}

/**
 * Get presigned S3 upload URLs for batch file upload.
 * Booth requests upload URLs, uploads directly to S3, then sends metadata via syncBatch.
 */
export async function getUploadUrls(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id, session_id, files } = req.body as {
      event_id: string;
      session_id: string;
      files: Array<{ client_id: string; content_type: string; variant: string }>;
    };

    const urls = await Promise.all(
      files.map(async (file) => {
        const ext = file.content_type.split('/')[1] || 'bin';
        const captureId = uuidv4();
        const key = `events/${event_id}/sessions/${session_id}/${captureId}/${file.variant}.${ext}`;

        const uploadUrl = await getPresignedUploadUrl(key, file.content_type, 3600);

        return {
          client_id: file.client_id,
          key,
          upload_url: uploadUrl,
          expires_in: 3600,
        };
      })
    );

    res.json({ upload_urls: urls });
  } catch (error) {
    next(error);
  }
}

/**
 * Force process the upload queue for a booth (admin/operator action).
 */
export async function forceProcessQueue(req: Request, res: Response, next: NextFunction) {
  try {
    const { booth_id } = req.params;

    // Run queue processing
    await syncService.processQueue(booth_id);

    const status = await syncService.getBoothSyncStatus(booth_id);
    res.json({ message: 'Queue processing triggered', status });
  } catch (error) {
    next(error);
  }
}
