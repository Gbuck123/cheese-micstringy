import { Request, Response, NextFunction } from 'express';
import { ZodSchema, ZodError } from 'zod';
import { ValidationError } from '../utils/errors';

type RequestPart = 'body' | 'query' | 'params';

/**
 * Validate request data against a Zod schema.
 * Replaces the request part with the parsed (and coerced) data.
 */
export function validate(schema: ZodSchema, part: RequestPart = 'body') {
  return (req: Request, _res: Response, next: NextFunction) => {
    try {
      const parsed = schema.parse(req[part]);
      // Replace with parsed data (includes defaults, coerced types)
      (req as any)[part] = parsed;
      next();
    } catch (error) {
      if (error instanceof ZodError) {
        const details = error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
          code: issue.code,
        }));
        return next(new ValidationError('Validation failed', details));
      }
      next(error);
    }
  };
}
