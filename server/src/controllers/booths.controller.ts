import { Request, Response, NextFunction } from 'express';
import { query } from '../config/database';
import { NotFoundError } from '../utils/errors';
import { syncService } from '../services/sync.service';
import type { RegisterBoothInput, BoothHeartbeatInput } from '../schemas';

export async function listBooths(req: Request, res: Response, next: NextFunction) {
  try {
    const userId = req.user!.sub;
    const isAdmin = req.user!.role === 'admin';

    const result = await query(
      `SELECT b.*, e.name AS current_event_name
       FROM booths b
       LEFT JOIN events e ON b.current_event_id = e.id
       ${isAdmin ? '' : 'WHERE b.owner_id = $1'}
       ORDER BY b.last_heartbeat DESC NULLS LAST`,
      isAdmin ? [] : [userId]
    );

    res.json({ booths: result.rows });
  } catch (error) {
    next(error);
  }
}

export async function registerBooth(req: Request, res: Response, next: NextFunction) {
  try {
    const input: RegisterBoothInput = req.body;
    const userId = req.user!.sub;

    // Upsert by device_id
    const result = await query(
      `INSERT INTO booths (owner_id, name, device_id, hardware_info, app_version, status)
       VALUES ($1, $2, $3, $4, $5, 'online')
       ON CONFLICT (device_id)
       DO UPDATE SET
         name = EXCLUDED.name,
         hardware_info = COALESCE(EXCLUDED.hardware_info, booths.hardware_info),
         app_version = COALESCE(EXCLUDED.app_version, booths.app_version),
         status = 'online',
         last_heartbeat = NOW()
       RETURNING *`,
      [
        userId,
        input.name,
        input.device_id,
        JSON.stringify(input.hardware_info || {}),
        input.app_version,
      ]
    );

    res.status(201).json({ booth: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

export async function heartbeat(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const input: BoothHeartbeatInput = req.body;

    const result = await query(
      `UPDATE booths
       SET battery_level = $2,
           storage_free_mb = $3,
           current_event_id = COALESCE($4, current_event_id),
           status = COALESCE($5, status),
           ip_address = $6::inet,
           app_version = COALESCE($7, app_version),
           last_heartbeat = NOW()
       WHERE id = $1
       RETURNING *`,
      [
        id,
        input.battery_level,
        input.storage_free_mb,
        input.current_event_id,
        input.status,
        input.ip_address,
        input.app_version,
      ]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Booth', id);
    }

    // Check for pending commands (stored in Redis or DB)
    // Return sync status
    const syncStatus = await syncService.getBoothSyncStatus(id);

    res.json({
      booth: result.rows[0],
      sync_status: syncStatus,
    });
  } catch (error) {
    next(error);
  }
}

export async function getBooth(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;

    const result = await query(
      `SELECT b.*, e.name AS current_event_name
       FROM booths b
       LEFT JOIN events e ON b.current_event_id = e.id
       WHERE b.id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Booth', id);
    }

    res.json({ booth: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

export async function assignEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const { event_id } = req.body;

    const result = await query(
      `UPDATE booths SET current_event_id = $2 WHERE id = $1 RETURNING *`,
      [id, event_id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Booth', id);
    }

    res.json({ booth: result.rows[0] });
  } catch (error) {
    next(error);
  }
}
