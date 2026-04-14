import { Request, Response, NextFunction } from 'express';
import { AppError, ValidationError } from '../utils/errors';
import { env } from '../config/env';

export function errorHandler(
  err: Error,
  _req: Request,
  res: Response,
  _next: NextFunction
): void {
  // Log error
  if (env.NODE_ENV !== 'test') {
    console.error(`[Error] ${err.message}`, {
      stack: env.NODE_ENV === 'development' ? err.stack : undefined,
    });
  }

  // Handle our custom errors
  if (err instanceof AppError) {
    const response: any = {
      error: {
        code: err.code,
        message: err.message,
      },
    };

    if (err instanceof ValidationError && err.details.length > 0) {
      response.error.details = err.details;
    }

    if (env.NODE_ENV === 'development') {
      response.error.stack = err.stack;
    }

    res.status(err.statusCode).json(response);
    return;
  }

  // Handle multer errors
  if (err.name === 'MulterError') {
    res.status(400).json({
      error: {
        code: 'UPLOAD_ERROR',
        message: err.message,
      },
    });
    return;
  }

  // Unhandled errors
  res.status(500).json({
    error: {
      code: 'INTERNAL_ERROR',
      message:
        env.NODE_ENV === 'production'
          ? 'An unexpected error occurred'
          : err.message,
      ...(env.NODE_ENV === 'development' ? { stack: err.stack } : {}),
    },
  });
}
