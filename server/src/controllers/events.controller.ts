import { Request, Response, NextFunction } from 'express';
import { query } from '../config/database';
import { generateUniqueSlug } from '../utils/slug';
import { formatPaginatedResponse, buildPaginationClause } from '../utils/pagination';
import { NotFoundError, ForbiddenError } from '../utils/errors';
import type { CreateEventInput, UpdateEventInput, PaginationInput } from '../schemas';

export async function listEvents(req: Request, res: Response, next: NextFunction) {
  try {
    const pagination: PaginationInput = req.query as any;
    const { limit, offset, orderClause } = buildPaginationClause(pagination);
    const userId = req.user!.sub;
    const isAdmin = req.user!.role === 'admin';

    const whereClause = isAdmin ? '' : 'WHERE e.owner_id = $3';
    const params = isAdmin ? [limit, offset] : [limit, offset, userId];

    const [data, count] = await Promise.all([
      query(
        `SELECT e.*, u.first_name || ' ' || u.last_name AS owner_name
         FROM events e
         JOIN users u ON e.owner_id = u.id
         ${whereClause}
         ${orderClause}
         LIMIT $1 OFFSET $2`,
        params
      ),
      query(
        `SELECT COUNT(*) FROM events e ${whereClause}`,
        isAdmin ? [] : [userId]
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

export async function getEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const result = await query(
      `SELECT e.*, u.first_name || ' ' || u.last_name AS owner_name
       FROM events e
       JOIN users u ON e.owner_id = u.id
       WHERE e.id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Event', id);
    }

    const event = result.rows[0];

    // Check ownership (admin can see all)
    if (req.user!.role !== 'admin' && event.owner_id !== req.user!.sub) {
      throw new ForbiddenError();
    }

    res.json({ event });
  } catch (error) {
    next(error);
  }
}

export async function createEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const input: CreateEventInput = req.body;
    const userId = req.user!.sub;
    const slug = await generateUniqueSlug(input.name);

    const result = await query(
      `INSERT INTO events (
         owner_id, name, slug, description, venue, location,
         start_date, end_date, timezone, branding, settings,
         guest_count_est, is_public, gallery_enabled, password
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
       RETURNING *`,
      [
        userId,
        input.name,
        slug,
        input.description,
        input.venue,
        JSON.stringify(input.location || {}),
        input.start_date,
        input.end_date,
        input.timezone,
        JSON.stringify(input.branding || {}),
        JSON.stringify(input.settings || {}),
        input.guest_count_est,
        input.is_public,
        input.gallery_enabled,
        input.password,
      ]
    );

    res.status(201).json({ event: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

export async function updateEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;
    const input: UpdateEventInput = req.body;

    // Check ownership
    const existing = await query('SELECT owner_id FROM events WHERE id = $1', [id]);
    if (existing.rows.length === 0) throw new NotFoundError('Event', id);
    if (req.user!.role !== 'admin' && existing.rows[0].owner_id !== req.user!.sub) {
      throw new ForbiddenError();
    }

    // Build dynamic update
    const fields: string[] = [];
    const values: any[] = [];
    let paramIdx = 1;

    const fieldMap: Record<string, (v: any) => any> = {
      name: (v) => v,
      description: (v) => v,
      venue: (v) => v,
      location: (v) => JSON.stringify(v),
      start_date: (v) => v,
      end_date: (v) => v,
      timezone: (v) => v,
      status: (v) => v,
      branding: (v) => JSON.stringify(v),
      settings: (v) => JSON.stringify(v),
      guest_count_est: (v) => v,
      is_public: (v) => v,
      gallery_enabled: (v) => v,
      password: (v) => v,
    };

    for (const [key, transform] of Object.entries(fieldMap)) {
      if ((input as any)[key] !== undefined) {
        fields.push(`${key} = $${paramIdx}`);
        values.push(transform((input as any)[key]));
        paramIdx++;
      }
    }

    if (fields.length === 0) {
      return res.json({ event: existing.rows[0] });
    }

    values.push(id);
    const result = await query(
      `UPDATE events SET ${fields.join(', ')} WHERE id = $${paramIdx} RETURNING *`,
      values
    );

    res.json({ event: result.rows[0] });
  } catch (error) {
    next(error);
  }
}

export async function deleteEvent(req: Request, res: Response, next: NextFunction) {
  try {
    const { id } = req.params;

    const existing = await query('SELECT owner_id FROM events WHERE id = $1', [id]);
    if (existing.rows.length === 0) throw new NotFoundError('Event', id);
    if (req.user!.role !== 'admin' && existing.rows[0].owner_id !== req.user!.sub) {
      throw new ForbiddenError();
    }

    // Soft delete via status change
    await query(
      "UPDATE events SET status = 'archived' WHERE id = $1",
      [id]
    );

    res.json({ message: 'Event archived successfully' });
  } catch (error) {
    next(error);
  }
}

/** Public endpoint: get event by slug for gallery. */
export async function getEventBySlug(req: Request, res: Response, next: NextFunction) {
  try {
    const { slug } = req.params;
    const result = await query(
      `SELECT id, name, slug, description, venue, start_date, end_date,
              branding, is_public, gallery_enabled, status
       FROM events
       WHERE slug = $1 AND status != 'archived'`,
      [slug]
    );

    if (result.rows.length === 0) {
      throw new NotFoundError('Event');
    }

    const event = result.rows[0];
    if (!event.is_public && !event.gallery_enabled) {
      throw new NotFoundError('Event');
    }

    res.json({ event });
  } catch (error) {
    next(error);
  }
}
