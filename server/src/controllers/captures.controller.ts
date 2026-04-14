import { Request, Response, NextFunction } from 'express';
import sharp from 'sharp';
import { query } from '../config/database';
import { uploadToS3, getPresignedUrl } from '../config/s3';
import { generateS3Key } from '../middleware/upload';
import { formatPaginatedResponse, buildPaginationClause } from '../utils/pagination';
import { NotFoundError } from '../utils/errors';
import type { PaginationInput } from '../schemas';

export async function listCaptures(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id, session_id, capture_type } = req.query as Record<string, string>;
    const pagination: PaginationInput = req.query as any;
    const { limit, offset, orderClause } = buildPaginationClause(pagination);

    const conditions: string[] = ['c.is_deleted = false'];
    const params: any[] = [];
    let paramIdx = 1;

    if (event_id) {
      conditions.push(`c.event_id = $${paramIdx++}`);
      params.push(event_id);
    }
    if (session_id) {
      conditions.push(`c.session_id = $${paramIdx++}`);
      params.push(session_id);
    }
    if (capture_type) {
      conditions.push(`c.capture_type = $${paramIdx++}`);
      params.push(capture_type);
    }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

    params.push(limit);
    params.push(offset);

    const [data, count] = await Promise.all([
      query(
        `SELECT c.*, s.session_code, s.guest_name
         FROM captures c
         LEFT JOIN sessions s ON c.session_id = s.id
         ${where}
         ${orderClause}
         LIMIT $${paramIdx++} OFFSET $${paramIdx}`,
        params
      ),
      query(
        `SELECT COUNT(*) FROM captures c ${where}`,
        params.slice(0, -2) // exclude limit/offset
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

export async function getCapture(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;

    const result = await query(
      `SELECT c.*, s.session_code, s.guest_name, e.name AS event_name, e.branding
       FROM captures c
       JOIN sessions s ON c.session_id = s.id
       JOIN events e ON c.event_id = e.id
       WHERE c.id = $1 AND c.is_deleted = false`,
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Capture', id);
    }

    res.json({ capture: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

/**
 * Upload a capture (photo/gif/video).
 * Expects multipart form data with file and metadata.
 */
export async function uploadCapture(req: Request, res: Response, next: NextFunction) {
  try {
    const file = req.file;
    if (!file) {
      return res.status(400).json({ error: { message: 'No file uploaded' } });
    }

    const {
      session_id,
      event_id,
      booth_id,
      capture_type = 'photo',
      client_id,
      filter_applied,
      template_id,
    } = req.body;

    // Generate S3 keys
    const originalKey = generateS3Key(event_id, session_id, 'original', file.mimetype);
    const thumbnailKey = generateS3Key(event_id, session_id, 'thumbnail', 'image/jpeg');

    // Upload original to S3
    const originalUrl = await uploadToS3({
      key: originalKey,
      body: file.buffer,
      contentType: file.mimetype,
      metadata: {
        session_id,
        event_id,
        capture_type,
      },
    });

    // Generate and upload thumbnail
    let thumbnailUrl: string | null = null;
    let width: number | undefined;
    let height: number | undefined;

    if (file.mimetype.startsWith('image/')) {
      const metadata = await sharp(file.buffer).metadata();
      width = metadata.width;
      height = metadata.height;

      const thumbnailBuffer = await sharp(file.buffer)
        .resize(400, 400, { fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 80 })
        .toBuffer();

      thumbnailUrl = await uploadToS3({
        key: thumbnailKey,
        body: thumbnailBuffer,
        contentType: 'image/jpeg',
      });
    }

    // Get next sequence number
    const seqResult = await query(
      'SELECT COALESCE(MAX(sequence_num), 0) + 1 AS next_seq FROM captures WHERE session_id = $1',
      [session_id]
    );
    const sequenceNum = seqResult.rows[0].next_seq;

    // Insert capture record
    const result = await query(
      `INSERT INTO captures (
         session_id, event_id, booth_id, capture_type, sequence_num,
         original_key, original_url, thumbnail_key, thumbnail_url,
         width, height, file_size_bytes, mime_type,
         filter_applied, template_id, client_id, sync_status
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,'confirmed')
       RETURNING *`,
      [
        session_id,
        event_id,
        booth_id,
        capture_type,
        sequenceNum,
        originalKey,
        originalUrl,
        thumbnailKey,
        thumbnailUrl,
        width,
        height,
        file.size,
        file.mimetype,
        filter_applied,
        template_id || null,
        client_id,
      ]
    );

    res.status(201).json({ capture: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

export async function deleteCapture(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;

    const result = await query(
      "UPDATE captures SET is_deleted = true WHERE id = $1 AND is_deleted = false RETURNING id",
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Capture', id);
    }

    res.json({ message: 'Capture deleted' });
  } catch (error) {
    next(error);
  }
}

export async function getDownloadUrl(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;

    const result = await query(
      'SELECT original_key, processed_key FROM captures WHERE id = $1 AND is_deleted = false',
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Capture', id);
    }

    const key = result.rows[0].processed_key || result.rows[0].original_key;
    const url = await getPresignedUrl(key, 3600);

    res.json({ download_url: url, expires_in: 3600 });
  } catch (error) {
    next(error);
  }
}

/** Public: list captures for a gallery (event). */
export async function listGalleryCaptures(req: Request, res: Response, next: NextFunction) {
  try {
    const { event_id } = req.params;
    const pagination: PaginationInput = req.query as any;
    const { limit, offset } = buildPaginationClause(pagination);

    // Verify event is public
    const event = await query(
      "SELECT id FROM events WHERE id = $1 AND (is_public = true OR gallery_enabled = true) AND status != 'archived'",
      [event_id]
    );
    if (event.rows.length === 0) {
      throw new NotFoundError('Event');
    }

    const [data, count] = await Promise.all([
      query(
        `SELECT c.id, c.capture_type, c.processed_url, c.thumbnail_url, c.original_url,
                c.width, c.height, c.duration_ms, c.created_at, s.guest_name
         FROM captures c
         LEFT JOIN sessions s ON c.session_id = s.id
         WHERE c.event_id = $1 AND c.is_deleted = false
         ORDER BY c.created_at DESC
         LIMIT $2 OFFSET $3`,
        [event_id, limit, offset]
      ),
      query(
        'SELECT COUNT(*) FROM captures WHERE event_id = $1 AND is_deleted = false',
        [event_id]
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
