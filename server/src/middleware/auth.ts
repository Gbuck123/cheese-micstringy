import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { env } from '../config/env';
import { UnauthorizedError, ForbiddenError } from '../utils/errors';

export interface JwtPayload {
  sub: string;       // user id
  email: string;
  role: 'admin' | 'operator' | 'guest';
  iat: number;
  exp: number;
}

declare global {
  namespace Express {
    interface Request {
      user?: JwtPayload;
    }
  }
}

/** Require a valid access token. */
export function authenticate(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return next(new UnauthorizedError('Missing or malformed Authorization header'));
  }

  const token = header.slice(7);
  try {
    const payload = jwt.verify(token, env.JWT_ACCESS_SECRET) as JwtPayload;
    req.user = payload;
    next();
  } catch (err: any) {
    if (err.name === 'TokenExpiredError') {
      return next(new UnauthorizedError('Access token expired'));
    }
    return next(new UnauthorizedError('Invalid access token'));
  }
}

/** Require one of the specified roles. Must be used after authenticate. */
export function authorize(...roles: Array<'admin' | 'operator' | 'guest'>) {
  return (req: Request, _res: Response, next: NextFunction) => {
    if (!req.user) {
      return next(new UnauthorizedError());
    }
    if (!roles.includes(req.user.role)) {
      return next(new ForbiddenError(`Requires one of: ${roles.join(', ')}`));
    }
    next();
  };
}

/** Optional authentication - attaches user if token present, but does not require it. */
export function optionalAuth(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return next();
  }
  const token = header.slice(7);
  try {
    req.user = jwt.verify(token, env.JWT_ACCESS_SECRET) as JwtPayload;
  } catch {
    // Silently ignore invalid tokens for optional auth
  }
  next();
}
