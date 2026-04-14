import { Request, Response, NextFunction } from 'express';
import { query } from '../config/database';
import { generateShortCode } from '../utils/slug';
import { formatPaginatedResponse, buildPaginationClause } from '../utils/pagination';
import { NotFoundError } from '../utils/errors';
import { qrService } from '../services/qr.service';
import type { CreateSessionInput, PaginationInput } from '../schemas';

export async function listSessions(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.query as { event_id?: string };
    const pagination: PaginationInput = req.query as any;
    const { limit, offset, orderClause } = buildPaginationClause(pagination);

    const whereClause = event_id ? 'WHERE s.event_id = $3' : '';
    const params = event_id
      ? [limit, offset, event_id]
      : [limit, offset];

    const [data, count] = await Promise.all([
      query(
        `SELECT s.*, e.name AS event_name
         FROM sessions s
         JOIN events e ON s.event_id = e.id
         ${whereClause}
         ${orderClause}
         LIMIT $1 OFFSET $2`,
        params
      ),
      query(
        `SELECT COUNT(*) FROM sessions s ${whereClause}`,
        event_id ? [event_id] : []
      ),
    ]);

    res.json(
      formatPaginatedResponse(
        data.rows,
        parseInt(count.rows[0].count, 10),
        pagination.page,
        pagination.limit
      )
    );
  } catch (error) {
    next(error);
  }
}

export async function getSession(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const result = await query(
      `SELECT s.*, e.name AS event_name, e.branding
       FROM sessions s
       JOIN events e ON s.event_id = e.id
       WHERE s.id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Session', id);
    }

    // Also fetch captures for this session
    const captures = await query(
      `SELECT id, capture_type, processed_url, thumbnail_url, original_url,
              width, height, duration_ms, filter_applied, created_at
       FROM captures
       WHERE session_id = $1 AND is_deleted = false
       ORDER BY sequence_num ASC`,
      [id]
    );

    res.json({
      session: result.rows[0],
      captures: captures.rows,
    });
  } catch (error) {
    next(error);
  }
}

export async function createSession(req: Request, res: Response, next: NextFunction) {
  try {
    const input: CreateSessionInput = req.body;
    const sessionCode = generateShortCode(8);

    const result = await query(
      `INSERT INTO sessions (
         event_id, booth_id, session_code, guest_name, guest_email,
         guest_phone, guest_data
       ) VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING *`,
      [
        input.event_id,
        input.booth_id,
        sessionCode,
        input.guest_name,
        input.guest_email,
        input.guest_phone,
        JSON.stringify(input.guest_data || {}),
      ]
    );

    const session = result.rows[0];

    // Generate QR code for this session
    const qr = await qrService.generateSessionQR(
      session.id,
      session.event_id,
      sessionCode
    );

    res.status(201).json({
      session,
      qr,
    });
  } catch (error) {
    next(error);
  }
}

export async function endSession(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const { duration_ms, retake_count } = req.body;

    const result = await query(
      `UPDATE sessions
       SET ended_at = NOW(),
           duration_ms = COALESCE($2, EXTRACT(EPOCH FROM (NOW() - started_at))::INTEGER * 1000),
           retake_count = COALESCE($3, retake_count)
       WHERE id = $1
       RETURNING *`,
      [id, duration_ms, retake_count]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Session', id);
    }

    res.json({ session: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

/** Public: get session by code (for QR scan landing page). */
export async function getSessionByCode(req: Request, res: Response, next: NextFunction) {
  try {
    const { code } = req.params;

    const result = await query(
      `SELECT s.*, e.name AS event_name, e.branding, e.slug AS event_slug
       FROM sessions s
       JOIN events e ON s.event_id = e.id
       WHERE s.session_code = $1`,
      [code]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Session');
    }

    const captures = await query(
      `SELECT id, capture_type, processed_url, thumbnail_url, original_url,
              width, height, duration_ms, created_at
       FROM captures
       WHERE session_id = $1 AND is_deleted = false
       ORDER BY sequence_num ASC`,
      [result.rows[0].id]
    );

    res.json({
      session: result.rows[0],
      captures: captures.rows,
    });
  } catch (error) {
    next(error);
  }
}
