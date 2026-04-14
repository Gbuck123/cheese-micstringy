import { query } from '../config/database';

/** Generate a URL-safe slug from a string, ensuring uniqueness in the events table. */
export async function generateUniqueSlug(name: string): Promise<string> {
  let base = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 200);

  if (!base) base = 'event';

  let slug = base;
  let counter = 0;

  while (true) {
    const existing = await query(
      'SELECT 1 FROM events WHERE slug = $1 LIMIT 1',
      [slug]
    );
    if (existing.rows.length === 0) return slug;
    counter++;
    slug = `${base}-${counter}`;
  }
}

/** Generate a short alphanumeric code. */
export function generateShortCode(length = 8): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let result = '';
  const array = new Uint8Array(length);
  globalThis.crypto.getRandomValues(array);
  for (let i = 0; i < length; i++) {
    result += chars[array[i] % chars.length];
  }
  return result;
}
