import multer from 'multer';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import { env } from '../config/env';
import { ValidationError } from '../utils/errors';

const allowedMimeTypes = env.ALLOWED_MIME_TYPES.split(',');
const maxFileSize = env.MAX_FILE_SIZE_MB * 1024 * 1024;

const storage = multer.memoryStorage();

export const upload = multer({
  storage,
  limits: {
    fileSize: maxFileSize,
    files: 10,
  },
  fileFilter: (_req, file, cb) => {
    if (!allowedMimeTypes.includes(file.mimetype)) {
      return cb(
        new ValidationError(
          `File type '${file.mimetype}' not allowed. Allowed: ${allowedMimeTypes.join(', ')}`
        )
      );
    }
    cb(null, true);
  },
});

/**
 * Generate a structured S3 key for an uploaded file.
 * Format: {eventId}/{sessionId}/{captureId}/{variant}.{ext}
 */
export function generateS3Key(
  eventId: string,
  sessionId: string,
  variant: 'original' | 'processed' | 'thumbnail',
  mimetype: string
): string {
  const ext = mimeToExtension(mimetype);
  const captureId = uuidv4();
  return `events/${eventId}/sessions/${sessionId}/${captureId}/${variant}.${ext}`;
}

function mimeToExtension(mime: string): string {
  const map: Record<string, string> = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'video/mp4': 'mp4',
    'video/quicktime': 'mov',
  };
  return map[mime] || 'bin';
}
